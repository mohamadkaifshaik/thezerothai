package engagement

import (
	"errors"
	"fmt"
	"strconv"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ADR-0029 Amendment 1, ticket W6-36: the block rule (A1) and the vote change (A2) at the service, over fakes.

const voterKey = "viewer"

// withChangesMax sets POLL_VOTE_CHANGES_MAX for an env.
func withChangesMax(n int) pollEnvOpt { return func(d *Deps, _ *pollEnv) { d.PollVoteChangesMax = n } }

// seedVote stores a vote doc as if uid had voted choice earlier and changed it changes times; the cached post and the userLikes cache are
// left as they are (the viewer reads them on the call).
func (e *pollEnv) seedVote(uid string, choice, changes int) {
	k := docID(pidA, uid)
	if e.pr.votes == nil {
		e.pr.votes = map[string]int{}
	}
	e.pr.votes[k] = choice
	e.pr.bump(k)
	e.pr.changes[k] = changes
}

// The block matrix of A1.1, in both directions, before and after voting.
func TestVotePoll_BlockMatrix(t *testing.T) {
	t.Run("the voter blocks the author, before voting: TARGET_BLOCKED, 0 writes, no vote read", func(t *testing.T) {
		e := newPollEnv(t)
		e.graph.block(voterKey, "author")
		for _, expected := range []int32{0, 1, 3} {
			_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, expected)
			requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED)
		}
		if e.pr.writes != 0 || e.pr.gets != 0 || e.pr.changeCalls != 0 || len(e.posts.pollVotes) != 0 || e.repo.loads != 0 {
			t.Fatalf("a TARGET_BLOCKED touched storage: writes=%d gets=%d changes=%d cache=%v loads=%d", e.pr.writes, e.pr.gets, e.pr.changeCalls, e.posts.pollVotes, e.repo.loads)
		}
	})
	t.Run("the voter blocks the author after voting: the vote is kept, a replay and a change are TARGET_BLOCKED", func(t *testing.T) {
		e := newPollEnv(t)
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 0); err != nil {
			t.Fatal(err)
		}
		e.graph.block(voterKey, "author")
		for name, args := range map[string][2]int32{"replay": {1, 0}, "replay with expected": {1, 2}, "change": {2, 2}, "old client": {2, 0}} {
			_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, args[0], args[1])
			if ae := requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED); ae.Metadata["choice"] != "" {
				t.Errorf("%s: TARGET_BLOCKED carries metadata %v", name, ae.Metadata)
			}
		}
		if e.pr.writes != 1 || e.pr.changeWrites != 0 || e.pr.votes[docID(pidA, voterKey)] != 1 {
			t.Fatalf("writes=%d changes=%d votes=%v, want the first vote kept and nothing else written", e.pr.writes, e.pr.changeWrites, e.pr.votes)
		}
	})
	t.Run("the order: no poll, author, closed and range come before the block", func(t *testing.T) {
		tests := []struct {
			name   string
			prep   func(*pollEnv)
			post   string
			choice int32
			code   connect.Code
			reason commonv1.ErrorReason
		}{
			{"no poll", nil, pidB, 0, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION},
			{"closed", func(e *pollEnv) { e.now = e.closes.Add(time.Second) }, pidA, 0, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED},
			{"choice range", nil, pidA, 3, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION},
			{"the author is the voter", func(e *pollEnv) { e.posts.docs[pidA].AuthorID = voterKey }, pidA, 0, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION},
		}
		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				e := newPollEnv(t)
				e.graph.block(voterKey, "author", voterKey)
				if tt.prep != nil {
					tt.prep(e)
				}
				_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, tt.post, tt.choice, 0)
				requireReason(t, err, tt.code, tt.reason)
			})
		}
	})
	t.Run("the author blocks the voter: the one NOT_FOUND of a missing post, whatever the voter blocks too", func(t *testing.T) {
		// Viewable (posts) answers ErrNotFound for an author who blocks the viewer; the fake models it with a hidden post. A mutual block
		// is the same answer because the voter-side check never runs.
		e := newPollEnv(t)
		e.posts.hidden[pidA] = true
		e.graph.block(voterKey, "author")
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 0)
		ae := requireCode(t, err, connect.CodeNotFound)
		_, missing := e.m.VotePoll(e.ctx, voterKey, keyOK, "0000000000000000099", 1, 0)
		me := requireCode(t, missing, connect.CodeNotFound)
		if ae.Message != me.Message || ae.Reason != me.Reason || len(ae.Metadata) != len(me.Metadata) {
			t.Fatalf("blocked-by-author = %+v, missing post = %+v, want byte-identical", ae, me)
		}
	})
	t.Run("a mute is not a block, and an unblock reopens the poll", func(t *testing.T) {
		e := newPollEnv(t)
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 0); err != nil { // the graph has no block: votable
			t.Fatal(err)
		}
		e.graph.mu.Lock()
		e.graph.blocked = map[string][]string{voterKey: {"author"}}
		e.graph.mu.Unlock()
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 2, 2); err == nil {
			t.Fatal("blocked: want TARGET_BLOCKED")
		}
		e.graph.mu.Lock()
		e.graph.blocked = nil // Unblock: no write to the vote, the voter can change again
		e.graph.mu.Unlock()
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 2, 2); err != nil {
			t.Fatalf("after unblock: %v", err)
		}
	})
	t.Run("a REPOST id is checked against the original's author", func(t *testing.T) {
		e := newPollEnv(t)
		e.graph.block(voterKey, "other") // the reposter, not a party to the poll
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidRep, 0, 0); err != nil {
			t.Fatalf("blocking the reposter must not block the vote: %v", err)
		}
		e2 := newPollEnv(t)
		e2.graph.block(voterKey, "author")
		_, err := e2.m.VotePoll(e2.ctx, voterKey, keyOK, pidRep, 0, 0)
		requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED)
	})
	t.Run("the check reads no extra document: one cached snapshot, no vote read", func(t *testing.T) {
		e := newPollEnv(t)
		e.graph.block(voterKey, "author")
		_, _ = e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 0)
		if e.graph.calls != 1 || e.pr.gets != 0 {
			t.Errorf("snapshot calls = %d, vote reads = %d, want 1 and 0", e.graph.calls, e.pr.gets)
		}
	})
	t.Run("fails closed: no graph, or a graph error, never lets the vote through", func(t *testing.T) {
		noGraph := newPollEnv(t, func(d *Deps, _ *pollEnv) { d.Graph = nil })
		if _, err := noGraph.m.VotePoll(noGraph.ctx, voterKey, keyOK, pidA, 1, 0); err == nil || noGraph.pr.writes != 0 {
			t.Fatalf("no graph: err = %v writes = %d, want an error and 0 writes", err, noGraph.pr.writes)
		}
		broken := newPollEnv(t)
		broken.graph.err = errors.New("firestore unavailable users/viewer")
		_, err := broken.m.VotePoll(broken.ctx, voterKey, keyOK, pidA, 1, 0)
		if err == nil || broken.pr.writes != 0 {
			t.Fatalf("graph error: err = %v writes = %d, want an error and 0 writes", err, broken.pr.writes)
		}
		var ae *apierr.Error
		if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED {
			t.Fatal("a graph error must not be read as a block")
		}
	})
}

