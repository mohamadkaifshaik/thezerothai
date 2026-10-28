//go:build integration

// purge_requests_integration_test.go exercises the `follow_requests` eraser step and export section against the
// Firestore emulator (ADR-0025 D11, ticket W3-32). Nothing in the product writes followRequests yet (W3-27), so the
// fixtures write the documents and the matching graph.requested entries directly, in the ADR-0025 D2 shape.
package graph_test

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

var reqBase = time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)

// seedRequest writes followRequests/{from}_{to} and, when the requester has a graph doc, its requested entry (I-R).
func seedRequest(t *testing.T, client *firestore.Client, from, to string, age time.Duration, withRequestedEntry bool) {
	t.Helper()
	ctx := context.Background()
	_, err := client.Collection("followRequests").Doc(from+"_"+to).Set(ctx, map[string]any{"followerId": from, "followeeId": to, "createdAt": reqBase.Add(-age)})
	if err != nil {
		t.Fatal(err)
	}
	if withRequestedEntry {
		if _, err := client.Collection("graph").Doc(from).Update(ctx, []firestore.Update{{Path: "requested", Value: firestore.ArrayUnion(to)}}); err != nil {
			t.Fatal(err)
		}
	}
}

func countRequests(t *testing.T, client *firestore.Client, field, uid string) int {
	t.Helper()
	docs, err := client.Collection("followRequests").Where(field, "==", uid).Limit(1000).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

func requestedOf(t *testing.T, client *firestore.Client, uid string) []string {
	t.Helper()
	snap, err := client.Collection("graph").Doc(uid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var d struct {
		Requested []string `firestore:"requested"`
	}
	if err := snap.DataTo(&d); err != nil {
		t.Fatal(err)
	}
	return d.Requested
}

// runRequestPurge loops the step to completion on one counter and returns it with the number of calls.
func runRequestPurge(t *testing.T, e *graph.RequestEraser, uid string) (*budget.Counter, int) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	var cp graph.RequestCheckpoint
	for calls := 1; calls <= 20; calls++ {
		next, done, err := e.PurgeUser(ctx, uid, cp)
		if err != nil {
			t.Fatalf("PurgeUser call %d: %v", calls, err)
		}
		if done {
			return counter, calls
		}
		cp = next
	}
	t.Fatal("the follow_requests step did not finish in 20 calls")
	return nil, 0
}

func TestRequestEraser_Integration(t *testing.T) {
	// out is how many outgoing requests the account has; in is how many incoming requests have a live requester
	// graph doc; ghost is how many incoming requesters have no graph doc (purged earlier).
	tests := []struct {
		name            string
		out, in, ghosts int
		wantCalls       int
		budget          budgettest.Budget
	}{
		// Minimum: 1 empty query per side, 0 writes.
		{"nothing", 0, 0, 0, 2, budgettest.Budget{Reads: 2}},
		{"one each way", 1, 1, 0, 2, budgettest.Budget{Reads: 2, Writes: 1, Deletes: 2}},
		// 501 outgoing = pages of 500 + 1, then 3 incoming (2 live, 1 ghost): 501 + 3 doc reads, +3 for the
		// requester-graph fallback after the ghost fails the first batch; the short incoming page ends the step.
		{"501 outgoing, 2 incoming and a ghost", 501, 2, 1, 3, budgettest.Budget{Reads: 501 + 3 + 3, Writes: 2, Deletes: 501 + 3}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := newWired(t)
			w.SkipInvariantSweep("raw followRequests seeding: ghost requesters have no graph docs by design")
			ctx := context.Background()
			mustCreateProfile(t, w.identity, "uid-u", "useru")
			var live []string
			for i := 0; i < tt.in; i++ {
				u := fmt.Sprintf("uid-in%d", i)
				mustCreateProfile(t, w.identity, u, fmt.Sprintf("user_in%d", i))
				seedRequest(t, w.client, u, "uid-u", time.Duration(i)*time.Minute, true)
				live = append(live, u)
			}
			for i := 0; i < tt.ghosts; i++ {
				seedRequest(t, w.client, fmt.Sprintf("uid-ghost%d", i), "uid-u", time.Hour, false)
			}
			for i := 0; i < tt.out; i++ {
				seedRequest(t, w.client, "uid-u", fmt.Sprintf("uid-tgt%03d", i), time.Duration(i)*time.Second, false)
			}
			// An unrelated request that names neither side stays untouched.
			seedRequest(t, w.client, "uid-other", "uid-elsewhere", time.Minute, false)

			e := graph.NewRequestEraser(w.graph.repo)
			counter, calls := runRequestPurge(t, e, "uid-u")
			t.Logf("BUDGET follow_requests step out=%d in=%d ghost=%d calls=%d reads=%d writes=%d deletes=%d", tt.out, tt.in, tt.ghosts, calls, counter.Reads(), counter.Writes(), counter.Deletes())
			budgettest.Assert(t, "follow_requests step", counter, tt.budget)
			if calls != tt.wantCalls {
				t.Errorf("calls = %d, want %d", calls, tt.wantCalls)
			}
			if counter.Reads() < 2 {
				t.Errorf("reads = %d, the step reads at least once per side", counter.Reads())
			}

			if n := countRequests(t, w.client, "followerId", "uid-u") + countRequests(t, w.client, "followeeId", "uid-u"); n != 0 {
				t.Errorf("%d request docs naming uid-u remain", n)
			}
			for _, u := range live {
				if got := requestedOf(t, w.client, u); slices.Contains(got, "uid-u") {
					t.Errorf("graph/%s.requested still names uid-u: %v", u, got)
				}
			}
			for i := 0; i < tt.ghosts; i++ {
				snap, err := w.client.Collection("graph").Doc(fmt.Sprintf("uid-ghost%d", i)).Get(ctx)
				if err == nil && snap.Exists() {
					t.Errorf("the purge recreated graph/uid-ghost%d", i)
				}
			}
			if n := countRequests(t, w.client, "followerId", "uid-other"); n != 1 {
				t.Errorf("unrelated request count = %d, want 1", n)
			}

			// A replay (redelivery after completion) is the minimum: 2 reads, 0 writes.
			again, _ := runRequestPurge(t, e, "uid-u")
			budgettest.Assert(t, "follow_requests replay", again, budgettest.Budget{Reads: 2})
		})
	}
}

