//go:build integration

package apiserver

// W6-17: the poll tests the developers' chain file (engagement_polls_chain_integration_test.go) does not hold. Every test name starts
// with TestW617_ so one -run regex selects the lot. They run over the real Build chain (Firestore and Auth emulators):
//   - the redaction bytes (hidden counts are the same bytes whatever the real split, ADR-0029 D4);
//   - one NOT_FOUND for every way a poll is out of reach (raw HTTP bytes, not proto String());
//   - a replay after closesAt (D6 step 5 precedes the batch);
//   - the new-account cap as the as-built note states it (per instance, in memory, replays and refusals count);
//   - concurrency: many voters, each racing itself across choices, over two Build instances;
//   - DEGRADED_MODE and the flag reveals.
// The emulator serialises writes, so none of the concurrency here is proof for production OPTIMISTIC contention (W6-22 smoke).

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// w617ID is a fresh 19-digit post id (seeded poll docs must not collide across tests on one emulator).
func w617ID() string { return fmt.Sprintf("3%018d", rand.Int63n(1_000_000_000_000_000_000)) }

// seedPoll copies the poll post `from` to a new id with the given per-choice counts (total = their sum), closesAt (zero = keep)
// and extra top-level fields. The copy is a post no instance has read, so no cache holds an older closesAt or count.
func (p *pollChain) seedPoll(t *testing.T, from string, counts []int64, closesAt time.Time, extra map[string]any) string {
	t.Helper()
	snap, err := p.fs.Doc("posts/" + from).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	data := snap.Data()
	poll := data["poll"].(map[string]any)
	cm := map[string]any{}
	var total int64
	for i, c := range counts {
		cm[strconv.Itoa(i)] = c
		total += c
	}
	poll["counts"], poll["total"] = cm, total
	if !closesAt.IsZero() {
		poll["closesAt"] = closesAt.UTC()
	}
	id := w617ID()
	data["conversationId"], data["poll"] = id, poll
	for k, v := range extra {
		data[k] = v
	}
	if _, err := p.fs.Doc("posts/"+id).Set(context.Background(), data); err != nil {
		t.Fatal(err)
	}
	return id
}

