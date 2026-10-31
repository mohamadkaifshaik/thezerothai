package engagement

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// fakePollRepo is PollRepo over a map. Every field is read and written under mu, so concurrent votes in a test are race-free;
// "first Create wins" is what Firestore's Create does.
type fakePollRepo struct {
	mu      sync.Mutex
	votes   map[string]int // "<postId>_<uid>" -> choice
	writes  int            // committed vote batches
	gets    int
	gone    bool  // Vote answers VotePostGone
	voteErr error // Vote returns it
	trims   [][]string
	trimErr error
	last    VoteParams
}

func (f *fakePollRepo) Vote(_ context.Context, p VoteParams) (VoteOutcome, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.last = p
	if f.voteErr != nil {
		return VoteWritten, f.voteErr
	}
	if f.gone {
		return VotePostGone, nil
	}
	k := docID(p.PostID, p.UID)
	if _, ok := f.votes[k]; ok {
		return VoteExists, nil
	}
	if f.votes == nil {
		f.votes = map[string]int{}
	}
	f.votes[k] = p.Choice
	f.writes++
	return VoteWritten, nil
}

func (f *fakePollRepo) GetVote(_ context.Context, uid, postID string) (int, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	c, ok := f.votes[docID(postID, uid)]
	return c, ok, nil
}

func (f *fakePollRepo) TrimPollVotes(_ context.Context, _ string, drop []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.trims = append(f.trims, drop)
	return f.trimErr
}

// pollEnv is an env whose module has a PollRepo and a poll post (pidA, authored by "author", 3 choices, counts 5/2/0).
type pollEnv struct {
	*env
	pr      *fakePollRepo
	now     time.Time
	closes  time.Time
	created time.Time
}

type pollEnvOpt func(*Deps, *pollEnv)

func newPollEnv(t *testing.T, opts ...pollEnvOpt) *pollEnv {
	t.Helper()
	pe := &pollEnv{env: &env{repo: &fakeRepo{}, events: &fakeEvents{}}, pr: &fakePollRepo{}}
	pe.now = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	pe.closes = pe.now.Add(24 * time.Hour)
	pe.created = pe.now.Add(-72 * time.Hour)
	pe.posts = &fakePosts{docs: map[string]*posts.Post{
		pidA:   {ID: pidA, AuthorID: "author", Kind: posts.KindPost, Poll: &posts.Poll{Options: []string{"a", "b", "c"}, DurationMin: 1440, ClosesAt: pe.closes, Counts: []int64{5, 2, 0}, Total: 7}},
		pidB:   {ID: pidB, AuthorID: "author", Kind: posts.KindPost},
		pidRep: {ID: pidRep, AuthorID: "other", Kind: posts.KindRepost, RepostOfID: pidA, Embedded: &posts.Embedded{PostID: pidA}},
	}, hidden: map[string]bool{}}
	d := Deps{
		Repo: pe.repo, Posts: pe.posts, Reader: pe.posts, Events: pe.events, NewAccountWindow: 24 * time.Hour, CacheTTL: time.Minute,
		AllowAnonymous: true, PollRepo: pe.pr, PollVoteTTLAfterClose: 30 * 24 * time.Hour, PollViewerVotesKept: 10,
		NewAccountPollVotesPerDay: 50, Now: func() time.Time { return pe.now },
	}
	for _, o := range opts {
		o(&d, pe)
	}
	if d.Directory == nil {
		d.Directory = fakeDir{created: pe.created}
	}
	m, err := New(d)
	if err != nil {
		t.Fatal(err)
	}
	pe.m = m
	pe.ctx = authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
	return pe
}

