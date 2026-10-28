//go:build integration

// privacy_public_integration_test.go exercises the W3-28b privacy_public job against the Firestore emulator (ADR-0025
// D8, D9): 0, 1, 100, 101 and 250 pending requests with the documented budget, a redelivery, a re-protect before and in
// the middle of a run, a requester at the following cap and a requester that is gone. The full chain through
// apiserver.Build (listener, Pub/Sub, push endpoint) is apiserver/w328b_privacy_public_integration_test.go.
package graph_test

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// pendingTo protects uid-p and makes n requesters request it through the real Follow path. Requesters are warmed in
// the Directory cache, as on an instance that served them recently, so the job's own cost is measured.
func pendingTo(t *testing.T, w wired, n int) []string {
	t.Helper()
	mustCreateProfile(t, w.identity, "uid-p", "userp")
	protect(t, w, "uid-p")
	reqs := mustCreateUsers(t, w.identity, "r", n)
	for _, r := range reqs {
		request(t, w, r, "uid-p")
	}
	if n > 0 {
		warmProfiles(t, w, reqs...)
	}
	return reqs
}

func unprotect(t *testing.T, w wired, uid string) { seedUserField(t, w, uid, "isPrivate", false) }

func pendingCount(t *testing.T, w wired) int {
	t.Helper()
	n, err := w.graph.counter.PendingFollowRequests(context.Background(), "uid-p")
	if err != nil {
		t.Fatal(err)
	}
	return int(n)
}

func runJob(t *testing.T, w wired, ev graph.FollowEvents) (string, *budget.Counter) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	out, err := w.graph.privacyJob(w.graph.repo).Run(ctx, "uid-p")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return out, counter
}

func TestPrivacyPublic_Integration_Counts(t *testing.T) {
	// reads = per page 1 (users) + 2 per request (the request inside the transaction, the requester graph); a run whose
	// last page is exactly full adds one empty page (users 1 + the empty query 1). writes = 3 per request + 1 per page
	// that accepted anything. deletes = 1 per request.
	cases := []struct {
		n                    int
		reads, writes, pages int
	}{
		{0, 2, 0, 1},
		{1, 1 + 2, 3 + 1, 1},
		{100, (1 + 200) + 2, 300 + 1, 2},
		{101, (1 + 200) + (1 + 2), 303 + 2, 2},
		{250, (1 + 200) + (1 + 200) + (1 + 100), 750 + 3, 3},
	}
	for _, tc := range cases {
		t.Run(fmt.Sprintf("%d pending", tc.n), func(t *testing.T) {
			ev := &acceptRecorder{}
			w := newWired(t, withEvents(ev))
			reqs := pendingTo(t, w, tc.n)
			unprotect(t, w, "uid-p")

			out, c := runJob(t, w, ev)
			t.Logf("BUDGET privacy_public n=%d reads=%d writes=%d deletes=%d pages=%d", tc.n, c.Reads(), c.Writes(), c.Deletes(), tc.pages)
			if out != "done" {
				t.Errorf("outcome = %q, want done", out)
			}
			budgettest.Assert(t, "privacy_public", c, budgettest.Budget{Reads: int64(tc.reads), Writes: int64(tc.writes), Deletes: int64(tc.n)})
			if c.Reads() != int64(tc.reads) || c.Writes() != int64(tc.writes) || c.Deletes() != int64(tc.n) {
				t.Errorf("cost = %d/%d/%d, want exactly %d/%d/%d", c.Reads(), c.Writes(), c.Deletes(), tc.reads, tc.writes, tc.n)
			}
			if got := pendingCount(t, w); got != 0 {
				t.Errorf("requests left = %d, want 0", got)
			}
			if _, followers := counts(t, w, "uid-p"); followers != int64(tc.n) {
				t.Errorf("followersCount = %d, want exactly %d", followers, tc.n)
			}
			if len(ev.accepted) != tc.n {
				t.Errorf("FollowRequestAccepted calls = %d, want %d", len(ev.accepted), tc.n)
			}
			for _, r := range reqs {
				assertRequestInvariants(t, w, false, [2]string{r, "uid-p"})
				if !docExists(t, w.client, "follows/"+r+"_uid-p") {
					t.Fatalf("no edge %s -> uid-p", r)
				}
			}
			if len(reqs) > 0 {
				if following, _ := counts(t, w, reqs[0]); following != 1 {
					t.Errorf("requester followingCount = %d, want 1", following)
				}
			}

			// A redelivery is a no-op: no edge twice, no counter doubled, one empty page.
			ev.accepted = nil
			out, c = runJob(t, w, ev)
			budgettest.Assert(t, "privacy_public redelivery", c, budgettest.Budget{Reads: 2, Writes: 0, Deletes: 0})
			if _, followers := counts(t, w, "uid-p"); out != "done" || followers != int64(tc.n) || len(ev.accepted) != 0 {
				t.Errorf("redelivery: outcome %q followersCount %d events %d, want done / %d / 0", out, followers, len(ev.accepted), tc.n)
			}
		})
	}
}