// rawVote POSTs VotePoll as JSON and returns the HTTP status and the exact response body.
func (p *pollChain) rawVote(t *testing.T, u testUser, key, postID string, choice int32) (int, string) {
	t.Helper()
	body := fmt.Sprintf(`{"idempotencyKey":%q,"postId":%q,"choiceIndex":%d}`, key, postID, choice)
	req, err := http.NewRequest(http.MethodPost, p.url+rpcVotePoll, bytes.NewReader([]byte(body)))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+u.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// getPoll is GetPost's PostView for viewer.
func (p *pollChain) getPost(t *testing.T, viewer testUser, id string) *postsv1.PostView {
	t.Helper()
	r, err := p.posts.GetPost(context.Background(), authed(viewer.token, &postsv1.GetPostRequest{PostId: id}))
	if err != nil {
		t.Fatalf("GetPost(%s): %v", id, err)
	}
	return r.Msg.GetPost()
}

func (p *pollChain) another(t *testing.T) *pollChain {
	t.Helper()
	return newPollChain(t)
}

func detBytes(t *testing.T, m proto.Message) []byte {
	t.Helper()
	b, err := proto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// Hidden counts are the same bytes whether the real split is {57,0,0}, {0,0,57}, {19,19,19} or, with total 0, nothing at all; the
// whole poll is byte-equal for the same total. total_votes stays real by design (F3), so two totals differ only in that field.
func TestW617_RedactionBytesIdentical(t *testing.T) {
	e := newPollChain(t)
	a, viewer := e.user(t), e.user(t)
	base := e.poll(t, a)
	closes := time.Now().Add(time.Hour)
	splits := map[string][]int64{"57-0-0": {57, 0, 0}, "0-0-57": {0, 0, 57}, "19-19-19": {19, 19, 19}, "0-57-0": {0, 57, 0}}
	ids := map[string]string{}
	for name, c := range splits {
		ids[name] = e.seedPoll(t, base, c, closes, nil)
	}
	zero := e.seedPoll(t, base, []int64{0, 0, 0}, closes, nil)

	var wantPoll, wantChoices []byte
	for name, id := range ids {
		po := e.getPost(t, viewer, id).GetPost().GetPoll()
		if po.GetResultsVisible() || po.GetClosed() || po.GetTotalVotes() != 57 {
			t.Fatalf("%s: visible=%v closed=%v total=%d, want hidden, open, 57", name, po.GetResultsVisible(), po.GetClosed(), po.GetTotalVotes())
		}
		for i, c := range po.GetChoices() {
			if c.GetVotes() != 0 {
				t.Errorf("%s: choice %d votes = %d, want 0 while hidden", name, i, c.GetVotes())
			}
		}
		pb, cb := detBytes(t, po), detBytes(t, &postsv1.Poll{Choices: po.GetChoices()})
		if wantPoll == nil {
			wantPoll, wantChoices = pb, cb
		}
		if !bytes.Equal(pb, wantPoll) {
			t.Errorf("%s: poll bytes differ from another split with the same total", name)
		}
		if !bytes.Equal(cb, wantChoices) {
			t.Errorf("%s: choices bytes differ", name)
		}
	}
	z := e.getPost(t, viewer, zero).GetPost().GetPoll()
	if !bytes.Equal(detBytes(t, &postsv1.Poll{Choices: z.GetChoices()}), wantChoices) {
		t.Error("choices of a 0-vote poll differ from the choices of a 57-vote poll while hidden")
	}
	if z.GetTotalVotes() != 0 || z.GetResultsVisible() {
		t.Errorf("0-vote poll = total %d visible %v", z.GetTotalVotes(), z.GetResultsVisible())
	}

	// Control: the author sees the real split of the same documents.
	if po := e.getPost(t, a, ids["0-0-57"]).GetPost().GetPoll(); !po.GetResultsVisible() || po.GetChoices()[2].GetVotes() != 57 || po.GetChoices()[0].GetVotes() != 0 {
		t.Errorf("author view of {0,0,57} = %v", po)
	}

	// A list producer applies the same rule: the author's user timeline as the non-voter. Only seeded polls are checked by id.
	tl, err := e.timeline.GetUserTimeline(context.Background(), authed(viewer.token, &timelinev1.GetUserTimelineRequest{UserId: a.uid, PageSize: 50}))
	if err != nil {
		t.Fatalf("GetUserTimeline: %v", err)
	}
	seen := 0
	for _, pv := range tl.Msg.GetPosts() {
		for name, id := range ids {
			if pv.GetPost().GetPostId() != id {
				continue
			}
			seen++
			po := pv.GetPost().GetPoll()
			if po.GetResultsVisible() || !bytes.Equal(detBytes(t, po), wantPoll) {
				t.Errorf("user timeline, %s: poll differs from GetPost's hidden bytes: %v", name, po)
			}
		}
	}
	if seen != len(ids) {
		t.Errorf("user timeline listed %d of %d seeded polls", seen, len(ids))
	}
}

// Every way a poll is out of reach answers one NOT_FOUND, byte for byte: a missing id, the author blocking the voter, the voter blocking
// the author, a REPOST id of either, a taken-down post and a suspended author's post. Raw HTTP bodies, compared as strings.
func TestW617_NotFoundBytesIdentical(t *testing.T) {
	e := newPollChain(t)
	a, blockedByA, blocksA, plain, reposter := e.user(t), e.user(t), e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)
	rp, err := e.eng.RepostPost(context.Background(), authed(reposter.token, &engagementv1.RepostPostRequest{IdempotencyKey: "w617-repost-key-000001", PostId: pid}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()
	if repostID == "" {
		t.Fatal("no repost id")
	}
	ctx := context.Background()
	if _, err := e.graph.Block(ctx, authed(a.token, &graphv1.BlockRequest{IdempotencyKey: "w617-block-key-0000001", UserId: blockedByA.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.graph.Block(ctx, authed(blocksA.token, &graphv1.BlockRequest{IdempotencyKey: "w617-block-key-0000002", UserId: a.uid})); err != nil {
		t.Fatal(err)
	}

	// A fresh instance has no cached copy of the seeded posts below.
	e2 := e.another(t)
	closes := time.Now().Add(time.Hour)
	taken := e.seedPoll(t, pid, []int64{1, 0, 0}, closes, map[string]any{"moderation": "TAKEN_DOWN"})
	hiddenAuthor := e.seedPoll(t, pid, []int64{1, 0, 0}, closes, map[string]any{"moderation": "SUSPENDED_AUTHOR"})

	status, ref := e.rawVote(t, plain, "w617-nf-key-reference1", w617ID(), 0)
	if status != http.StatusNotFound || !strings.Contains(ref, "not_found") {
		t.Fatalf("reference = %d %s, want 404 not_found", status, ref)
	}
	cases := []struct {
		name string
		by   testUser
		post string
		on   *pollChain
	}{
		{"author blocks the voter", blockedByA, pid, e},
		{"author blocks the voter, REPOST id", blockedByA, repostID, e},
		{"taken-down post", plain, taken, e2},
		{"suspended author's post", plain, hiddenAuthor, e2},
		{"a missing id on another instance", plain, w617ID(), e2},
	}
	for i, c := range cases {
		st, body := c.on.rawVote(t, c.by, fmt.Sprintf("w617-nf-key-%08d", i), c.post, 0)
		if st != http.StatusNotFound || body != ref {
			t.Errorf("%s: %d %s, want the reference %d %s", c.name, st, body, http.StatusNotFound, ref)
		}
	}
	if n := e.voteDocs(t, pid); n != 0 {
		t.Errorf("a refused vote left %d vote docs", n)
	}
	if total, _ := e.counts(t, pid); total != 0 {
		t.Errorf("a refused vote changed the total to %d", total)
	}

	// The other direction is NOT hidden by design: a voter who blocked the author still sees the post (GetPost, Like and VotePoll share
	// Viewable; only an author who blocks the caller hides it), so the vote is accepted. The plan ticket's "blocked either way" reads
	// as NOT_FOUND both ways; the as-built behaviour follows ADR-0029 D6 step 4 ("visibility as GetPost"). Pinned here so a change is seen.
	if g, err := e.posts.GetPost(ctx, authed(blocksA.token, &postsv1.GetPostRequest{PostId: pid})); err != nil || g.Msg.GetPost().GetPost().GetPostId() != pid {
		t.Fatalf("GetPost by a user who blocked the author = %v, %v", g, err)
	}
	if st, body := e.rawVote(t, blocksA, "w617-nf-key-blocker0001", pid, 0); st != http.StatusOK {
		t.Errorf("vote by a user who blocked the author = %d %s, want 200 (same visibility as GetPost)", st, body)
	}
}

// A replay after closesAt answers POLL_CLOSED (the closed check precedes the batch), as does another choice and a new voter; none writes,
// and the closed poll then shows the real counts to everyone.
func TestW617_ReplayAfterClose(t *testing.T) {
	e := newPollChain(t)
	a, b, c := e.user(t), e.user(t), e.user(t)
	base := e.poll(t, a)
	closesAt := time.Now().Add(4 * time.Second).UTC().Truncate(time.Millisecond) // Firestore keeps microseconds
	pid := e.seedPoll(t, base, []int64{0, 0, 0}, closesAt, nil)

	if _, err := e.vote(b, "w617-close-key-00001", pid, 1); err != nil {
		t.Fatalf("vote before close: %v", err)
	}
	v, err := e.vote(b, "w617-close-key-00001", pid, 1)
	if err != nil || v.GetViewerPollChoice() != 2 {
		t.Fatalf("replay before close = %v, %v", v, err)
	}
	cfg, _ := config.Load()
	snap, err := e.fs.Doc("pollVotes/" + pid + "_" + b.uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	exp, _ := snap.DataAt("expireAt")
	if got := exp.(time.Time).Sub(closesAt); got != cfg.Composer.PollVoteTTLAfterClose {
		t.Errorf("expireAt - closesAt = %v, want POLL_VOTE_TTL_AFTER_CLOSE %v", got, cfg.Composer.PollVoteTTLAfterClose)
	}

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(closesAt.Add(100*time.Millisecond)) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond) // waiting for the server clock, not synchronising goroutines
	}
	steps := []struct {
		name   string
		by     testUser
		key    string
		choice int32
	}{
		{"replay of the same vote", b, "w617-close-key-00001", 1},
		{"same voter, another choice", b, "w617-close-key-00002", 2},
		{"a new voter", c, "w617-close-key-00003", 0},
	}
	for _, s := range steps {
		_, err := e.vote(s.by, s.key, pid, s.choice)
		assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_POLL_CLOSED)
		if w := e.lineBudget(t, rpcVotePoll).Writes(); w != 0 {
			t.Errorf("%s: %d writes after close", s.name, w)
		}
	}
	if total, counts := e.counts(t, pid); total != 1 || counts["1"] != 1 || e.voteDocs(t, pid) != 1 {
		t.Errorf("after the refusals total=%d counts=%v voteDocs=%d, want the one vote untouched", total, counts, e.voteDocs(t, pid))
	}
	for _, who := range []testUser{b, c, a} {
		po := e.getPost(t, who, pid).GetPost().GetPoll()
		if !po.GetClosed() || !po.GetResultsVisible() || po.GetChoices()[1].GetVotes() != 1 || po.GetTotalVotes() != 1 {
			t.Errorf("closed poll for %s = %v, want closed with the real counts", who.uid, po)
		}
	}
}

// POLL_VOTES_PER_DAY_NEW_ACCOUNT, as the as-built note (ADR-0029 N2) states it.
func TestW617_NewAccountCap(t *testing.T) {
	const capN = 3
	newCapped := func(t *testing.T) *pollChain {
		return newPollChain(t, func(c *config.Config) { c.RateLimit.PollVotesPerDayNewAccount = capN })
	}
	refused := func(t *testing.T, err error) *commonv1.ErrorDetail {
		t.Helper()
		d := wireError(t, err, connect.CodeResourceExhausted)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
		if d.GetMetadata()["limit"] != "poll_votes_daily" {
			t.Errorf("metadata = %v, want limit=poll_votes_daily", d.GetMetadata())
		}
		return d
	}

	t.Run("boundary: call N passes, N+1 is refused and writes nothing", func(t *testing.T) {
		e := newCapped(t)
		a, b := e.user(t), e.user(t)
		polls := []string{e.poll(t, a), e.poll(t, a), e.poll(t, a), e.poll(t, a)}
		for i := 0; i < capN; i++ {
			if _, err := e.vote(b, fmt.Sprintf("w617-cap-bnd-key-%04d", i), polls[i], 0); err != nil {
				t.Fatalf("call %d of %d: %v", i+1, capN, err)
			}
		}
		_, err := e.vote(b, "w617-cap-bnd-key-9999", polls[3], 0)
		refused(t, err)
		line := e.lineBudget(t, rpcVotePoll)
		if line.Writes() != 0 || line.Reads() > 1 {
			t.Errorf("the refusal cost reads=%d writes=%d, want at most the interceptor's profile read and 0 writes", line.Reads(), line.Writes())
		}
		if e.voteDocs(t, polls[3]) != 0 {
			t.Error("the refused vote was stored")
		}
	})

	t.Run("replays count toward the cap", func(t *testing.T) {
		e := newCapped(t)
		a, b := e.user(t), e.user(t)
		p1, p2 := e.poll(t, a), e.poll(t, a)
		for i := 0; i < capN; i++ { // one vote, then replays of it
			if _, err := e.vote(b, "w617-cap-rep-key-0001", p1, 0); err != nil {
				t.Fatalf("call %d: %v", i+1, err)
			}
		}
		_, err := e.vote(b, "w617-cap-rep-key-0002", p2, 0)
		refused(t, err)
	})

	t.Run("refusals count toward the cap", func(t *testing.T) {
		e := newCapped(t)
		a, b := e.user(t), e.user(t)
		pid := e.poll(t, a)
		plain, err := e.posts.CreatePost(context.Background(), authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "w617-cap-plain-key-01", Text: "no poll"}))
		if err != nil {
			t.Fatal(err)
		}
		for i := 0; i < capN; i++ {
			_, err := e.vote(b, fmt.Sprintf("w617-cap-ref-key-%04d", i), plain.Msg.GetPost().GetPost().GetPostId(), 0)
			assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		}
		_, err = e.vote(b, "w617-cap-ref-key-9999", pid, 0)
		refused(t, err)
		if e.voteDocs(t, pid) != 0 {
			t.Error("a vote stored after the cap refused it")
		}
	})

	t.Run("per instance: a second instance has its own counter", func(t *testing.T) {
		e1 := newCapped(t)
		a, b := e1.user(t), e1.user(t)
		polls := []string{e1.poll(t, a), e1.poll(t, a), e1.poll(t, a), e1.poll(t, a), e1.poll(t, a)}
		for i := 0; i < capN; i++ {
			if _, err := e1.vote(b, fmt.Sprintf("w617-cap-ins-key-%04d", i), polls[i], 0); err != nil {
				t.Fatal(err)
			}
		}
		_, err := e1.vote(b, "w617-cap-ins-key-9990", polls[3], 0)
		refused(t, err)
		e2 := newCapped(t)
		if _, err := e2.vote(b, "w617-cap-ins-key-9991", polls[3], 0); err != nil {
			t.Fatalf("the same account on a second instance: %v, want the vote accepted (the cap is per instance)", err)
		}
		if _, err := e2.vote(b, "w617-cap-ins-key-9992", polls[4], 0); err != nil {
			t.Fatal(err)
		}
		t.Logf("effective new-account limit = %d x instances, as the as-built note says", capN)
	})

	t.Run("the refusal has the interceptor's shape", func(t *testing.T) {
		// A new account at the new-account cap, and an established account (NewAccountWindow gone) at POLL_VOTES_PER_DAY.
		eNew := newCapped(t)
		eOld := newPollChain(t, func(c *config.Config) {
			c.RateLimit.PollVotesPerDay = capN
			c.RateLimit.PollVotesPerDayNewAccount = 1_000_000
			c.Quota.NewAccountWindow = time.Nanosecond
		})
		var details []*commonv1.ErrorDetail
		for _, e := range []*pollChain{eNew, eOld} {
			a, b := e.user(t), e.user(t)
			pid := e.poll(t, a)
			var err error
			for i := 0; i <= capN; i++ {
				_, err = e.vote(b, "w617-cap-shape-key-001", pid, 0)
			}
			details = append(details, refused(t, err))
		}
		n, o := details[0], details[1]
		if n.GetMessage() != o.GetMessage() || n.GetReason() != o.GetReason() || len(n.GetMetadata()) != len(o.GetMetadata()) {
			t.Errorf("new-account refusal %v differs from the interceptor's %v", n, o)
		}
		for k, v := range o.GetMetadata() {
			if n.GetMetadata()[k] != v {
				t.Errorf("metadata[%s] = %q, interceptor says %q", k, n.GetMetadata()[k], v)
			}
		}
		dn, do := n.GetRetryAfter().AsDuration(), o.GetRetryAfter().AsDuration()
		if dn <= 0 || do <= 0 || dn-do > 5*time.Second || do-dn > 5*time.Second {
			t.Errorf("retry_after: new account %v, interceptor %v, want both positive and within 5 s", dn, do)
		}
	})
}

// Many voters, each racing itself across choices, over two Build instances on one Firestore. Per voter exactly one call wins; the stored
// counts equal the tally of vote docs; every userLikes.pollVotes holds the one stored entry; every answer agrees with the stored choice;
// a cold instance's author view agrees with the store.
func TestW617_ConcurrencyManyVotersRacingThemselves(t *testing.T) {
	const voters = 60
	e1 := newPollChain(t)
	e2 := e1.another(t)
	a := e1.user(t)
	pid := e1.poll(t, a)
	us := make([]testUser, voters)
	for i := range us {
		us[i] = e1.user(t)
	}

	type result struct {
		choice int32
		view   *postsv1.PostView
		err    error
	}
	call := func(e *pollChain, u testUser, key string, choice int32) result {
		var r result
		r.choice = choice
		for try := 0; try < 10; try++ {
			r.view, r.err = e.vote(u, key, pid, choice)
			if connect.CodeOf(r.err) != connect.CodeUnavailable {
				return r
			}
			time.Sleep(time.Duration(5<<min(try, 6)) * time.Millisecond) // the contract's retry_after, not synchronisation
		}
		return r
	}
	results := make([][3]result, voters)
	var wg sync.WaitGroup
	for i := range us {
		for k := 0; k < 3; k++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				e := e1
				if (i+k)%2 == 1 {
					e = e2 // one voter's three calls land on both instances
				}
				results[i][k] = call(e, us[i], fmt.Sprintf("w617-conc-key-%04d-%d", i, k), int32(k))
			}()
		}
	}
	wg.Wait()

	// The store, tallied from the vote docs.
	docs, err := e1.fs.Collection("pollVotes").Where("postId", "==", pid).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	tally := map[string]int64{}
	stored := map[string]int64{}
	for _, d := range docs {
		uid, _ := d.DataAt("uid")
		ch, _ := d.DataAt("choice")
		stored[uid.(string)] = ch.(int64)
		tally[strconv.FormatInt(ch.(int64), 10)]++
	}
	total, counts := e1.counts(t, pid)
	if len(docs) != voters || total != voters {
		t.Fatalf("voteDocs=%d total=%d, want %d each", len(docs), total, voters)
	}
	for _, k := range []string{"0", "1", "2"} {
		if counts[k] != tally[k] {
			t.Errorf("poll.counts[%s] = %d, vote docs say %d", k, counts[k], tally[k])
		}
	}

	unavailable := 0
	for i, u := range us {
		wins := 0
		for _, r := range results[i] {
			switch {
			case r.err == nil:
				wins++
				if got := int64(r.view.GetViewerPollChoice()) - 1; got != stored[u.uid] || int64(r.choice) != stored[u.uid] {
					t.Errorf("voter %d: success for choice %d answered viewer_poll_choice-1=%d, stored %d", i, r.choice, got, stored[u.uid])
				}
			case connect.CodeOf(r.err) == connect.CodeFailedPrecondition:
				d := wireError(t, r.err, connect.CodeFailedPrecondition)
				assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)
				if d.GetMetadata()["choice"] != strconv.FormatInt(stored[u.uid], 10) {
					t.Errorf("voter %d: ALREADY_VOTED choice=%s, stored %d", i, d.GetMetadata()["choice"], stored[u.uid])
				}
			default:
				unavailable++
				t.Errorf("voter %d call (choice %d): %v", i, r.choice, r.err)
			}
		}
		// A voter whose winning call was a retry after UNAVAILABLE still counts one win; a voter whose calls were all refused with
		// ALREADY_VOTED cannot happen (the first writer's own call succeeds), so exactly one success is the invariant.
		if wins != 1 {
			t.Errorf("voter %d: %d successful calls, want exactly 1", i, wins)
		}
		ul, err := e1.fs.Doc("userLikes/" + u.uid).Get(context.Background())
		if err != nil {
			t.Fatalf("voter %d userLikes: %v", i, err)
		}
		got, _ := ul.DataAt("pollVotes")
		if want := fmt.Sprintf("[%s:%d]", pid, stored[u.uid]); fmt.Sprint(got) != want {
			t.Errorf("voter %d: userLikes.pollVotes = %v, want %s", i, got, want)
		}
	}

	// A cold instance reads the store: the author's view equals the tally exactly. The two busy instances hold cached copies bumped only
	// by the commits they made (plus whatever the cold read saw), so each can lag the store by up to the post-cache TTL (60 s): the
	// as-built behaviour (a vote on another instance does not bump this one's cache); logged, bounded, never above the store.
	e3 := e1.another(t)
	po := e3.getPost(t, a, pid).GetPost().GetPoll()
	if po.GetTotalVotes() != voters {
		t.Errorf("cold instance: author sees total %d, store %d", po.GetTotalVotes(), voters)
	}
	for i, c := range po.GetChoices() {
		if c.GetVotes() != tally[strconv.Itoa(i)] {
			t.Errorf("cold instance: author sees choice %d = %d, store %d", i, c.GetVotes(), tally[strconv.Itoa(i)])
		}
	}
	for name, e := range map[string]*pollChain{"instance 1": e1, "instance 2": e2} {
		got := e.getPost(t, a, pid).GetPost().GetPoll()
		var sum int64
		for _, c := range got.GetChoices() {
			sum += c.GetVotes()
		}
		if got.GetTotalVotes() < 1 || got.GetTotalVotes() > voters || sum != got.GetTotalVotes() {
			t.Errorf("%s: cached author view total=%d choices sum=%d, want a self-consistent value in 1..%d", name, got.GetTotalVotes(), sum, voters)
		}
		t.Logf("%s: cached author view total %d of %d in the store (multi-instance lag, TTL-bounded)", name, got.GetTotalVotes(), voters)
	}
	// A voter's GetPost on each instance carries the stored choice.
	for i := 0; i < voters; i += 7 {
		for name, e := range map[string]*pollChain{"instance 1": e1, "instance 2": e2} {
			if got := int64(e.getPost(t, us[i], pid).GetViewerPollChoice()) - 1; got != stored[us[i].uid] {
				t.Errorf("voter %d on %s sees choice %d, stored %d", i, name, got, stored[us[i].uid])
			}
		}
	}
	t.Logf("contention lines: instance 1 %d, instance 2 %d; UNAVAILABLE after retries: %d",
		strings.Count(e1.logs.buf.String(), "poll_vote_contention"), strings.Count(e2.logs.buf.String(), "poll_vote_contention"), unavailable)
}

