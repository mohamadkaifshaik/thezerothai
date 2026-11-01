//go:build integration

package apiserver

// W6-36 (ADR-0029 Amendment 1 A1 and A2): the voter-blocks-author rule and vote changes over the real Build chain (Firestore and Auth emulators).
// Names start with TestW636_ so one -run regex selects them; the flipped W6-17 tests keep their names.

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// TestW617_ConcurrencyManyVotersRacingThemselves is two cases since W6-36: expected_choice 0 keeps the one-vote rule of W6-17, and with the stored
// choice one of two racing changes wins.
func TestW617_ConcurrencyManyVotersRacingThemselves(t *testing.T) {
	t.Run("expected_choice 0: one vote per voter, the other calls replay or ALREADY_VOTED", w617ConcurrencyArmA)
	t.Run("expected_choice names the stored vote: exactly one racing change wins", w636ConcurrencyArmB)
}

// Arm (b): each of 60 voters votes c0, then races c1 and c2 with expected_choice c0+1 over two instances. Exactly one change commits per voter
// (changes == 1), the other is ALREADY_VOTED naming the winner; afterwards one vote doc per voter, sum of counts == total == 60, every count equals
// the tally of vote docs, one userLikes entry per voter equal to the stored choice, and each success answered the choice it committed.
func w636ConcurrencyArmB(t *testing.T) {
	const voters = 60
	e1 := newPollChain(t)
	e2 := e1.another(t)
	a := e1.user(t)
	pid := e1.poll(t, a)
	us := make([]testUser, voters)
	for i := range us {
		us[i] = e1.user(t)
	}
	retry := func(f func() (*postsv1.PostView, error)) (v *postsv1.PostView, err error) {
		for try := 0; try < 10; try++ {
			if v, err = f(); connect.CodeOf(err) != connect.CodeUnavailable {
				return v, err
			}
			time.Sleep(time.Duration(5<<min(try, 6)) * time.Millisecond) // the contract's retry_after, not synchronisation
		}
		return v, err
	}
	// Step 1: every voter votes c0 = i % 3 (60 voters in parallel).
	var wg sync.WaitGroup
	for i := range us {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c0 := int32(i % 3)
			if _, err := retry(func() (*postsv1.PostView, error) { return e1.vote(us[i], fmt.Sprintf("w636-b-first-%04d", i), pid, c0) }); err != nil {
				t.Errorf("voter %d first vote: %v", i, err)
			}
		}()
	}
	wg.Wait()
	// Step 2: two racing changes per voter, on both instances.
	type result struct {
		choice int32
		view   *postsv1.PostView
		err    error
	}
	results := make([][2]result, voters)
	for i := range us {
		c0 := int32(i % 3)
		for j, c := range []int32{(c0 + 1) % 3, (c0 + 2) % 3} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				e := e1
				if (i+j)%2 == 1 {
					e = e2
				}
				r := result{choice: c}
				r.view, r.err = retry(func() (*postsv1.PostView, error) {
					return e.voteExpecting(us[i], fmt.Sprintf("w636-b-change-%04d-%d", i, j), pid, c, c0+1)
				})
				results[i][j] = r
			}()
		}
	}
	wg.Wait()

	docs, err := e1.fs.Collection("pollVotes").Where("postId", "==", pid).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	tally, stored, changes := map[string]int64{}, map[string]int64{}, map[string]int64{}
	for _, d := range docs {
		uid, _ := d.DataAt("uid")
		ch, _ := d.DataAt("choice")
		n, _ := d.DataAt("changes")
		stored[uid.(string)], tally[strconv.FormatInt(ch.(int64), 10)] = ch.(int64), tally[strconv.FormatInt(ch.(int64), 10)]+1
		changes[uid.(string)], _ = n.(int64)
	}
	total, counts := e1.counts(t, pid)
	var sum int64
	for _, c := range counts {
		sum += c
	}
	if len(docs) != voters || total != voters || sum != voters {
		t.Fatalf("voteDocs=%d total=%d sum(counts)=%d, want %d each (I-V1, I-V2: a change leaves the total alone)", len(docs), total, sum, voters)
	}
	for _, k := range []string{"0", "1", "2"} {
		if counts[k] != tally[k] {
			t.Errorf("poll.counts[%s] = %d, vote docs say %d", k, counts[k], tally[k])
		}
	}
	for i, u := range us {
		wins := 0
		for _, r := range results[i] {
			switch {
			case r.err == nil:
				wins++
				if got := int64(r.view.GetViewerPollChoice()) - 1; got != int64(r.choice) || got != stored[u.uid] {
					t.Errorf("voter %d: success for choice %d answered viewer_poll_choice-1=%d, stored %d", i, r.choice, got, stored[u.uid])
				}
			case connect.CodeOf(r.err) == connect.CodeFailedPrecondition:
				d := wireError(t, r.err, connect.CodeFailedPrecondition)
				assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
				if d.GetMetadata()["choice"] != strconv.FormatInt(stored[u.uid], 10) {
					t.Errorf("voter %d: ALREADY_VOTED choice=%s, stored %d", i, d.GetMetadata()["choice"], stored[u.uid])
				}
			default:
				t.Errorf("voter %d change (choice %d): %v", i, r.choice, r.err)
			}
		}
		if wins != 1 || changes[u.uid] != 1 {
			t.Errorf("voter %d: wins=%d changes=%d, want exactly 1 and 1 (I-V1)", i, wins, changes[u.uid])
		}
		ul, err := e1.fs.Doc("userLikes/" + u.uid).Get(context.Background())
		if err != nil {
			t.Fatalf("voter %d userLikes: %v", i, err)
		}
		if got, _ := ul.DataAt("pollVotes"); !onePollEntry(got, pid, stored[u.uid]) {
			t.Errorf("voter %d: userLikes.pollVotes = %v, want the one entry %s:%d (I-V3)", i, got, pid, stored[u.uid])
		}
	}
	// A cold instance agrees with the store exactly.
	po := e1.another(t).getPost(t, a, pid).GetPost().GetPoll()
	for i, c := range po.GetChoices() {
		if c.GetVotes() != tally[strconv.Itoa(i)] {
			t.Errorf("cold instance: choice %d = %d, store %d", i, c.GetVotes(), tally[strconv.Itoa(i)])
		}
	}
}

