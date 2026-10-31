//go:build integration

package apiserver

// VotePoll over the real Build chain (Firestore and Auth emulators): the wire contract the poll card (W6-13) maps by reason, the
// vote batch, replay, ALREADY_VOTED, concurrency, the new-account cap, the byte-identical NOT_FOUND, the flag gate and the budgets
// (logged fs_reads / fs_writes of the request line, ADR-0029 Cost impact). The emulator serialises writes, so the concurrency here is
// not proof for production OPTIMISTIC concurrency (W6-22 runs a dev smoke).

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcVotePoll = "/dzeroth.engagement.v1.EngagementService/VotePoll"

func pollsOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.PollVotePerUserPerMinute = 1_000_000
	c.RateLimit.PollVotesPerDay, c.RateLimit.PollVotesPerDayNewAccount = 1_000_000, 1_000_000
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeaturePolls = flags.Spec{Name: "polls", Mode: flags.On}
}

type pollChain struct {
	*chainEnv
	eng   engagementv1connect.EngagementServiceClient
	graph graphv1connect.GraphServiceClient
	seq   int
}

func newPollChain(t *testing.T, mut ...func(*config.Config)) *pollChain {
	t.Helper()
	e := newChainWith(t, func(c *config.Config) {
		pollsOn(c)
		for _, m := range mut {
			m(c)
		}
	}, nil)
	return &pollChain{
		chainEnv: e, eng: engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url),
		graph: graphv1connect.NewGraphServiceClient(http.DefaultClient, e.url),
	}
}

func (p *pollChain) user(t *testing.T) testUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	p.createProfile(t, tok)
	return testUser{tok, uid}
}