// DEGRADED_MODE=readonly refuses VotePoll cleanly (VotePoll is not NO_SIDE_EFFECTS), writes nothing, and GetPost still renders the poll.
// nomedia does not touch voting.
func TestW617_DegradedModes(t *testing.T) {
	setup := newPollChain(t)
	a, b, c := setup.user(t), setup.user(t), setup.user(t)
	pid := setup.poll(t, a)

	ro := newPollChain(t, func(cfg *config.Config) { cfg.Degraded = config.DegradedReadonly })
	_, err := ro.vote(b, "w617-ro-key-000000001", pid, 0)
	d := wireError(t, err, connect.CodeUnavailable)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
	if d.GetRetryAfter().AsDuration() <= 0 {
		t.Error("DEGRADED_MODE without a retry_after")
	}
	line := ro.lineBudget(t, rpcVotePoll)
	if line.Writes() != 0 || line.Reads() > 1 {
		t.Errorf("readonly refusal cost reads=%d writes=%d", line.Reads(), line.Writes())
	}
	if n := setup.voteDocs(t, pid); n != 0 {
		t.Errorf("%d vote docs written under readonly", n)
	}
	if po := ro.getPost(t, b, pid).GetPost().GetPoll(); len(po.GetChoices()) != 3 || po.GetClosed() {
		t.Errorf("GetPost under readonly = %v, want the open 3-choice poll", po)
	}

	nm := newPollChain(t, func(cfg *config.Config) { cfg.Degraded = config.DegradedNoMedia })
	if _, err := nm.vote(c, "w617-nm-key-000000001", pid, 1); err != nil {
		t.Errorf("a vote under nomedia: %v", err)
	}
}

