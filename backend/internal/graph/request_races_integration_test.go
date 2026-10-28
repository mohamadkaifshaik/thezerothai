//go:build integration

// request_races_integration_test.go is the W3-35b race and redelivery suite for the ADR-0025 request lifecycle (D7, D8,
// D9): Respond on two instances, the privacy_public job against withdraw, Block and a manual accept, two concurrent job
// runs, a delivery that stops at the page cap, a crash between and after pages, and at-cap requesters. Every scenario
// ends with the automatic invariant sweep (I1 to I4, I-R and I-X); the assertions here are the end states the sweep cannot
// know (one effect, one event, an exact followersCount).
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// twoInstances wires two Cloud Run instances (own caches, own event recorders) onto one Firestore project.
func twoInstances(t *testing.T) (w1, w2 wired, ev1, ev2 *acceptRecorder) {
	t.Helper()
	ev1, ev2 = &acceptRecorder{}, &acceptRecorder{}
	w1 = newWired(t, withEvents(ev1))
	w2 = newInstance(w1.client, withEvents(ev2))
	return
}

func hasEdge(t *testing.T, w wired, follower, followee string) bool {
	t.Helper()
	return docExists(t, w.client, "follows/"+follower+"_"+followee)
}

// TestW335b_Respond_TwoInstances: the same request answered at the same moment on two instances (ADR-0025 D7, "Respond on
// two instances"). Neither call may fail; whichever commits second is a replay (the request is gone), so exactly one
// effect lands: one edge or none, one counter step, at most one notification.
func TestW335b_Respond_TwoInstances(t *testing.T) {
	type op func(ctx context.Context, w wired) error
	respond := func(accept bool) op {
		return func(ctx context.Context, w wired) error {
			_, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, "uid-a", accept)
			return err
		}
	}
	withdraw := func(ctx context.Context, w wired) error {
		_, err := w.graph.Unfollow(ctx, "uid-a", key2, "uid-p")
		return err
	}
	blockRequester := func(ctx context.Context, w wired) error {
		_, err := w.graph.Block(ctx, "uid-p", key3, "uid-a")
		return err
	}
	tests := []struct {
		name     string
		a, b     op
		edge     string // "yes", "no" or "either"
		maxEvent int
	}{
		{"accept and accept", respond(true), respond(true), "yes", 1},
		{"accept and decline", respond(true), respond(false), "either", 1},
		{"decline and decline", respond(false), respond(false), "no", 0},
		{"accept and withdraw", respond(true), withdraw, "either", 1},
		{"decline and withdraw", respond(false), withdraw, "no", 0},
		{"accept and block", respond(true), blockRequester, "no", 1},
	}
	for _, tt := range tests {
		for round := 0; round < 3; round++ {
			t.Run(fmt.Sprintf("%s %d", tt.name, round), func(t *testing.T) {
				w1, w2, ev1, ev2 := twoInstances(t)
				mustCreateProfile(t, w1.identity, "uid-p", "userp")
				mustCreateProfile(t, w1.identity, "uid-a", "usera")
				protect(t, w1, "uid-p")
				request(t, w1, "uid-a", "uid-p")
				// Instance 2 has seen nothing yet: its first read of everything is from Firestore.
				errs := runConcurrently(2, func(i int) error {
					if i == 0 {
						return tt.a(context.Background(), w1)
					}
					return tt.b(context.Background(), w2)
				})
				for i, err := range errs {
					if err != nil {
						t.Errorf("racer %d: %v", i, err)
					}
				}
				assertRequestInvariants(t, w1, false, [2]string{"uid-a", "uid-p"})
				edge := hasEdge(t, w1, "uid-a", "uid-p")
				if (tt.edge == "yes" && !edge) || (tt.edge == "no" && edge) {
					t.Errorf("edge = %v, want %s", edge, tt.edge)
				}
				events := len(ev1.accepted) + len(ev2.accepted)
				wantFollowers := int64(0)
				if edge {
					wantFollowers = 1
				}
				if _, followers := storedCounts(t, w1, "uid-p"); followers != wantFollowers {
					t.Errorf("followersCount = %d, want %d (edge=%v)", followers, wantFollowers, edge)
				}
				if following, _ := storedCounts(t, w1, "uid-a"); following != wantFollowers {
					t.Errorf("followingCount = %d, want %d (edge=%v)", following, wantFollowers, edge)
				}
				// A withdraw that removed the accepted edge afterwards keeps the accept's event (a notification is not
				// recalled), so the bound is on accepts, not on the edge.
				if events > tt.maxEvent {
					t.Errorf("FollowRequestAccepted events = %d across both instances, want at most %d", events, tt.maxEvent)
				}
				if tt.edge == "yes" && events != 1 {
					t.Errorf("events = %d, want exactly 1 (the loser is a replay and emits nothing)", events)
				}
			})
		}
	}
}