func TestPrivacyPublic_Integration_ReprotectedBeforeRun(t *testing.T) {
	w := newWired(t)
	reqs := pendingTo(t, w, 3) // still protected
	out, c := runJob(t, w, nil)
	budgettest.Assert(t, "privacy_public protected", c, budgettest.Budget{Reads: 1, Writes: 0, Deletes: 0})
	if out != "stopped:protected" || pendingCount(t, w) != 3 {
		t.Fatalf("outcome %q pending %d, want stopped:protected / 3", out, pendingCount(t, w))
	}
	for _, r := range reqs {
		assertRequestInvariants(t, w, true, [2]string{r, "uid-p"})
	}
}

// reprotectOnAccept protects uid-p again as soon as the first page has committed and its notifications are emitted
// (afterCommit runs between pages), which is exactly "the owner re-protects while the job runs".
type reprotectOnAccept struct {
	*acceptRecorder
	w    wired
	once sync.Once
}

func (r *reprotectOnAccept) FollowRequestAccepted(ctx context.Context, target, requester string, at time.Time) {
	r.acceptRecorder.FollowRequestAccepted(ctx, target, requester, at)
	r.once.Do(func() {
		if _, err := r.w.client.Collection("users").Doc("uid-p").Update(ctx, []firestore.Update{{Path: "isPrivate", Value: true}}); err != nil {
			panic(err)
		}
	})
}

func TestPrivacyPublic_Integration_ReprotectedMidRun(t *testing.T) {
	rec := &acceptRecorder{}
	ev := &reprotectOnAccept{acceptRecorder: rec}
	w := newWired(t, withEvents(ev))
	ev.w = w
	reqs := pendingTo(t, w, 150)
	unprotect(t, w, "uid-p")

	out, _ := runJob(t, w, ev)
	if out != "stopped:protected" {
		t.Fatalf("outcome = %q, want stopped:protected", out)
	}
	if got := pendingCount(t, w); got != 50 {
		t.Errorf("requests left = %d, want 50 (page 1 accepted, page 2 refused)", got)
	}
	if _, followers := counts(t, w, "uid-p"); followers != 100 || len(rec.accepted) != 100 {
		t.Errorf("followersCount %d events %d, want 100 / 100", followers, len(rec.accepted))
	}
	accepted := 0
	for _, r := range reqs {
		edge := docExists(t, w.client, "follows/"+r+"_uid-p")
		if edge {
			accepted++
		}
		assertRequestInvariants(t, w, !edge, [2]string{r, "uid-p"})
	}
	if accepted != 100 {
		t.Errorf("edges = %d, want 100", accepted)
	}
}

func TestPrivacyPublic_Integration_CapInactiveAndGone(t *testing.T) {
	ev := &acceptRecorder{}
	w := newWired(t, withEvents(ev))
	reqs := pendingTo(t, w, 4)
	capped, suspended, gone, ok := reqs[0], reqs[1], reqs[2], reqs[3]
	// capped follows 5,000 accounts already (synthetic uids; the invariant checker ignores pads).
	if _, err := w.client.Collection("graph").Doc(capped).Update(context.Background(),
		[]firestore.Update{{Path: "following", Value: firestore.ArrayUnion(toAny(padUIDs(5000))...)}}); err != nil {
		t.Fatal(err)
	}
	seedUserField(t, w, suspended, "status", "SUSPENDED")
	// gone: the account purge removed its graph doc and users doc but not yet the request (its eraser runs it later).
	w.SkipInvariantSweep("a requester whose accounts docs are gone holds a request until its eraser step runs")
	if _, err := w.client.Collection("graph").Doc(gone).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := w.client.Collection("users").Doc(gone).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	w.identity.(identity.Directory).Forget(gone, suspended)
	unprotect(t, w, "uid-p")

	out, _ := runJob(t, w, ev)
	if out != "done" {
		t.Fatalf("outcome = %q", out)
	}
	if !docExists(t, w.client, "follows/"+ok+"_uid-p") || len(ev.accepted) != 1 || ev.accepted[0][1] != ok {
		t.Errorf("the healthy requester must be accepted alone; events = %v", ev.accepted)
	}
	for _, r := range []string{suspended, gone} {
		if docExists(t, w.client, "follows/"+r+"_uid-p") || docExists(t, w.client, "followRequests/"+r+"_uid-p") {
			t.Errorf("%s: an inactive requester gets no edge and no leftover request", r)
		}
	}
	if contains(requestedOf(t, w.client, suspended), "uid-p") {
		t.Error("I-R: the suspended requester's requested[] still names uid-p")
	}
	// The capped requester's request stays (D7: nothing written), and no edge exists.
	if docExists(t, w.client, "follows/"+capped+"_uid-p") || !docExists(t, w.client, "followRequests/"+capped+"_uid-p") {
		t.Error("a requester at the 5,000 cap keeps a pending request and gets no edge")
	}
	if _, followers := counts(t, w, "uid-p"); followers != 1 {
		t.Errorf("followersCount = %d, want 1", followers)
	}
}

func toAny(s []string) []any {
	out := make([]any, len(s))
	for i, v := range s {
		out[i] = v
	}
	return out
}