func TestExportRequests_Integration(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("raw followRequests seeding")
	for _, u := range []string{"uid-u", "uid-a", "uid-b", "uid-c", "uid-d"} {
		mustCreateProfile(t, w.identity, u, "user_"+u[4:])
	}

	// Empty: two queries, both arrays present (never null).
	measured(t, "ExportRequests empty", budgettest.Budget{Reads: 2}, func(ctx context.Context) {
		got, err := w.graph.repo.ExportRequests(ctx, "uid-u")
		if err != nil {
			t.Fatal(err)
		}
		if got.Sent == nil || got.Received == nil || len(got.Sent)+len(got.Received) != 0 {
			t.Errorf("empty export = %+v, want two empty non-nil slices", got)
		}
	})

	// u asked a (older) and b (newer); c (older) and d (newer) asked u.
	seedRequest(t, w.client, "uid-u", "uid-a", 2*time.Hour, true)
	seedRequest(t, w.client, "uid-u", "uid-b", time.Hour, true)
	seedRequest(t, w.client, "uid-c", "uid-u", 3*time.Hour, true)
	seedRequest(t, w.client, "uid-d", "uid-u", 30*time.Minute, true)

	// 4 request docs + 4 distinct handle lookups.
	measured(t, "ExportRequests 2 sent 2 received", budgettest.Budget{Reads: 4 + 4}, func(ctx context.Context) {
		got, err := w.graph.repo.ExportRequests(ctx, "uid-u")
		if err != nil {
			t.Fatal(err)
		}
		ids := func(rows []graph.RequestExportRow) []string {
			var out []string
			for _, r := range rows {
				out = append(out, r.UserID+":"+r.Handle)
			}
			return out
		}
		if want := []string{"uid-b:user_b", "uid-a:user_a"}; !slices.Equal(ids(got.Sent), want) {
			t.Errorf("sent = %v, want %v (newest first)", ids(got.Sent), want)
		}
		if want := []string{"uid-d:user_d", "uid-c:user_c"}; !slices.Equal(ids(got.Received), want) {
			t.Errorf("received = %v, want %v (newest first)", ids(got.Received), want)
		}
		if !got.Sent[0].RequestedAt.Equal(reqBase.Add(-time.Hour)) {
			t.Errorf("requestedAt = %v, want %v", got.Sent[0].RequestedAt, reqBase.Add(-time.Hour))
		}
	})
}