// The change matrix: A2.2's table, row by row, with the writes and the counts.
func TestVotePoll_ChangeMatrix(t *testing.T) {
	const max = 5
	tests := []struct {
		name    string
		stored  int // -1 = no vote doc
		changes int
		choice  int32
		exp     int32
		want    string // changed | replay | new | stale | limit
	}{
		{"no vote, e=0: a new vote", -1, 0, 1, 0, "new"},
		{"no vote, e names a vote that does not exist: still a new vote", -1, 0, 1, 3, "new"},
		{"same choice, e=0: replay", 1, 0, 1, 0, "replay"},
		{"same choice, e matches: replay", 1, 2, 1, 2, "replay"},
		{"same choice, e stale: replay", 1, 0, 1, 4, "replay"},
		{"other choice, e matches: a change", 0, 0, 2, 1, "changed"},
		{"other choice, e matches, one change left", 2, max - 1, 0, 3, "changed"},
		{"other choice, e matches at the cap: LIMIT_REACHED", 2, max, 0, 3, "limit"},
		{"other choice, e=0 (an old client): ALREADY_VOTED", 0, 0, 2, 0, "stale"},
		{"other choice, e stale (a second device): ALREADY_VOTED", 0, 0, 2, 3, "stale"},
		{"other choice, e beyond the poll: ALREADY_VOTED", 0, 0, 2, 4, "stale"},
		{"other choice, e stale at the cap: ALREADY_VOTED, not the limit", 0, max, 2, 3, "stale"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newPollEnv(t, withChangesMax(max))
			if tt.stored >= 0 {
				e.seedVote(voterKey, tt.stored, tt.changes)
			}
			var fields *logger.RequestInfo
			e.ctx, fields = logger.WithRequestInfo(e.ctx)
			res, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, tt.choice, tt.exp)
			outcome, _ := fields.Get(fieldOutcome)
			switch tt.want {
			case "new", "changed", "replay":
				if err != nil {
					t.Fatalf("err = %v", err)
				}
				v := posts.ToViewAt(res.Post, res.Viewer, voterKey, e.now)
				if got := v.GetViewerPollChoice(); got != tt.choice+1 {
					t.Errorf("viewer_poll_choice = %d, want %d: the choice this call committed", got, tt.choice+1)
				}
				if !v.GetPost().GetPoll().GetResultsVisible() {
					t.Error("a voter sees the results")
				}
			case "stale":
				ae := requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
				if ae.Metadata[pollMetaChoice] != strconv.Itoa(tt.stored) {
					t.Errorf("choice metadata = %q, want the stored %d", ae.Metadata[pollMetaChoice], tt.stored)
				}
				if outcome != outcomeStale {
					t.Errorf("outcome = %v, want %s", outcome, outcomeStale)
				}
			case "limit":
				ae := requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
				if ae.Metadata["limit"] != "poll_vote_changes" || ae.Metadata[pollMetaChoice] != strconv.Itoa(tt.stored) {
					t.Errorf("metadata = %v, want limit=poll_vote_changes choice=%d", ae.Metadata, tt.stored)
				}
				if outcome != outcomeChangeLimit {
					t.Errorf("outcome = %v, want %s", outcome, outcomeChangeLimit)
				}
			}
			wantWrites, wantChanges := 0, 0
			switch tt.want {
			case "new":
				wantWrites = 1
			case "changed":
				wantChanges = 1
			}
			if e.pr.writes != wantWrites || e.pr.changeWrites != wantChanges {
				t.Errorf("create batches = %d, change batches = %d, want %d and %d", e.pr.writes, e.pr.changeWrites, wantWrites, wantChanges)
			}
			if tt.want == "changed" {
				if outcome != outcomeChanged {
					t.Errorf("outcome = %v, want %s", outcome, outcomeChanged)
				}
				if got := e.pr.votes[docID(pidA, voterKey)]; got != int(tt.choice) {
					t.Errorf("stored choice = %d, want %d", got, tt.choice)
				}
				if got := e.pr.changes[docID(pidA, voterKey)]; got != tt.changes+1 {
					t.Errorf("changes = %d, want %d", got, tt.changes+1)
				}
			}
		})
	}
}