func ctxFor(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

func TestVotePoll_FirstVote(t *testing.T) {
	e := newPollEnv(t)
	e.repo.loaded = UserLikes{Recent: []string{pidA}, Bookmarks: []string{pidA}}
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 1)
	if err != nil {
		t.Fatal(err)
	}
	if e.pr.writes != 1 || e.pr.last.PostID != pidA || e.pr.last.Choice != 1 || !e.pr.last.ExpireAt.Equal(e.closes.Add(30*24*time.Hour)) {
		t.Fatalf("writes=%d last=%+v, want one batch for choice 1 expiring closesAt + 30 d", e.pr.writes, e.pr.last)
	}
	v := posts.ToViewAt(res.Post, res.Viewer, "viewer", e.now)
	po := v.GetPost().GetPoll()
	if !po.GetResultsVisible() || po.GetTotalVotes() != 8 || po.GetChoices()[1].GetVotes() != 3 || po.GetChoices()[0].GetVotes() != 5 {
		t.Fatalf("poll = %v, want results visible with the committed counts 5/3/0 and total 8", po)
	}
	if v.GetViewerPollChoice() != 2 {
		t.Errorf("viewer_poll_choice = %d, want 2 (index + 1)", v.GetViewerPollChoice())
	}
	if !v.GetLikedByViewer() || !v.GetBookmarkedByViewer() {
		t.Errorf("liked=%v bookmarked=%v, want the userLikes flags kept", v.GetLikedByViewer(), v.GetBookmarkedByViewer())
	}
	// The shared post is never mutated (Cache.AdjustCounts shares one *Poll between cached copies).
	orig := e.posts.docs[pidA].Poll
	if orig.Total != 7 || orig.Counts[1] != 2 {
		t.Errorf("the stored post's poll changed in place: %+v", orig)
	}
	if len(e.posts.pollVotes) != 1 || e.posts.pollVotes[0] != pidA+":1" {
		t.Errorf("PollVoted calls = %v", e.posts.pollVotes)
	}
	// The cache was filled by the response's userLikes read and now holds the vote, with the likes kept.
	st, ok := e.m.s.cache.get("viewer")
	if !ok || len(st.pollVotes) != 1 || st.pollVotes[0] != pollEntry(pidA, 1, e.closes) || len(st.recent) != 1 || e.repo.loads != 1 {
		t.Errorf("cache = %+v ok=%v loads=%d", st, ok, e.repo.loads)
	}
	// A later GetPost-style hydration shows the choice from the same cache with no extra read.
	if i, voted := e.m.Viewer(e.ctx, "viewer").PollChoice(e.posts.docs[pidA]); !voted || i != 1 || e.repo.loads != 1 {
		t.Errorf("Viewer choice = %d,%v loads=%d", i, voted, e.repo.loads)
	}
}

func TestVotePoll_NoUserLikesDocYet(t *testing.T) {
	e := newPollEnv(t) // loaded is the zero UserLikes: LoadUserLikes of a missing doc
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0)
	if err != nil {
		t.Fatal(err)
	}
	if i, ok := res.Viewer.PollChoice(res.Post); !ok || i != 0 {
		t.Fatalf("choice = %d,%v, want 0,true", i, ok)
	}
	if st, _ := e.m.s.cache.get("viewer"); len(st.pollVotes) != 1 {
		t.Fatalf("pollVotes = %v, want the new vote hydrated on the next read", st.pollVotes)
	}
}

func TestVotePoll_ReplayAndAlreadyVoted(t *testing.T) {
	e := newPollEnv(t)
	if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 2); err != nil {
		t.Fatal(err)
	}
	// The same call again: 0 writes, the vote doc read once, the same view.
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 2)
	if err != nil {
		t.Fatal(err)
	}
	if e.pr.writes != 1 || e.pr.gets != 1 || len(e.posts.pollVotes) != 1 {
		t.Fatalf("writes=%d gets=%d PollVoted=%d, want a replay to write and count nothing", e.pr.writes, e.pr.gets, len(e.posts.pollVotes))
	}
	if i, ok := res.Viewer.PollChoice(res.Post); !ok || i != 2 || !posts.ToViewAt(res.Post, res.Viewer, "viewer", e.now).GetPost().GetPoll().GetResultsVisible() {
		t.Fatalf("a replay must show the results and the choice, got %d,%v", i, ok)
	}
	// A different choice: ALREADY_VOTED with the caller's own stored choice, 0 writes.
	_, err = e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0)
	ae := requireCode(t, err, connect.CodeFailedPrecondition)
	if ae.Reason != commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED || ae.Metadata["choice"] != "2" {
		t.Fatalf("reason=%v metadata=%v, want ALREADY_VOTED choice=2", ae.Reason, ae.Metadata)
	}
	if e.pr.writes != 1 {
		t.Fatalf("writes = %d, want 1", e.pr.writes)
	}
}