// pendingJob builds a job on w over the real repo, with an optional page size (0 = production 100).
func pendingJob(w wired, page int) *graph.PrivacyPublicJob {
	j := w.graph.privacyJob(w.graph.repo)
	if page > 0 {
		graph.SetPrivacyPublicPage(j, page)
	}
	return j
}

func countAccepted(ev *acceptRecorder) map[string]int {
	ev.mu.Lock()
	defer ev.mu.Unlock()
	out := map[string]int{}
	for _, a := range ev.accepted {
		out[a[1]]++
	}
	return out
}

func requireEachOnce(t *testing.T, got map[string]int, reqs []string) {
	t.Helper()
	for _, r := range reqs {
		if got[r] != 1 {
			t.Errorf("requester %s: %d FollowRequestAccepted events, want exactly 1", r, got[r])
		}
	}
	if len(got) != len(reqs) {
		t.Errorf("events for %d distinct requesters, want %d", len(got), len(reqs))
	}
}

// TestW335b_PrivacyPublic_DeliveryStopsAtThePageCap: 60 pending with a page of 1 means a run reaches the 50-page cap of one
// delivery and returns ErrPrivacyPublicMore (the message is nacked). The accepted 50 have dropped out of the query, so the
// redelivery finishes the last 10 and nothing is doubled; a third delivery is a no-op.
func TestW335b_PrivacyPublic_DeliveryStopsAtThePageCap(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	reqs := pendingTo(t, w, 60)
	unprotect(t, w, "uid-p")
	job := pendingJob(w, 1)

	out, err := job.Run(context.Background(), "uid-p")
	if !errors.Is(err, graph.ErrPrivacyPublicMore) || out != "" {
		t.Fatalf("run 1 = %q, %v; want ErrPrivacyPublicMore (the delivery is nacked)", out, err)
	}
	if got := pendingCount(t, w); got != 60-graph.PrivacyPublicMaxPagesForTest {
		t.Errorf("pending after run 1 = %d, want %d", got, 60-graph.PrivacyPublicMaxPagesForTest)
	}
	if _, followers := counts(t, w, "uid-p"); followers != int64(graph.PrivacyPublicMaxPagesForTest) {
		t.Errorf("followersCount after run 1 = %d, want %d (each page counted with its edges)", followers, graph.PrivacyPublicMaxPagesForTest)
	}

	out, err = job.Run(context.Background(), "uid-p")
	if err != nil || out != "done" {
		t.Fatalf("run 2 = %q, %v; want done", out, err)
	}
	if got := pendingCount(t, w); got != 0 {
		t.Errorf("pending after run 2 = %d", got)
	}
	if _, followers := counts(t, w, "uid-p"); followers != 60 {
		t.Errorf("followersCount = %d, want exactly 60", followers)
	}
	requireEachOnce(t, countAccepted(ev), reqs)
	for _, r := range reqs {
		assertRequestInvariants(t, w, false, [2]string{r, "uid-p"})
		if !hasEdge(t, w, r, "uid-p") {
			t.Fatalf("no edge %s -> uid-p", r)
		}
	}
	out, err = job.Run(context.Background(), "uid-p")
	if err != nil || out != "done" {
		t.Fatalf("run 3 = %q, %v", out, err)
	}
	requireEachOnce(t, countAccepted(ev), reqs)
}

// failingAccepter delegates to the real repo and fails the Nth page: before the commit (the page never ran) or after it (the
// page committed and the process "died" before returning).
type failingAccepter struct {
	real      graph.PendingAccepter
	failOn    int
	afterRun  bool
	calls     int
	failedErr error
}