// A change moves one count down and one up with the total fixed, replaces (never appends) the viewer's cache entry, leaves the shared stored
// poll alone, and costs the vote doc read plus one write batch: the documented budget (typical 1 vote read, 0 extra, writes counted at the repo).
func TestVotePoll_ChangeEffects(t *testing.T) {
	e := newPollEnv(t) // counts 5/2/0, total 7
	e.repo.loaded = UserLikes{Recent: []string{pidA}, PollVotes: []string{"0000000000000000901:3", pidA + ":1", "0000000000000000902:0"}}
	e.seedVote(voterKey, 1, 0)
	res, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 2, 2)
	if err != nil {
		t.Fatal(err)
	}
	po := posts.ToViewAt(res.Post, res.Viewer, voterKey, e.now).GetPost().GetPoll()
	if po.GetTotalVotes() != 7 || po.GetChoices()[0].GetVotes() != 5 || po.GetChoices()[1].GetVotes() != 1 || po.GetChoices()[2].GetVotes() != 1 {
		t.Fatalf("poll = %v, want counts 5/1/1 and total 7", po)
	}
	if e.pr.gets != 1 || e.pr.changeWrites != 1 || e.pr.writes != 0 || e.pr.lastChange.From != 1 || e.pr.lastChange.To != 2 {
		t.Fatalf("vote reads=%d change batches=%d creates=%d last=%+v, want one read and one change batch 1>2", e.pr.gets, e.pr.changeWrites, e.pr.writes, e.pr.lastChange)
	}
	if orig := e.posts.docs[pidA].Poll; orig.Total != 7 || orig.Counts[1] != 2 || orig.Counts[2] != 0 {
		t.Errorf("the stored post's poll changed in place: %+v", orig)
	}
	if len(e.posts.pollVotes) != 1 || e.posts.pollVotes[0] != pidA+":1>2" {
		t.Errorf("PollVoteChanged calls = %v, want one 1>2", e.posts.pollVotes)
	}
	st, _ := e.m.s.cache.get(voterKey)
	if got := fmt.Sprint(st.pollVotes); got != fmt.Sprint([]string{"0000000000000000901:3", "0000000000000000902:0", pidA + ":2"}) {
		t.Errorf("cache pollVotes = %v, want the post's one entry replaced by :2 (I-V3), the others kept", st.pollVotes)
	}
	if i, ok := e.m.Viewer(e.ctx, voterKey).PollChoice(e.posts.docs[pidA]); !ok || i != 2 {
		t.Errorf("a later hydration shows choice %d,%v, want 2", i, ok)
	}
	if len(e.pr.trims) != 0 {
		t.Errorf("a change trimmed userLikes: %v", e.pr.trims)
	}
}