// A replay where the userLikes entry was trimmed away still shows the results: the view comes from this call's vote (D6 step 8).
func TestVotePoll_ReplayAfterTrim(t *testing.T) {
	e := newPollEnv(t)
	e.pr.votes = map[string]int{docID(pidA, "viewer"): 1}
	e.repo.loaded = UserLikes{} // no pollVotes entry: trimmed
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 1)
	if err != nil {
		t.Fatal(err)
	}
	v := posts.ToViewAt(res.Post, res.Viewer, "viewer", e.now)
	if !v.GetPost().GetPoll().GetResultsVisible() || v.GetViewerPollChoice() != 2 {
		t.Fatalf("visible=%v choice=%d, want results and the stored choice", v.GetPost().GetPoll().GetResultsVisible(), v.GetViewerPollChoice())
	}
}

func TestVotePoll_Refusals(t *testing.T) {
	closed := func(e *pollEnv) { e.now = e.closes.Add(time.Second) }
	tests := []struct {
		name   string
		key    string
		post   string
		choice int32
		prep   func(*pollEnv)
		code   connect.Code
		reason commonv1.ErrorReason
		field  string
		views  int // Viewable calls the refusal may have made
	}{
		{"short key", "short", pidA, 0, nil, connect.CodeInvalidArgument, 0, "idempotency_key", 0},
		{"bad post id", keyOK, "12", 0, nil, connect.CodeInvalidArgument, 0, "post_id", 0},
		{"choice -1", keyOK, pidA, -1, nil, connect.CodeInvalidArgument, 0, "choice_index", 0},
		{"choice 4", keyOK, pidA, 4, nil, connect.CodeInvalidArgument, 0, "choice_index", 0},
		{"choice beyond this poll's choices", keyOK, pidA, 3, nil, connect.CodeInvalidArgument, 0, "choice_index", 1},
		{"unknown post", keyOK, "0000000000000000099", 0, nil, connect.CodeNotFound, 0, "", 1},
		{"hidden post is the same answer", keyOK, pidA, 0, func(e *pollEnv) { e.posts.hidden[pidA] = true }, connect.CodeNotFound, 0, "", 1},
		{"post without a poll", keyOK, pidB, 0, nil, connect.CodeInvalidArgument, 0, "post_id", 1},
		{"the author", keyOK, pidA, 0, func(e *pollEnv) { e.posts.docs[pidA].AuthorID = "viewer" }, connect.CodeInvalidArgument, 0, "post_id", 1},
		{"closed", keyOK, pidA, 0, closed, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED, "", 1},
		{"closed exactly at closesAt", keyOK, pidA, 0, func(e *pollEnv) { e.now = e.closes }, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED, "", 1},
		{"deleted before the commit", keyOK, pidA, 0, func(e *pollEnv) { e.pr.gone = true }, connect.CodeNotFound, 0, "", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newPollEnv(t)
			if tt.prep != nil {
				tt.prep(e)
			}
			_, err := e.m.VotePoll(e.ctx, "viewer", tt.key, tt.post, tt.choice)
			ae := requireCode(t, err, tt.code)
			want := tt.reason
			if tt.code == connect.CodeInvalidArgument {
				want = commonv1.ErrorReason_ERROR_REASON_VALIDATION
			}
			if ae.Reason != want {
				t.Errorf("reason = %v, want %v", ae.Reason, want)
			}
			if tt.field != "" && ae.Metadata["field"] != tt.field {
				t.Errorf("field = %q, want %q", ae.Metadata["field"], tt.field)
			}
			if tt.code == connect.CodeNotFound && ae.Message != postNotFoundText {
				t.Errorf("message = %q, want the one NOT_FOUND text", ae.Message)
			}
			if e.pr.writes != 0 || e.pr.gets != 0 || len(e.posts.pollVotes) != 0 {
				t.Errorf("a refusal touched storage: writes=%d gets=%d PollVoted=%v", e.pr.writes, e.pr.gets, e.posts.pollVotes)
			}
			if e.posts.viewCalls > tt.views {
				t.Errorf("Viewable calls = %d, want <= %d", e.posts.viewCalls, tt.views)
			}
			if e.repo.loads != 0 {
				t.Errorf("userLikes loads = %d, want 0 for a refusal", e.repo.loads)
			}
		})
	}
}