func (f *failingAccepter) AcceptPendingPage(ctx context.Context, a graph.PendingPageArgs) (graph.PendingPageResult, error) {
	f.calls++
	if f.calls != f.failOn {
		return f.real.AcceptPendingPage(ctx, a)
	}
	f.failedErr = errors.New("injected crash")
	if !f.afterRun {
		return graph.PendingPageResult{}, f.failedErr
	}
	if _, err := f.real.AcceptPendingPage(ctx, a); err != nil {
		return graph.PendingPageResult{}, err
	}
	return graph.PendingPageResult{}, f.failedErr
}

// TestW335b_PrivacyPublic_CrashBetweenAndAfterPages: the redelivery after a crash converges on the exact end state.
//   - a crash before page 3 loses nothing and no notification;
//   - a crash after page 3 committed but before its events were emitted keeps the edges and counters (the page is atomic)
//     and loses only that page's notification (ADR-0025 D8: "a crash between commit and emit loses at most that page's
//     notifications"); the redelivery neither doubles the edge nor emits for it.
func TestW335b_PrivacyPublic_CrashBetweenAndAfterPages(t *testing.T) {
	for _, afterRun := range []bool{false, true} {
		t.Run(fmt.Sprintf("crash after the commit=%v", afterRun), func(t *testing.T) {
			ev := &acceptRecorder{}
			w := newWired(t, withEvents(ev))
			reqs := pendingTo(t, w, 5)
			unprotect(t, w, "uid-p")

			fa := &failingAccepter{real: w.graph.repo, failOn: 3, afterRun: afterRun}
			job := w.graph.privacyJob(fa)
			graph.SetPrivacyPublicPage(job, 1)
			if _, err := job.Run(context.Background(), "uid-p"); err == nil || fa.failedErr == nil {
				t.Fatalf("the injected crash did not surface: %v", err)
			}
			wantAfterCrash := 2
			if afterRun {
				wantAfterCrash = 3
			}
			if _, followers := counts(t, w, "uid-p"); followers != int64(wantAfterCrash) {
				t.Errorf("followersCount after the crash = %d, want %d", followers, wantAfterCrash)
			}
			if got := pendingCount(t, w); got != 5-wantAfterCrash {
				t.Errorf("pending after the crash = %d, want %d", got, 5-wantAfterCrash)
			}

			// The redelivery runs on the real repo.
			redo := pendingJob(w, 1)
			if out, err := redo.Run(context.Background(), "uid-p"); err != nil || out != "done" {
				t.Fatalf("redelivery = %q, %v", out, err)
			}
			if _, followers := counts(t, w, "uid-p"); followers != 5 {
				t.Errorf("followersCount = %d, want exactly 5", followers)
			}
			got := countAccepted(ev)
			for _, r := range reqs {
				if got[r] > 1 {
					t.Errorf("requester %s notified %d times", r, got[r])
				}
				assertRequestInvariants(t, w, false, [2]string{r, "uid-p"})
				if !hasEdge(t, w, r, "uid-p") {
					t.Errorf("no edge %s -> uid-p", r)
				}
			}
			wantEvents := 5
			if afterRun {
				wantEvents = 4 // the page that committed before the crash lost its event
			}
			total := 0
			for _, n := range got {
				total += n
			}
			if total != wantEvents {
				t.Errorf("events = %d, want %d", total, wantEvents)
			}
		})
	}
}

// TestW335b_PrivacyPublic_ConcurrentRuns: the same message delivered to two instances at the same moment (a redelivery
// while the first run is still going). Pages are atomic and an accepted request drops out of the other run's query, so each
// requester is accepted once and followersCount is exact. A run that loses a transaction to the other retries; one that
// exhausts its retries returns an error (a nack) and the redelivery finishes: the test converges either way.
func TestW335b_PrivacyPublic_ConcurrentRuns(t *testing.T) {
	const n = 250
	w1, w2, ev1, ev2 := twoInstances(t)
	reqs := pendingTo(t, w1, n)
	unprotect(t, w1, "uid-p")
	jobs := []*graph.PrivacyPublicJob{pendingJob(w1, 0), pendingJob(w2, 0)}

	var mu sync.Mutex
	var outcomes []string
	errs := runConcurrently(2, func(i int) error {
		out, err := jobs[i].Run(context.Background(), "uid-p")
		mu.Lock()
		outcomes = append(outcomes, out)
		mu.Unlock()
		return err
	})
	for i, err := range errs {
		if err != nil {
			t.Logf("run %d failed with %v (a nack): the redelivery must finish", i, err)
		}
	}
	t.Logf("concurrent privacy_public outcomes: %v, errors: %v", outcomes, errs)
	if out, err := jobs[0].Run(context.Background(), "uid-p"); err != nil || out != "done" {
		t.Fatalf("converging run = %q, %v", out, err)
	}

	if got := pendingCount(t, w1); got != 0 {
		t.Errorf("pending = %d, want 0", got)
	}
	if _, followers := counts(t, w1, "uid-p"); followers != n {
		t.Errorf("followersCount = %d, want exactly %d", followers, n)
	}
	total := countAccepted(ev1)
	for r, c := range countAccepted(ev2) {
		total[r] += c
	}
	requireEachOnce(t, total, reqs)
	for _, r := range reqs {
		if !hasEdge(t, w1, r, "uid-p") {
			t.Fatalf("no edge %s -> uid-p", r)
		}
	}
}