// POLL_VOTE_CHANGES_MAX: the cap counts durable changes; 0 makes votes final again.
func TestVotePoll_ChangeCap(t *testing.T) {
	e := newPollEnv(t, withChangesMax(2))
	if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 0, 0); err != nil {
		t.Fatal(err)
	}
	for i, c := range []int32{1, 2} { // two changes allowed
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, c, c); err != nil {
			t.Fatalf("change %d: %v", i+1, err)
		}
	}
	_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 0, 3)
	requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 2, 3); err != nil { // the held vote is still a replay at the cap
		t.Fatalf("replay at the cap: %v", err)
	}
	if e.pr.changeWrites != 2 {
		t.Errorf("change batches = %d, want 2", e.pr.changeWrites)
	}

	off := newPollEnv(t, withChangesMax(0))
	if _, err := off.m.VotePoll(off.ctx, voterKey, keyOK, pidA, 0, 0); err != nil {
		t.Fatal(err)
	}
	_, err = off.m.VotePoll(off.ctx, voterKey, keyOK, pidA, 1, 1)
	requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if off.pr.changeCalls != 0 {
		t.Error("POLL_VOTE_CHANGES_MAX=0 must refuse before any write")
	}
}

// After close everything is POLL_CLOSED: a change, a replay, and a change whose first round lost a race and would commit after close.
func TestVotePoll_ChangeAfterClose(t *testing.T) {
	e := newPollEnv(t)
	e.seedVote(voterKey, 0, 0)
	e.now = e.closes // exactly at closesAt
	for _, args := range [][2]int32{{1, 1}, {0, 1}, {0, 0}} {
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, args[0], args[1])
		requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED)
	}
	if e.pr.changeCalls != 0 || e.pr.writes != 0 {
		t.Errorf("writes after close: creates=%d changes=%d", e.pr.writes, e.pr.changeCalls)
	}

	// A round that loses its precondition is re-checked against the clock before the next attempt (A2.3 step 4).
	late := newPollEnv(t)
	late.seedVote(voterKey, 0, 0)
	late.pr.afterGet = func(uid, postID string) {
		late.pr.touch(uid, postID)
		late.now = late.closes.Add(time.Second)
	}
	_, err := late.m.VotePoll(late.ctx, voterKey, keyOK, pidA, 1, 1)
	requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED)
	if late.pr.changeWrites != 0 {
		t.Error("a change committed after close")
	}
}