// A refusal on a vote never says which choice the caller tried, and a hidden poll answers exactly as a missing post.
func TestVotePoll_ValidationDoesNotEchoTheChoice(t *testing.T) {
	e := newPollEnv(t)
	_, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 777)
	ae := requireCode(t, err, connect.CodeInvalidArgument)
	if want := "choice_index must be between 0 and 3"; ae.Message != want {
		t.Fatalf("message = %q, want %q", ae.Message, want)
	}
}

func TestVotePoll_RepostIDVotesInTheOriginal(t *testing.T) {
	e := newPollEnv(t)
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidRep, 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.Post.ID != pidA || e.pr.last.PostID != pidA {
		t.Fatalf("post=%s voted=%s, want the original %s", res.Post.ID, e.pr.last.PostID, pidA)
	}
	if e.posts.viewCalls != 2 {
		t.Errorf("Viewable calls = %d, want 2 (repost, original)", e.posts.viewCalls)
	}
}

func TestVotePoll_Contention(t *testing.T) {
	for name, err := range map[string]error{
		"exhausted retries": errors.Join(store.ErrContended, errors.New("aborted")),
		"lock timeout":      fmt.Errorf("wrapped: %w", context.DeadlineExceeded),
	} {
		t.Run(name, func(t *testing.T) {
			e := newPollEnv(t)
			e.pr.voteErr = err
			_, got := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0)
			ae := requireCode(t, got, connect.CodeUnavailable)
			if ae.RetryAfter <= 0 {
				t.Errorf("retry_after = %v, want a hint", ae.RetryAfter)
			}
			if len(e.posts.pollVotes) != 0 {
				t.Errorf("a failed vote bumped the cache: %v", e.posts.pollVotes)
			}
		})
	}
	t.Run("another storage error is internal and redacted", func(t *testing.T) {
		e := newPollEnv(t)
		e.pr.voteErr = errors.New("boom users/viewer posts/" + pidA)
		_, got := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0)
		if connect.CodeOf(got) == connect.CodeUnavailable || got == nil {
			t.Fatalf("err = %v, want an internal error", got)
		}
		for _, s := range []string{"viewer", pidA} {
			if strings.Contains(got.Error(), s) {
				t.Errorf("error %q leaks %q", got.Error(), s)
			}
		}
	})
}

// POLL_VOTES_PER_DAY_NEW_ACCOUNT (50) is applied here, against the interceptor's own poll_votes_daily counter (which already counted
// this call).
func TestVotePoll_NewAccountDailyCap(t *testing.T) {
	tests := []struct {
		name    string
		created time.Duration // account age
		spent   int64         // the interceptor's count, including this call
		cap     bool
		refused bool
	}{
		{"new account at its 50th", time.Hour, 50, true, false},
		{"new account at its 51st", time.Hour, 51, true, true},
		{"established account at 51 (general cap is the interceptor's)", 48 * time.Hour, 51, true, false},
		{"established account at 300", 48 * time.Hour, 300, true, false},
		{"no cap wired: not enforced", time.Hour, 500, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dc := ratelimit.NewDailyCap(1000)
			dc.Charge("viewer", tt.spent)
			e := newPollEnv(t, func(d *Deps, pe *pollEnv) {
				pe.created = pe.now.Add(-tt.created)
				if tt.cap {
					d.PollVoteCap = dc
				}
			})
			_, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0)
			if !tt.refused {
				if err != nil {
					t.Fatalf("err = %v, want a vote", err)
				}
				return
			}
			ae := requireCode(t, err, connect.CodeResourceExhausted)
			if ae.Reason != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED || ae.Metadata["limit"] != "poll_votes_daily" || ae.RetryAfter <= 0 {
				t.Fatalf("rejection = %+v, want the interceptor's RATE_LIMITED poll_votes_daily with a retry_after", ae)
			}
			if e.posts.viewCalls != 0 || e.pr.writes != 0 {
				t.Errorf("a cap refusal read posts (%d) or wrote (%d)", e.posts.viewCalls, e.pr.writes)
			}
		})
	}
}