func (p *pollChain) poll(t *testing.T, author testUser) string {
	t.Helper()
	p.seq++
	r, err := p.posts.CreatePost(context.Background(), authed(author.token, &postsv1.CreatePostRequest{
		IdempotencyKey: fmt.Sprintf("poll-create-key-%07d", p.seq), Text: "which one?",
		Poll: &postsv1.PollDraft{Choices: []string{"red", "green", "blue"}, DurationMinutes: 60},
	}))
	if err != nil {
		t.Fatalf("CreatePost with a poll: %v", err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

func (p *pollChain) vote(u testUser, key, postID string, choice int32) (*postsv1.PostView, error) {
	return p.voteExpecting(u, key, postID, choice, 0)
}

// voteExpecting is vote with VotePollRequest.expected_choice (ADR-0029 Amendment 1 A2.2): 0 = no vote held, 1..4 = the held choice + 1.
func (p *pollChain) voteExpecting(u testUser, key, postID string, choice, expected int32) (*postsv1.PostView, error) {
	r, err := p.eng.VotePoll(context.Background(), authed(u.token, &engagementv1.VotePollRequest{IdempotencyKey: key, PostId: postID, ChoiceIndex: choice, ExpectedChoice: expected}))
	if err != nil {
		return nil, err
	}
	return r.Msg.GetPost(), nil
}

func (p *pollChain) counts(t *testing.T, postID string) (total int64, counts map[string]int64) {
	t.Helper()
	snap, err := p.fs.Doc("posts/" + postID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	poll, _ := snap.Data()["poll"].(map[string]any)
	total, _ = poll["total"].(int64)
	counts = map[string]int64{}
	raw, _ := poll["counts"].(map[string]any)
	for k, v := range raw {
		counts[k], _ = v.(int64)
	}
	return total, counts
}

func (p *pollChain) voteDocs(t *testing.T, postID string) int {
	t.Helper()
	docs, err := p.fs.Collection("pollVotes").Where("postId", "==", postID).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

// The contract the poll card relies on, plus the budgets.
func TestPollVoteChain_ContractAndBudgets(t *testing.T) {
	e := newPollChain(t)
	a, b, c := e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)

	v, err := e.vote(b, "poll-vote-key-000001", pid, 1)
	if err != nil {
		t.Fatalf("VotePoll: %v", err)
	}
	po := v.GetPost().GetPoll()
	if v.GetPost().GetPostId() != pid || !po.GetResultsVisible() || po.GetClosed() || po.GetTotalVotes() != 1 || po.GetChoices()[1].GetVotes() != 1 || v.GetViewerPollChoice() != 2 {
		t.Fatalf("response = %v", v)
	}
	budgettest.Assert(t, "VotePoll new vote", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 8, Writes: 3})
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 3 {
		t.Errorf("writes = %d, want exactly 3 (vote doc, counters, userLikes)", w)
	}
	total, counts := e.counts(t, pid)
	if total != 1 || counts["1"] != 1 || counts["0"] != 0 || e.voteDocs(t, pid) != 1 {
		t.Fatalf("stored total=%d counts=%v", total, counts)
	}
	ul, err := e.fs.Doc("userLikes/" + b.uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := ul.DataAt("pollVotes"); fmt.Sprint(got) != fmt.Sprintf("[%s:1]", pid) {
		t.Errorf("userLikes.pollVotes = %v", got)
	}

	// Replay: same view, 0 writes, the vote doc read once more (9 worst).
	v2, err := e.vote(b, "poll-vote-key-000001", pid, 1)
	if err != nil || v2.GetViewerPollChoice() != 2 || !v2.GetPost().GetPoll().GetResultsVisible() || v2.GetPost().GetPoll().GetTotalVotes() != 1 {
		t.Fatalf("replay = %v, %v", v2, err)
	}
	budgettest.Assert(t, "VotePoll replay", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 9})
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
		t.Errorf("replay writes = %d", w)
	}

	// ALREADY_VOTED: by reason, with the stored choice; 0 writes.
	_, err = e.vote(b, "poll-vote-key-000002", pid, 2)
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
	if d.GetMetadata()["choice"] != "1" {
		t.Errorf("metadata = %v, want choice=1", d.GetMetadata())
	}
	budgettest.Assert(t, "VotePoll already voted", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 9})
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
		t.Errorf("already-voted writes = %d", w)
	}
	if total, _ := e.counts(t, pid); total != 1 {
		t.Errorf("total after ALREADY_VOTED = %d", total)
	}

	// A viewer who has not voted sees no per-choice counts; the voter sees them in GetPost.
	gc, err := e.posts.GetPost(context.Background(), authed(c.token, &postsv1.GetPostRequest{PostId: pid}))
	if err != nil || gc.Msg.GetPost().GetPost().GetPoll().GetResultsVisible() || gc.Msg.GetPost().GetPost().GetPoll().GetTotalVotes() != 1 {
		t.Fatalf("GetPost by a non-voter = %v, %v", gc, err)
	}
	gb, err := e.posts.GetPost(context.Background(), authed(b.token, &postsv1.GetPostRequest{PostId: pid}))
	if err != nil || gb.Msg.GetPost().GetViewerPollChoice() != 2 || !gb.Msg.GetPost().GetPost().GetPoll().GetResultsVisible() {
		t.Fatalf("GetPost by the voter = %v, %v", gb, err)
	}

	// Refusals: the author, a choice beyond the poll, a post without a poll. 0 writes, at most 7 reads.
	_, err = e.vote(a, "poll-vote-key-000003", pid, 0)
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	_, err = e.vote(c, "poll-vote-key-000004", pid, 3)
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	plain, err := e.posts.CreatePost(context.Background(), authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "poll-plain-key-00001", Text: "no poll"}))
	if err != nil {
		t.Fatal(err)
	}
	_, err = e.vote(c, "poll-vote-key-000005", plain.Msg.GetPost().GetPost().GetPostId(), 0)
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	budgettest.Assert(t, "VotePoll refusal", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 7})
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
		t.Errorf("refusal writes = %d", w)
	}
}