// touch moves the version of the vote doc without changing the vote (a concurrent write to the same document).
func (f *fakePollRepo) touch(uid, postID string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bump(docID(postID, uid))
}

// Precondition failures (A2.3 step 3): a moved vote doc is decided again, an unmoved one means the post is gone, four lost rounds are contention.
func TestVotePoll_ChangeRaces(t *testing.T) {
	t.Run("a concurrent change by another device wins: ALREADY_VOTED naming the winner", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		once := false
		e.pr.afterGet = func(uid, postID string) {
			if !once {
				once = true
				e.pr.setVote(uid, postID, 2)
			}
		}
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1)
		ae := requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
		if ae.Metadata[pollMetaChoice] != "2" || e.pr.gets != 2 || e.pr.changeWrites != 0 {
			t.Fatalf("choice=%q reads=%d change batches=%d, want 2, a re-read and 0 writes", ae.Metadata[pollMetaChoice], e.pr.gets, e.pr.changeWrites)
		}
	})
	t.Run("a concurrent write that does not touch the choice is retried and commits", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		once := false
		e.pr.afterGet = func(uid, postID string) {
			if !once {
				once = true
				e.pr.touch(uid, postID)
			}
		}
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1); err != nil {
			t.Fatal(err)
		}
		if e.pr.gets != 2 || e.pr.changeWrites != 1 || e.pr.changeCalls != 2 {
			t.Fatalf("reads=%d change calls=%d committed=%d, want 2 reads, 2 attempts, 1 commit", e.pr.gets, e.pr.changeCalls, e.pr.changeWrites)
		}
	})
	t.Run("the other device already made the same change: a replay", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		once := false
		e.pr.afterGet = func(uid, postID string) {
			if !once {
				once = true
				e.pr.setVote(uid, postID, 1)
			}
		}
		if _, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1); err != nil {
			t.Fatalf("err = %v, want a replay of the winner's identical change", err)
		}
		if e.pr.changeWrites != 0 {
			t.Error("a replay wrote")
		}
	})
	t.Run("the vote doc did not move: the post is gone, NOT_FOUND, 0 writes", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		e.pr.gone = true
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1)
		ae := requireCode(t, err, connect.CodeNotFound)
		if ae.Message != postNotFoundText || e.pr.changeWrites != 0 || len(e.posts.pollVotes) != 0 {
			t.Fatalf("message=%q writes=%d cache=%v", ae.Message, e.pr.changeWrites, e.posts.pollVotes)
		}
	})
	t.Run("four lost rounds are contention", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		e.pr.afterGet = func(uid, postID string) { e.pr.touch(uid, postID) }
		var fields *logger.RequestInfo
		e.ctx, fields = logger.WithRequestInfo(e.ctx)
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1)
		requireCode(t, err, connect.CodeUnavailable)
		if got, _ := fields.Get(fieldContention); got != true {
			t.Errorf("contention field = %v, want true", got)
		}
		if e.pr.gets != pollWriteAttempts || e.pr.changeWrites != 0 {
			t.Errorf("reads=%d commits=%d, want %d bounded rounds and 0 commits", e.pr.gets, e.pr.changeWrites, pollWriteAttempts)
		}
	})
	t.Run("a storage error on the change is redacted and bumps nothing", func(t *testing.T) {
		e := newPollEnv(t)
		e.seedVote(voterKey, 0, 0)
		e.pr.changeErr = errors.New("boom users/viewer posts/" + pidA)
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, 1)
		if err == nil || connect.CodeOf(err) == connect.CodeUnavailable {
			t.Fatalf("err = %v, want an internal error", err)
		}
		if len(e.posts.pollVotes) != 0 {
			t.Error("a failed change bumped the cache")
		}
	})
}