// The lazy trim (D3, A3): a cached list over kept + slack loses its oldest entries in one field-level write; under it, nothing.
func TestVotePoll_LazyTrim(t *testing.T) {
	old := func(n int) []string {
		out := make([]string, n)
		for i := range out {
			out[i] = "9" + fmt.Sprintf("%018d", i) + ":" + strconv.Itoa(i%3)
		}
		return out
	}
	t.Run("over kept + slack", func(t *testing.T) {
		e := newPollEnv(t) // kept = 10, slack 100
		e.repo.loaded = UserLikes{PollVotes: old(120)}
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0); err != nil {
			t.Fatal(err)
		}
		if len(e.pr.trims) != 1 || len(e.pr.trims[0]) != 111 { // 121 entries after the vote, keep the newest 10
			t.Fatalf("trims = %v, want one trim of the 111 oldest", len(e.pr.trims))
		}
		st, _ := e.m.s.cache.get("viewer")
		if len(st.pollVotes) != 10 || st.pollVotes[9] != pollEntry(pidA, 0, e.closes) {
			t.Fatalf("cache keeps %d votes (last %q), want the newest 10 with the new vote last", len(st.pollVotes), st.pollVotes[len(st.pollVotes)-1])
		}
	})
	t.Run("within the slack", func(t *testing.T) {
		e := newPollEnv(t)
		e.repo.loaded = UserLikes{PollVotes: old(105)}
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0); err != nil {
			t.Fatal(err)
		}
		if len(e.pr.trims) != 0 {
			t.Fatalf("trims = %d, want none", len(e.pr.trims))
		}
	})
	t.Run("a failed trim never fails the vote", func(t *testing.T) {
		e := newPollEnv(t)
		e.pr.trimErr = errors.New("unavailable")
		e.repo.loaded = UserLikes{PollVotes: old(120)}
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("a replay never trims", func(t *testing.T) {
		e := newPollEnv(t)
		e.pr.votes = map[string]int{docID(pidA, "viewer"): 0}
		e.repo.loaded = UserLikes{PollVotes: old(200)}
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 0); err != nil {
			t.Fatal(err)
		}
		if len(e.pr.trims) != 0 {
			t.Fatalf("a replay trimmed %d times", len(e.pr.trims))
		}
	})
}

// 50 voters: every vote lands exactly once and the instance's cached counts compose to 50 (deterministic: no ordering is asserted).
func TestVotePoll_ConcurrentVoters(t *testing.T) {
	e := newPollEnv(t)
	var wg sync.WaitGroup
	errs := make(chan error, 50)
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			uid := "voter" + strconv.Itoa(i)
			if _, err := e.m.VotePoll(ctxFor(uid), uid, keyOK, pidA, int32(i%3)); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("vote failed: %v", err)
	}
	e.posts.mu.Lock()
	defer e.posts.mu.Unlock()
	cp := e.posts.cached[pidA]
	if cp == nil || cp.Poll.Total != 7+50 {
		t.Fatalf("cached poll = %+v, want total 57", cp)
	}
	var sum int64
	for _, c := range cp.Poll.Counts {
		sum += c
	}
	if sum != 57 || e.pr.writes != 50 {
		t.Fatalf("sum of counts = %d, writes = %d, want 57 and 50", sum, e.pr.writes)
	}
}