// The flag modes the developers' gate test does not hold: creation per caller (the polls allowlist), and the globally-off reveal.
func TestW617_FlagModes(t *testing.T) {
	setup := newPollChain(t)
	a, b, c := setup.user(t), setup.user(t), setup.user(t)
	pid := setup.poll(t, a)
	if _, err := setup.vote(b, "w617-flag-key-000000001", pid, 1); err != nil {
		t.Fatal(err)
	}
	create := func(e *pollChain, u testUser, key string) error {
		_, err := e.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{
			IdempotencyKey: key, Text: "q?", Poll: &postsv1.PollDraft{Choices: []string{"x", "y"}, DurationMinutes: 60},
		}))
		return err
	}

	allow := newPollChain(t, func(cfg *config.Config) {
		cfg.FeaturePolls = flags.Spec{Name: "polls", Mode: flags.Allowlist, Allowlist: map[string]struct{}{a.uid: {}}}
	})
	if err := create(allow, a, "w617-flag-create-0000001"); err != nil {
		t.Errorf("CreatePost with a poll by an allowlisted caller: %v", err)
	}
	d := wireError(t, create(allow, c, "w617-flag-create-0000002"), connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "polls" {
		t.Errorf("metadata = %v, want feature=polls", d.GetMetadata())
	}
	// The same non-listed caller can vote (only creation is per caller).
	if _, err := allow.vote(c, "w617-flag-vote-0000001", pid, 0); err != nil {
		t.Errorf("a vote by a caller outside the polls allowlist: %v", err)
	}

	off := newPollChain(t, func(cfg *config.Config) { cfg.FeaturePolls = flags.Spec{Name: "polls", Mode: flags.Off} })
	wireError(t, create(off, a, "w617-flag-create-0000003"), connect.CodeFailedPrecondition)
	// polls globally off: the poll stays readable and everyone sees the real counts, voted or not.
	po := off.getPost(t, a, pid).GetPost().GetPoll()
	other := off.user(t)
	pv := off.getPost(t, other, pid)
	if !pv.GetPost().GetPoll().GetResultsVisible() || pv.GetPost().GetPoll().GetChoices()[1].GetVotes() != 1 || pv.GetPost().GetPoll().GetTotalVotes() < 1 {
		t.Errorf("globally-off reveal for a non-voter = %v (author view %v)", pv.GetPost().GetPoll(), po)
	}

	// engagement off for the voter: no viewer choice and the counts stay hidden, while the vote itself is stored.
	engOff := newPollChain(t, func(cfg *config.Config) { cfg.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.Off} })
	vv := engOff.getPost(t, b, pid)
	if vv.GetViewerPollChoice() != 0 || vv.GetPost().GetPoll().GetResultsVisible() || vv.GetPost().GetPoll().GetChoices()[1].GetVotes() != 0 {
		t.Errorf("voter with engagement off sees choice %d visible=%v votes=%d, want 0/false/0",
			vv.GetViewerPollChoice(), vv.GetPost().GetPoll().GetResultsVisible(), vv.GetPost().GetPoll().GetChoices()[1].GetVotes())
	}
	wireError(t, func() error { _, err := engOff.vote(b, "w617-flag-vote-0000002", pid, 1); return err }(), connect.CodeFailedPrecondition)
	if got := engOff.lineBudget(t, rpcVotePoll); got.Reads() > 1 || got.Writes() != 0 {
		t.Errorf("engagement-off refusal cost reads=%d writes=%d", got.Reads(), got.Writes())
	}
}