func TestVotePoll_ExpectedChoiceShape(t *testing.T) {
	for _, exp := range []int32{-1, 5, 1 << 20} {
		e := newPollEnv(t)
		_, err := e.m.VotePoll(e.ctx, voterKey, keyOK, pidA, 1, exp)
		ae := requireCode(t, err, connect.CodeInvalidArgument)
		if ae.Metadata["field"] != "expected_choice" || e.posts.viewCalls != 0 || e.pr.gets != 0 {
			t.Errorf("expected %d: field=%q viewable=%d gets=%d, want a shape refusal before any read", exp, ae.Metadata["field"], e.posts.viewCalls, e.pr.gets)
		}
	}
}

// 60 voters x 3 choices (A2.3's race, unit scale): arm (a) expected_choice 0 keeps the one-vote rule; arm (b) the stored choice lets exactly one
// of the two racing changes win and every voter ends with one vote, counts and total consistent.
func TestVotePoll_ConcurrentChangeRace(t *testing.T) {
	const voters = 60
	t.Run("arm b: two racing changes per voter, one wins", func(t *testing.T) {
		e := newPollEnv(t, withChangesMax(5))
		var wg sync.WaitGroup
		errs := make([][2]error, voters)
		for i := range voters {
			uid := "voter" + strconv.Itoa(i)
			c0 := int32(i % 3)
			if _, err := e.m.VotePoll(ctxFor(uid), uid, keyOK, pidA, c0, 0); err != nil {
				t.Fatal(err)
			}
			c1, c2 := (c0+1)%3, (c0+2)%3
			for j, c := range []int32{c1, c2} {
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, errs[i][j] = e.m.VotePoll(ctxFor(uid), uid, keyOK, pidA, c, c0+1)
				}()
			}
		}
		wg.Wait()
		tally := map[int]int64{}
		for i := range voters {
			uid := "voter" + strconv.Itoa(i)
			wins := 0
			for _, err := range errs[i] {
				var ae *apierr.Error
				switch {
				case err == nil:
					wins++
				case errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED:
				default:
					t.Errorf("%s: %v, want a win or ALREADY_VOTED", uid, err)
				}
			}
			k := docID(pidA, uid)
			if wins != 1 || e.pr.changes[k] != 1 {
				t.Errorf("%s: wins=%d changes=%d, want exactly one", uid, wins, e.pr.changes[k])
			}
			tally[e.pr.votes[k]]++
		}
		e.posts.mu.Lock()
		defer e.posts.mu.Unlock()
		cp := e.posts.cached[pidA]
		// Starting counts 5/2/0, total 7: every change moved one vote and the total stayed.
		if cp.Poll.Total != 7+voters {
			t.Fatalf("total = %d, want %d", cp.Poll.Total, 7+voters)
		}
		want := [3]int64{5 + tally[0], 2 + tally[1], tally[2]}
		for i := range want {
			if cp.Poll.Counts[i] != want[i] {
				t.Errorf("count[%d] = %d, want %d (the vote docs)", i, cp.Poll.Counts[i], want[i])
			}
		}
		if e.pr.changeWrites != voters {
			t.Errorf("change batches = %d, want %d", e.pr.changeWrites, voters)
		}
	})
	t.Run("arm a: expected_choice 0 never changes anything", func(t *testing.T) {
		e := newPollEnv(t)
		var wg sync.WaitGroup
		for i := range voters {
			uid := "voter" + strconv.Itoa(i)
			for c := range int32(3) {
				wg.Add(1)
				go func() {
					defer wg.Done()
					_, _ = e.m.VotePoll(ctxFor(uid), uid, keyOK, pidA, c, 0)
				}()
			}
		}
		wg.Wait()
		if e.pr.writes != voters || e.pr.changeWrites != 0 || len(e.pr.votes) != voters {
			t.Fatalf("creates=%d changes=%d votes=%d, want %d one-vote creates and no change", e.pr.writes, e.pr.changeWrites, len(e.pr.votes), voters)
		}
	})
}