// The voter blocks the author after voting (A1): the vote and the check mark are kept and counted, the results stay visible, a replay and a change
// are TARGET_BLOCKED with 0 writes at the documented read ceiling, and after Unblock the voter can change again.
func TestW636_VoterBlocksAuthor(t *testing.T) {
	e := newPollChain(t)
	a, voter, neverVoted := e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)
	if _, err := e.vote(voter, "w636-block-vote-000001", pid, 1); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	for _, u := range []testUser{voter, neverVoted} {
		if _, err := e.graph.Block(ctx, authed(u.token, &graphv1.BlockRequest{IdempotencyKey: "w636-block-key-" + u.uid[:8], UserId: a.uid})); err != nil {
			t.Fatal(err)
		}
	}
	// The block is a pure graph write: no vote, count or userLikes side effect (A1.4).
	if total, counts := e.counts(t, pid); total != 1 || counts["1"] != 1 {
		t.Fatalf("after the block total=%d counts=%v, want the vote kept", total, counts)
	}
	g := e.getPost(t, voter, pid)
	if !g.GetViewerPollVoteBlocked() || g.GetViewerPollChoice() != 2 || !g.GetPost().GetPoll().GetResultsVisible() || g.GetPost().GetPoll().GetChoices()[1].GetVotes() != 1 {
		t.Fatalf("voter's GetPost = blocked %v choice %d visible %v, want blocked, the kept check mark and the results", g.GetViewerPollVoteBlocked(), g.GetViewerPollChoice(), g.GetPost().GetPoll().GetResultsVisible())
	}
	if nv := e.getPost(t, neverVoted, pid); !nv.GetViewerPollVoteBlocked() || nv.GetPost().GetPoll().GetResultsVisible() || nv.GetViewerPollChoice() != 0 {
		t.Fatalf("never-voted blocker's GetPost = blocked %v visible %v, want blocked and hidden results (F3)", nv.GetViewerPollVoteBlocked(), nv.GetPost().GetPoll().GetResultsVisible())
	}
	// The block rule on the wire: replay, change, first vote, REPOST-free.
	for i, c := range []struct {
		u        testUser
		choice   int32
		expected int32
	}{{voter, 1, 0}, {voter, 1, 2}, {voter, 2, 2}, {neverVoted, 0, 0}} {
		_, err := e.voteExpecting(c.u, fmt.Sprintf("w636-block-vote-%06d", i+2), pid, c.choice, c.expected)
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_TARGET_BLOCKED)
		got := e.lineBudget(t, rpcVotePoll)
		budgettest.Assert(t, "VotePoll TARGET_BLOCKED", got, budgettest.Budget{Reads: 7})
		if got.Writes() != 0 {
			t.Errorf("TARGET_BLOCKED wrote %d", got.Writes())
		}
	}
	if total, counts := e.counts(t, pid); total != 1 || counts["1"] != 1 || e.voteDocs(t, pid) != 1 {
		t.Errorf("refused calls changed the poll: total=%d counts=%v", total, counts)
	}
	// Unblock: no write to the vote; the voter can change again.
	if _, err := e.graph.Unblock(ctx, authed(voter.token, &graphv1.UnblockRequest{IdempotencyKey: "w636-unblock-key-00001", UserId: a.uid})); err != nil {
		t.Fatal(err)
	}
	v, err := e.voteExpecting(voter, "w636-block-vote-000099", pid, 2, 2)
	if err != nil || v.GetViewerPollChoice() != 3 || v.GetViewerPollVoteBlocked() {
		t.Fatalf("change after Unblock = %v, %v", v, err)
	}
}