// A closed poll: POLL_CLOSED by reason, 0 writes, and GetPost shows closed with the results.
func TestPollVoteChain_Closed(t *testing.T) {
	e := newPollChain(t)
	a, b := e.user(t), e.user(t)
	pid := e.poll(t, a)
	snap, err := e.fs.Doc("posts/" + pid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	data := snap.Data()
	poll := data["poll"].(map[string]any)
	poll["closesAt"] = time.Now().Add(-time.Minute).UTC()
	const closedID = "1000000000000000001"
	data["conversationId"] = closedID
	if _, err := e.fs.Doc("posts/"+closedID).Set(context.Background(), data); err != nil {
		t.Fatal(err)
	}
	_, err = e.vote(b, "poll-vote-key-000010", closedID, 0)
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED)
	budgettest.Assert(t, "VotePoll closed", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 7})
	if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
		t.Errorf("closed writes = %d", w)
	}
	g, err := e.posts.GetPost(context.Background(), authed(b.token, &postsv1.GetPostRequest{PostId: closedID}))
	if err != nil || !g.Msg.GetPost().GetPost().GetPoll().GetClosed() || !g.Msg.GetPost().GetPost().GetPoll().GetResultsVisible() {
		t.Fatalf("GetPost of a closed poll = %v, %v", g, err)
	}
}

// Blocked by the author is the byte-identical NOT_FOUND of a missing post.
func TestPollVoteChain_BlockedIsNotFound(t *testing.T) {
	e := newPollChain(t)
	a, b := e.user(t), e.user(t)
	pid := e.poll(t, a)
	if _, err := e.graph.Block(context.Background(), authed(a.token, &graphv1.BlockRequest{IdempotencyKey: "poll-block-key-00001", UserId: b.uid})); err != nil {
		t.Fatal(err)
	}
	_, errBlocked := e.vote(b, "poll-vote-key-000020", pid, 0)
	_, errMissing := e.vote(b, "poll-vote-key-000021", "1000000000000000099", 0)
	db, dm := wireError(t, errBlocked, connect.CodeNotFound), wireError(t, errMissing, connect.CodeNotFound)
	if db.String() != dm.String() {
		t.Errorf("blocked = %v, missing = %v, want identical", db, dm)
	}
	var cb, cm *connect.Error
	if !errors.As(errBlocked, &cb) || !errors.As(errMissing, &cm) || cb.Message() != cm.Message() {
		t.Errorf("messages differ: %v / %v", errBlocked, errMissing)
	}
}

// 50 users, then 10 racing calls of one user. Clients retry UNAVAILABLE as the contract tells them to.
func TestPollVoteChain_Concurrency(t *testing.T) {
	e := newPollChain(t)
	a := e.user(t)
	pid := e.poll(t, a)
	voters := make([]testUser, 50)
	for i := range voters {
		voters[i] = e.user(t)
	}
	retry := func(u testUser, key, post string, choice int32) error {
		var err error
		for try := 0; try < 8; try++ {
			if _, err = e.vote(u, key, post, choice); connect.CodeOf(err) != connect.CodeUnavailable {
				return err
			}
			time.Sleep(time.Duration(10<<try) * time.Millisecond)
		}
		return err
	}
	var wg sync.WaitGroup
	errs := make([]error, len(voters))
	for i, u := range voters {
		wg.Add(1)
		go func() { defer wg.Done(); errs[i] = retry(u, fmt.Sprintf("poll-conc-key-%08d", i), pid, int32(i%3)) }()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("voter %d: %v", i, err)
		}
	}
	total, counts := e.counts(t, pid)
	if total != 50 || counts["0"]+counts["1"]+counts["2"] != 50 || e.voteDocs(t, pid) != 50 {
		t.Fatalf("total=%d counts=%v voteDocs=%d, want 50", total, counts, e.voteDocs(t, pid))
	}

	// One user, ten calls, mixed choices: exactly one vote counted.
	solo := e.user(t)
	pid2 := e.poll(t, a)
	res := make([]error, 10)
	for i := range res {
		wg.Add(1)
		go func() {
			defer wg.Done()
			res[i] = retry(solo, fmt.Sprintf("poll-solo-key-%08d", i), pid2, int32(i%3))
		}()
	}
	wg.Wait()
	total2, _ := e.counts(t, pid2)
	if total2 != 1 || e.voteDocs(t, pid2) != 1 {
		t.Fatalf("one user: total=%d voteDocs=%d, want 1", total2, e.voteDocs(t, pid2))
	}
	ok := 0
	for _, err := range res {
		if err == nil {
			ok++
			continue
		}
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
	}
	if ok < 1 {
		t.Error("nobody succeeded")
	}
	ul, err := e.fs.Doc("userLikes/" + solo.uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := ul.DataAt("pollVotes"); len(got.([]any)) != 1 {
		t.Errorf("userLikes.pollVotes = %v, want one entry", got)
	}
}