// 10 concurrent calls by one user with mixed choices: exactly one vote is stored and counted; each call that chose the winner is a
// replay or the vote itself, every other is ALREADY_VOTED carrying the winner's index.
func TestVotePoll_ConcurrentSameVoter(t *testing.T) {
	e := newPollEnv(t)
	var wg sync.WaitGroup
	type outcome struct {
		choice int32
		err    error
	}
	outs := make([]outcome, 10)
	for i := range outs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c := int32(i % 3)
			_, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, c)
			outs[i] = outcome{c, err}
		}()
	}
	wg.Wait()
	if e.pr.writes != 1 || len(e.pr.votes) != 1 {
		t.Fatalf("writes=%d votes=%v, want exactly one", e.pr.writes, e.pr.votes)
	}
	winner := int32(e.pr.votes[docID(pidA, "viewer")])
	for i, o := range outs {
		if o.choice == winner {
			if o.err != nil {
				t.Errorf("call %d chose the winner and failed: %v", i, o.err)
			}
			continue
		}
		var ae *apierr.Error
		if !errors.As(o.err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED || ae.Metadata["choice"] != strconv.Itoa(int(winner)) {
			t.Errorf("call %d (choice %d) = %v, want ALREADY_VOTED choice=%d", i, o.choice, o.err, winner)
		}
	}
	if len(e.posts.pollVotes) != 1 {
		t.Errorf("the post cache was bumped %d times, want 1", len(e.posts.pollVotes))
	}
}

// ToView of the response must agree with the converter's rule for a voter, and a protected author's wire visibility follows the hint.
func TestPollVoteView_HintAndFlagsDegrade(t *testing.T) {
	e := newPollEnv(t)
	e.repo.loadErr = errors.New("firestore unavailable")
	res, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 1)
	if err != nil {
		t.Fatalf("a committed vote failed because the userLikes read did: %v", err)
	}
	v := posts.ToViewAt(res.Post, res.Viewer, "viewer", e.now)
	if v.GetViewerPollChoice() != 2 || !v.GetPost().GetPoll().GetResultsVisible() || v.GetLikedByViewer() {
		t.Fatalf("degraded view = choice %d visible %v liked %v", v.GetViewerPollChoice(), v.GetPost().GetPoll().GetResultsVisible(), v.GetLikedByViewer())
	}
}

// post_hash (the pseudonymous post, logger.HashUID like message_hash) is on the request line and on the contention WARN, so a hot
// poll can be counted from logs; the raw post id and the choice never appear.
func TestVotePoll_PostHashOnRequestLineAndContentionWarn(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(prev) })
	want := logger.HashPost(pidA)

	t.Run("voted", func(t *testing.T) {
		e := newPollEnv(t)
		var fields *logger.RequestInfo
		e.ctx, fields = logger.WithRequestInfo(e.ctx)
		if _, err := e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 2); err != nil {
			t.Fatal(err)
		}
		assertPostHash(t, fields, want)
	})
	t.Run("contention", func(t *testing.T) {
		buf.Reset()
		e := newPollEnv(t)
		e.pr.voteErr = errors.Join(store.ErrContended, errors.New("aborted"))
		var fields *logger.RequestInfo
		e.ctx, fields = logger.WithRequestInfo(e.ctx)
		_, _ = e.m.VotePoll(e.ctx, "viewer", keyOK, pidA, 2)
		assertPostHash(t, fields, want)
		out := buf.String()
		if !strings.Contains(out, `"post_hash":"`+want+`"`) || !strings.Contains(out, "poll_vote_contention") {
			t.Errorf("WARN lacks post_hash: %s", out)
		}
		if strings.Contains(out, pidA) {
			t.Errorf("WARN leaks the raw post id: %s", out)
		}
	})
}

func assertPostHash(t *testing.T, fields *logger.RequestInfo, want string) {
	t.Helper()
	if got, _ := fields.Get(fieldPostHash); got != want {
		t.Errorf("post_hash = %v, want %q", got, want)
	}
	for _, a := range fields.Fields() {
		v := a.Value.String()
		if a.Key != fieldPostHash && (strings.Contains(v, pidA) || a.Key == "choice" || a.Key == "choice_index") {
			t.Errorf("field %s=%q leaks the post id or choice", a.Key, v)
		}
	}
}