// The change write over the chain: 4 writes and at most 9 reads (the 8 of a new vote + the vote doc), the total fixed, one userLikes entry, the
// cap with its metadata, and POLL_CLOSED after close.
func TestW636_ChangeBudgetCapAndClose(t *testing.T) {
	e := newPollChain(t, func(c *config.Config) { c.Composer.PollVoteChangesMax = 2 })
	a, voter := e.user(t), e.user(t)
	pid := e.poll(t, a)
	if _, err := e.vote(voter, "w636-chg-vote-0000001", pid, 0); err != nil {
		t.Fatal(err)
	}
	for i, to := range []int32{1, 2} {
		v, err := e.voteExpecting(voter, fmt.Sprintf("w636-chg-vote-%07d", i+2), pid, to, to) // expected = the previous choice + 1 = to (to-1+1)
		if err != nil || v.GetViewerPollChoice() != to+1 || v.GetPost().GetPoll().GetTotalVotes() != 1 || v.GetPost().GetPoll().GetChoices()[to].GetVotes() != 1 {
			t.Fatalf("change %d = %v, %v", i+1, v, err)
		}
		got := e.lineBudget(t, rpcVotePoll)
		budgettest.Assert(t, "VotePoll change", got, budgettest.Budget{Reads: 9, Writes: 4})
		t.Logf("change %d: fs_reads=%d fs_writes=%d", i+1, got.Reads(), got.Writes())
		if got.Writes() != 4 {
			t.Errorf("change %d wrote %d, want 4 (vote doc, post counters, userLikes x2)", i+1, got.Writes())
		}
	}
	if total, counts := e.counts(t, pid); total != 1 || counts["2"] != 1 || counts["0"] != 0 || counts["1"] != 0 {
		t.Fatalf("after two changes total=%d counts=%v, want the one vote on choice 2", total, counts)
	}
	if d, ok := voteDocFor(t, e, pid, voter.uid); !ok || d["choice"] != int64(2) || d["changes"] != int64(2) || d["changedAt"] == nil {
		t.Fatalf("vote doc = %v, %v", d, ok)
	}
	if ul, err := e.fs.Doc("userLikes/" + voter.uid).Get(context.Background()); err != nil {
		t.Fatal(err)
	} else if got, _ := ul.DataAt("pollVotes"); !onePollEntry(got, pid, 2) {
		t.Errorf("userLikes.pollVotes = %v, want the one entry for choice 2", got)
	}

	// The cap: LIMIT_REACHED with limit and the stored choice, 0 writes.
	_, err := e.voteExpecting(voter, "w636-chg-vote-0000009", pid, 0, 3)
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
	if d.GetMetadata()["limit"] != "poll_vote_changes" || d.GetMetadata()["choice"] != "2" {
		t.Errorf("LIMIT_REACHED metadata = %v, want limit=poll_vote_changes choice=2", d.GetMetadata())
	}
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
		t.Errorf("LIMIT_REACHED wrote %d", w)
	}
	// A stale expected_choice is ALREADY_VOTED with the stored choice; the old-client shape too.
	for _, exp := range []int32{0, 1} {
		_, err = e.voteExpecting(voter, fmt.Sprintf("w636-chg-vote-stale%d", exp), pid, 1, exp)
		d = wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
		if d.GetMetadata()["choice"] != "2" {
			t.Errorf("ALREADY_VOTED metadata = %v, want choice=2", d.GetMetadata())
		}
	}

	// After close, on an instance that has not cached the poll: a change, and a replay, are POLL_CLOSED.
	e2 := e.another(t)
	closed := e.seedPoll(t, pid, []int64{0, 0, 1}, time.Now().Add(time.Hour), nil)
	if _, err := e.fs.Doc("pollVotes/"+closed+"_"+voter.uid).Set(context.Background(), map[string]any{
		"postId": closed, "uid": voter.uid, "choice": int64(2), "createdAt": time.Now().UTC(), "expireAt": time.Now().Add(48 * time.Hour).UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.fs.Doc("posts/"+closed).Update(context.Background(), []firestore.Update{{Path: "poll.closesAt", Value: time.Now().Add(-time.Minute).UTC()}}); err != nil {
		t.Fatal(err)
	}
	for _, c := range [][2]int32{{0, 3}, {2, 3}, {2, 0}} {
		_, err := e2.voteExpecting(voter, fmt.Sprintf("w636-chg-close-%d%d", c[0], c[1]), closed, c[0], c[1])
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED)
	}
	if d, _ := voteDocFor(t, e, closed, voter.uid); d["choice"] != int64(2) || d["changes"] != nil {
		t.Errorf("a change after close wrote: %v", d)
	}
}

// onePollEntry reports whether a userLikes.pollVotes value holds exactly one entry, for postID with choice, in the three-part form
// "<postId>:<choice>:<closesAtUnix>" (W6-29).
func onePollEntry(got any, postID string, choice int64) bool {
	list, ok := got.([]any)
	if !ok || len(list) != 1 {
		return false
	}
	s, _ := list[0].(string)
	rest, ok := strings.CutPrefix(s, postID+":"+strconv.FormatInt(choice, 10)+":")
	if !ok {
		return false
	}
	_, err := strconv.ParseInt(rest, 10, 64)
	return err == nil
}