// POLL_VOTES_PER_DAY_NEW_ACCOUNT is enforced in the service: a new account's 3rd call (cap 2) is RATE_LIMITED; an established one is not.
func TestPollVoteChain_NewAccountCap(t *testing.T) {
	for _, tt := range []struct {
		name    string
		mut     func(*config.Config)
		refused bool
	}{
		{"new account", func(c *config.Config) { c.RateLimit.PollVotesPerDayNewAccount = 2 }, true},
		{"established account", func(c *config.Config) {
			c.RateLimit.PollVotesPerDayNewAccount = 2
			c.Quota.NewAccountWindow = time.Nanosecond
		}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newPollChain(t, tt.mut)
			a, b := e.user(t), e.user(t)
			pid := e.poll(t, a)
			var err error
			for i := 0; i < 3; i++ {
				_, err = e.vote(b, "poll-cap-key-0000001", pid, 0)
			}
			if !tt.refused {
				if err != nil {
					t.Fatalf("3rd call: %v", err)
				}
				return
			}
			d := wireError(t, err, connect.CodeResourceExhausted)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
			if d.GetMetadata()["limit"] != "poll_votes_daily" {
				t.Errorf("metadata = %v", d.GetMetadata())
			}
		})
	}
}

// The per-minute bucket (30): the 31st call in a minute is RATE_LIMITED.
func TestPollVoteChain_BucketLimit(t *testing.T) {
	e := newPollChain(t, func(c *config.Config) { c.RateLimit.PollVotePerUserPerMinute = 30 })
	a, b := e.user(t), e.user(t)
	pid := e.poll(t, a)
	var err error
	for i := 0; i < 31; i++ {
		_, err = e.vote(b, "poll-bkt-key-00000001", pid, 0)
		if i < 30 && err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
	}
	assertReason(t, wireError(t, err, connect.CodeResourceExhausted), commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
}

// The flag gate: FEATURE_DISABLED with the feature name before any read; a polls allowlist or percent 0 that excludes the voter still
// lets them vote (only globally off refuses).
func TestPollVoteChain_FlagGate(t *testing.T) {
	cases := []struct {
		name    string
		polls   func(author string) flags.Spec
		engOff  bool
		feature string // "" = allowed
	}{
		{"all on", func(string) flags.Spec { return flags.Spec{Name: "polls", Mode: flags.On} }, false, ""},
		{"engagement off", func(string) flags.Spec { return flags.Spec{Name: "polls", Mode: flags.On} }, true, "engagement"},
		{"polls off", func(string) flags.Spec { return flags.Spec{Name: "polls", Mode: flags.Off} }, false, "polls"},
		{"polls allowlist, voter outside", func(a string) flags.Spec {
			return flags.Spec{Name: "polls", Mode: flags.Allowlist, Allowlist: map[string]struct{}{a: {}}}
		}, false, ""},
		{"polls percent 0 with the author listed", func(a string) flags.Spec {
			return flags.Spec{Name: "polls", Mode: flags.Percent, Percent: 0, Allowlist: map[string]struct{}{a: {}}}
		}, false, ""},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			authorTok, authorUID := mintToken(t, "")
			e := newPollChain(t, func(c *config.Config) {
				c.FeaturePolls = tt.polls(authorUID)
				if tt.engOff {
					c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.Off}
				}
			})
			e.createProfile(t, authorTok)
			a := testUser{authorTok, authorUID}
			b := e.user(t)
			pid := "1000000000000000001" // a refusal never reads it
			if tt.feature == "" {
				pid = e.poll(t, a)
			}
			_, err := e.vote(b, "poll-flag-key-0000001", pid, 0)
			if tt.feature == "" {
				if err != nil {
					t.Fatalf("vote: %v", err)
				}
				return
			}
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if d.GetMetadata()["feature"] != tt.feature {
				t.Errorf("metadata = %v, want feature=%s", d.GetMetadata(), tt.feature)
			}
			budgettest.Assert(t, "VotePoll flag refusal", e.lineBudget(t, rpcVotePoll), budgettest.Budget{Reads: 1})
		})
	}
}