// TestW335b_PrivacyPublic_AgainstWithdrawBlockAndManualAccept: while the job accepts a page, 10 requesters withdraw, the
// owner blocks 10 and answers 10 by hand. Whoever wins each pair, no request survives, followersCount equals the edges,
// no blocked requester follows (the Block clean-up removes an edge the job won), and no call fails. The end sweep proves
// I1 to I4, I-R and I-X.
func TestW335b_PrivacyPublic_AgainstWithdrawBlockAndManualAccept(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	reqs := pendingTo(t, w, 40)
	unprotect(t, w, "uid-p")
	withdrawers, blocked, manual := reqs[:10], reqs[10:20], reqs[20:30]

	// One goroutine per role, each working through its requesters one after the other: a single user does not fire ten
	// Blocks in the same millisecond (10 simultaneous Blocks by one account all write the same graph doc and the losers
	// answer a retryable "temporarily busy"; that is contention by design, not what this test is about).
	errs := runConcurrently(4, func(i int) error {
		ctx := context.Background()
		switch i {
		case 0:
			_, err := pendingJob(w, 0).Run(ctx, "uid-p")
			return err
		case 1:
			for _, r := range withdrawers {
				if _, err := w.graph.Unfollow(ctx, r, key2, "uid-p"); err != nil {
					return err
				}
			}
		case 2:
			for _, r := range blocked {
				if _, err := w.graph.Block(ctx, "uid-p", key3, r); err != nil {
					return err
				}
			}
		default:
			for _, r := range manual {
				if _, err := w.graph.RespondToFollowRequest(ctx, "uid-p", key1, r, true); err != nil {
					return err
				}
			}
		}
		return nil
	})
	for i, err := range errs {
		if err != nil {
			t.Errorf("racer %d: %v", i, err)
		}
	}
	if out, err := pendingJob(w, 0).Run(context.Background(), "uid-p"); err != nil || out != "done" {
		t.Fatalf("a final run = %q, %v", out, err)
	}
	if got := pendingCount(t, w); got != 0 {
		t.Errorf("pending = %d, want 0", got)
	}
	isBlocked := map[string]bool{}
	for _, b := range blocked {
		isBlocked[b] = true
	}
	edges := int64(0)
	for _, r := range reqs {
		assertRequestInvariants(t, w, false, [2]string{r, "uid-p"})
		edge := hasEdge(t, w, r, "uid-p")
		if edge {
			edges++
		}
		if isBlocked[r] && edge {
			t.Errorf("blocked requester %s still follows uid-p", r)
		}
	}
	if _, followers := storedCounts(t, w, "uid-p"); followers != edges {
		t.Errorf("followersCount = %d, edges = %d", followers, edges)
	}
	if edges < 10 {
		t.Errorf("only %d edges: the 10 untouched requesters must all follow", edges)
	}
}