// A REPOST id acts on its original: the vote doc, the counts and the voter's userLikes entry all name the original; the voter's view of
// the REPOST row carries viewer_poll_choice, and the embedded poll of that row never carries counts or results.
func TestW617_RepostIDVotesInTheOriginal(t *testing.T) {
	e := newPollChain(t)
	a, reposter, voter := e.user(t), e.user(t), e.user(t)
	pid := e.poll(t, a)
	rp, err := e.eng.RepostPost(context.Background(), authed(reposter.token, &engagementv1.RepostPostRequest{IdempotencyKey: "w617-rp-key-0000000001", PostId: pid}))
	if err != nil {
		t.Fatal(err)
	}
	repostID := rp.Msg.GetRepostPostId()
	v, err := e.vote(voter, "w617-rp-vote-key-00001", repostID, 2)
	if err != nil {
		t.Fatalf("vote by REPOST id: %v", err)
	}
	if v.GetPost().GetPostId() != pid || v.GetViewerPollChoice() != 3 {
		t.Errorf("response is for post %s choice %d, want the original %s choice 3", v.GetPost().GetPostId(), v.GetViewerPollChoice(), pid)
	}
	if _, ok := voteDocFor(t, e, repostID, voter.uid); ok {
		t.Error("a vote doc is keyed by the REPOST id")
	}
	if d, ok := voteDocFor(t, e, pid, voter.uid); !ok || d["choice"] != int64(2) {
		t.Errorf("vote doc on the original = %v, %v", d, ok)
	}
	if total, counts := e.counts(t, pid); total != 1 || counts["2"] != 1 {
		t.Errorf("original total=%d counts=%v", total, counts)
	}
	// The same vote through the original id is a replay (one natural key), a different choice is ALREADY_VOTED.
	if _, err := e.vote(voter, "w617-rp-vote-key-00001", pid, 2); err != nil {
		t.Errorf("replay through the original id: %v", err)
	}
	_, err = e.vote(voter, "w617-rp-vote-key-00002", repostID, 0)
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_ALREADY_VOTED)

	tl, err := e.timeline.GetUserTimeline(context.Background(), authed(voter.token, &timelinev1.GetUserTimelineRequest{UserId: reposter.uid, PageSize: 20}))
	if err != nil {
		t.Fatal(err)
	}
	rows := 0
	for _, row := range tl.Msg.GetPosts() {
		if row.GetPost().GetKind() != postsv1.PostKind_POST_KIND_REPOST {
			continue
		}
		rows++
		emb := row.GetPost().GetEmbedded().GetPoll()
		if row.GetViewerPollChoice() != 3 || emb == nil || emb.GetResultsVisible() || emb.GetTotalVotes() != 0 || emb.GetChoices()[2].GetVotes() != 0 {
			t.Errorf("REPOST row: viewer_poll_choice=%d embedded poll=%v, want 3 and an embed with no counts", row.GetViewerPollChoice(), emb)
		}
	}
	if rows != 1 {
		t.Errorf("reposter's timeline has %d REPOST rows, want 1", rows)
	}
}

// Polls add no Firestore read to the read path: GetPost and the user timeline cost the same reads for a poll post as for a plain post,
// each on a fresh instance (equal cold caches), for a viewer who voted and one who did not.
func TestW617_ReadBudgetPollVsPlain(t *testing.T) {
	setup := newPollChain(t)
	a, voted, fresh := setup.user(t), setup.user(t), setup.user(t)
	pollID := setup.poll(t, a)
	plain, err := setup.posts.CreatePost(context.Background(), authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "w617-budget-plain-key-1", Text: "plain"}))
	if err != nil {
		t.Fatal(err)
	}
	plainID := plain.Msg.GetPost().GetPost().GetPostId()
	if _, err := setup.vote(voted, "w617-budget-vote-key-01", pollID, 0); err != nil {
		t.Fatal(err)
	}
	const getPost = "/dzeroth.posts.v1.PostService/GetPost"
	for _, viewer := range []struct {
		name string
		u    testUser
	}{{"voter", voted}, {"non-voter", fresh}} {
		readsOf := func(id string) int64 {
			e := newPollChain(t)
			e.getPost(t, viewer.u, id)
			return e.lineBudget(t, getPost).Reads()
		}
		if p, q := readsOf(pollID), readsOf(plainID); p != q {
			t.Errorf("GetPost as %s: %d reads for the poll post, %d for the plain post, want equal", viewer.name, p, q)
		}
	}
}