// TestW335b_PrivacyPublic_AtCapRequestersAreRecountedEveryRun: a requester at the 5,000 following cap keeps a pending
// request (ADR-0025 D7: nothing written, the target may decline), so it never drops out of the query. Every rerun
// re-reads it: the cost is the same on every delivery (no growth, no writes), the outcome stays "done", and healthy
// requesters are accepted once.
func TestW335b_PrivacyPublic_AtCapRequestersAreRecountedEveryRun(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	reqs := pendingTo(t, w, 5)
	capped := reqs[:3]
	for _, c := range capped {
		if _, err := w.client.Collection("graph").Doc(c).Update(context.Background(), []firestore.Update{
			{Path: "following", Value: firestore.ArrayUnion(toAny(padUIDs(5000))...)}}); err != nil {
			t.Fatal(err)
		}
	}
	unprotect(t, w, "uid-p")

	var costs []*budget.Counter
	for run := 1; run <= 3; run++ {
		out, c := runJob(t, w, ev)
		costs = append(costs, c)
		if out != "done" {
			t.Fatalf("run %d outcome = %q", run, out)
		}
		t.Logf("BUDGET privacy_public run %d (3 at cap, 2 healthy): reads=%d writes=%d deletes=%d", run, c.Reads(), c.Writes(), c.Deletes())
		if got := pendingCount(t, w); got != 3 {
			t.Errorf("run %d: pending = %d, want the 3 at-cap requests to stay", run, got)
		}
	}
	// Run 1 accepts 2; runs 2 and 3 re-read the 3 stuck requests (users 1 + request 1 + requester graph 1 each) and write nothing.
	budgettest.Assert(t, "privacy_public rerun with 3 at cap", costs[1], budgettest.Budget{Reads: 1 + 3*2, Writes: 0, Deletes: 0})
	if costs[1].Reads() != costs[2].Reads() || costs[2].Writes() != 0 {
		t.Errorf("rerun costs differ: %d then %d reads, %d writes; want a stable re-read and no writes", costs[1].Reads(), costs[2].Reads(), costs[2].Writes())
	}
	if _, followers := counts(t, w, "uid-p"); followers != 2 {
		t.Errorf("followersCount = %d, want 2", followers)
	}
	requireEachOnce(t, countAccepted(ev), reqs[3:])
	for _, c := range capped {
		assertRequestInvariants(t, w, true, [2]string{c, "uid-p"})
	}
}

// TestW335b_PrivacyPublic_AtCapRequestersNeverDropOut is a scale model of the same fact at a page size of 1 (O-1 in the
// W3-35b report): a delivery whose first 50 pages are all requests that cannot be accepted ends in ErrPrivacyPublicMore
// (nack) and so does every redelivery, until the target declines them. At the production page of 100 this needs more
// than 5,000 stuck requests at once, and a request is stuck only while its requester follows 5,000 accounts, so this
// is characterization, not a defect at Stage 0.
func TestW335b_PrivacyPublic_AtCapRequestersNeverDropOut(t *testing.T) {
	w := newWired(t)
	n := graph.PrivacyPublicMaxPagesForTest + 1
	reqs := pendingTo(t, w, n)
	for _, c := range reqs {
		if _, err := w.client.Collection("graph").Doc(c).Update(context.Background(), []firestore.Update{
			{Path: "following", Value: firestore.ArrayUnion(toAny(padUIDs(5000))...)}}); err != nil {
			t.Fatal(err)
		}
	}
	unprotect(t, w, "uid-p")
	job := pendingJob(w, 1)
	for run := 1; run <= 2; run++ {
		ctx, c := budget.WithCounter(context.Background())
		_, err := job.Run(ctx, "uid-p")
		if !errors.Is(err, graph.ErrPrivacyPublicMore) {
			t.Fatalf("run %d err = %v, want ErrPrivacyPublicMore", run, err)
		}
		t.Logf("run %d nacked after %d reads, %d writes", run, c.Reads(), c.Writes())
		if c.Writes() != 0 {
			t.Errorf("run %d wrote %d with nothing acceptable", run, c.Writes())
		}
	}
	// The owner clears the backlog by declining; the next delivery is done.
	for _, r := range reqs {
		if _, err := w.graph.RespondToFollowRequest(context.Background(), "uid-p", key1, r, false); err != nil {
			t.Fatal(err)
		}
	}
	if out, err := job.Run(context.Background(), "uid-p"); err != nil || out != "done" {
		t.Fatalf("after declining everything: %q, %v", out, err)
	}
}

// storedCounts reads followingCount and followersCount from Firestore, not through an instance's profile cache: after a race
// on two instances the other instance legitimately serves its cached profile until the TTL.
func storedCounts(t *testing.T, w wired, uid string) (following, followers int64) {
	t.Helper()
	snap, err := w.client.Collection("users").Doc(uid).Get(context.Background())
	if err != nil {
		t.Fatalf("read users/%s: %v", uid, err)
	}
	return intField(snap, "followingCount"), intField(snap, "followersCount")
}
