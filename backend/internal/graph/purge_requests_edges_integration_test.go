//go:build integration

// purge_requests_edges_integration_test.go is the W3-35b attack list against the `follow_requests` eraser and export
// (ADR-0025 D11, W3-32): the page boundaries (exactly 250 incoming and exactly 500 outgoing, each a full page that needs
// one more empty query), a requester whose graph doc is gone between calls and inside a page, a redelivery after the step
// finished, two loops on one account at the same time, a requester that keeps requests to other accounts, and the export
// across its 500-row page.
//
// "Graph doc gone mid-page" cannot be interleaved inside one batch without a production seam, so it is approximated two
// ways: a ghost row inside a full 250 page, and a graph doc deleted between the outgoing and the incoming call.
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

// seedGraphWithRequested makes graph/{uid} for a requester that asked each of targets, without a users doc (the eraser never
// reads one).
func seedGraphWithRequested(t *testing.T, client *firestore.Client, uid string, targets ...string) {
	t.Helper()
	seedGraphArrays(t, client, uid, map[string]interface{}{"requested": targets})
}

// seedRequestDoc writes only the request doc (the requester side is seeded separately).
func seedRequestDoc(t *testing.T, client *firestore.Client, from, to string, age time.Duration) {
	t.Helper()
	if _, err := client.Collection("followRequests").Doc(from+"_"+to).Set(context.Background(),
		map[string]any{"followerId": from, "followeeId": to, "createdAt": reqBase.Add(-age)}); err != nil {
		t.Fatal(err)
	}
}

func TestW335b_RequestEraser_PageBoundaries(t *testing.T) {
	tests := []struct {
		name            string
		out, in, ghosts int
		calls           int
		budget          budgettest.Budget
	}{
		// 500 outgoing: one full page (500 deletes), the empty re-query moves on, the empty incoming query ends.
		{"exactly 500 outgoing", 500, 0, 0, 3, budgettest.Budget{Reads: 500 + 1 + 1, Deletes: 500}},
		// 250 incoming, all live: the batch is 250 deletes + 250 updates = exactly Firestore's 500; a full page needs the
		// extra empty query: calls = outgoing-empty, incoming-full, incoming-empty.
		{"exactly 250 incoming", 0, 250, 0, 3, budgettest.Budget{Reads: 1 + 250 + 1, Writes: 250, Deletes: 250}},
		// 250 incoming of which one requester has no graph doc: the first batch fails on the missing update, the fallback
		// reads the 250 requester graphs and commits again with the ghost's update left out.
		{"250 incoming with one ghost inside the page", 0, 249, 1, 3, budgettest.Budget{Reads: 1 + 250 + 250 + 1, Writes: 249, Deletes: 250}},
		{"250 incoming, every requester gone", 0, 0, 250, 3, budgettest.Budget{Reads: 1 + 250 + 250 + 1, Writes: 0, Deletes: 250}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := newWired(t)
			w.SkipInvariantSweep("raw followRequests seeding: ghost requesters have no graph docs by design")
			var live []string
			for i := 0; i < tt.in; i++ {
				u := fmt.Sprintf("uid-in%03d", i)
				seedGraphWithRequested(t, w.client, u, "uid-u")
				seedRequestDoc(t, w.client, u, "uid-u", time.Duration(i)*time.Second)
				live = append(live, u)
			}
			for i := 0; i < tt.ghosts; i++ {
				seedRequestDoc(t, w.client, fmt.Sprintf("uid-ghost%03d", i), "uid-u", time.Hour+time.Duration(i)*time.Second)
			}
			for i := 0; i < tt.out; i++ {
				seedRequestDoc(t, w.client, "uid-u", fmt.Sprintf("uid-tgt%03d", i), time.Duration(i)*time.Second)
			}

			e := graph.NewRequestEraser(w.graph.repo)
			counter, calls := runRequestPurge(t, e, "uid-u")
			t.Logf("BUDGET follow_requests boundary %q calls=%d reads=%d writes=%d deletes=%d", tt.name, calls, counter.Reads(), counter.Writes(), counter.Deletes())
			budgettest.Assert(t, "follow_requests boundary", counter, tt.budget)
			if counter.Reads() != tt.budget.Reads || counter.Writes() != tt.budget.Writes || counter.Deletes() != tt.budget.Deletes {
				t.Errorf("cost = %d/%d/%d, want exactly %d/%d/%d", counter.Reads(), counter.Writes(), counter.Deletes(), tt.budget.Reads, tt.budget.Writes, tt.budget.Deletes)
			}
			if calls != tt.calls {
				t.Errorf("calls = %d, want %d", calls, tt.calls)
			}
			if n := countRequests(t, w.client, "followerId", "uid-u") + countRequests(t, w.client, "followeeId", "uid-u"); n != 0 {
				t.Errorf("%d request docs naming uid-u remain", n)
			}
			for _, u := range live {
				if got := requestedOf(t, w.client, u); slices.Contains(got, "uid-u") {
					t.Fatalf("graph/%s.requested still names uid-u", u)
				}
			}
			for i := 0; i < tt.ghosts; i++ {
				if docExists(t, w.client, fmt.Sprintf("graph/uid-ghost%03d", i)) {
					t.Fatalf("the purge recreated graph/uid-ghost%03d", i)
				}
			}
		})
	}
}

// A requester whose graph doc is removed by its own account purge BETWEEN two calls of this step (the outgoing pass done,
// the incoming pass not started): the incoming pass drops the request without recreating the graph doc.
func TestW335b_RequestEraser_RequesterGoneBetweenCalls(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("raw followRequests seeding")
	ctx, counter := budget.WithCounter(context.Background())
	seedGraphWithRequested(t, w.client, "uid-live", "uid-u")
	seedGraphWithRequested(t, w.client, "uid-doomed", "uid-u")
	seedRequestDoc(t, w.client, "uid-live", "uid-u", time.Minute)
	seedRequestDoc(t, w.client, "uid-doomed", "uid-u", time.Hour)
	seedRequestDoc(t, w.client, "uid-u", "uid-tgt", time.Minute)

	e := graph.NewRequestEraser(w.graph.repo)
	cp, done, err := e.PurgeUser(ctx, "uid-u", graph.RequestCheckpoint{})
	if err != nil || done {
		t.Fatalf("call 1 = %+v, %v, %v", cp, done, err)
	}
	if _, err := w.client.Doc("graph/uid-doomed").Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	for calls := 2; !done && calls < 10; calls++ {
		if cp, done, err = e.PurgeUser(ctx, "uid-u", cp); err != nil {
			t.Fatalf("call %d: %v", calls, err)
		}
	}
	if !done {
		t.Fatal("the step did not finish")
	}
	if docExists(t, w.client, "graph/uid-doomed") {
		t.Error("the purge recreated graph/uid-doomed")
	}
	if n := countRequests(t, w.client, "followerId", "uid-u") + countRequests(t, w.client, "followeeId", "uid-u"); n != 0 {
		t.Errorf("%d request docs naming uid-u remain", n)
	}
	if got := requestedOf(t, w.client, "uid-live"); slices.Contains(got, "uid-u") {
		t.Errorf("graph/uid-live.requested = %v still names uid-u", got)
	}
	t.Logf("BUDGET follow_requests gone-between-calls reads=%d writes=%d deletes=%d", counter.Reads(), counter.Writes(), counter.Deletes())
}

// A redelivery after the step finished, from the beginning and from a stale checkpoint, is the 2-read minimum and writes
// nothing; a requester that also asked someone else keeps that request and that `requested` entry; the pair asked in
// both directions loses both docs.
func TestW335b_RequestEraser_RedeliveryKeepsOtherRequests(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("raw followRequests seeding")
	seedGraphWithRequested(t, w.client, "uid-r", "uid-u", "uid-other")
	seedRequestDoc(t, w.client, "uid-r", "uid-u", time.Minute)
	seedRequestDoc(t, w.client, "uid-r", "uid-other", time.Minute)
	seedGraphWithRequested(t, w.client, "uid-u", "uid-both")
	seedGraphWithRequested(t, w.client, "uid-both", "uid-u")
	seedRequestDoc(t, w.client, "uid-u", "uid-both", time.Minute)
	seedRequestDoc(t, w.client, "uid-both", "uid-u", time.Minute)

	e := graph.NewRequestEraser(w.graph.repo)
	runRequestPurge(t, e, "uid-u")
	if got := requestedOf(t, w.client, "uid-r"); !slices.Equal(got, []string{"uid-other"}) {
		t.Errorf("graph/uid-r.requested = %v, want only uid-other", got)
	}
	if !docExists(t, w.client, "followRequests/uid-r_uid-other") {
		t.Error("the purge deleted a request that does not name uid-u")
	}
	if got := requestedOf(t, w.client, "uid-both"); len(got) != 0 {
		t.Errorf("graph/uid-both.requested = %v, want empty", got)
	}
	if docExists(t, w.client, "followRequests/uid-u_uid-both") || docExists(t, w.client, "followRequests/uid-both_uid-u") {
		t.Error("a request in one of the two directions survived")
	}

	for _, cp := range []graph.RequestCheckpoint{{}, {Phase: 1}, {Phase: 2}} {
		ctx, c := budget.WithCounter(context.Background())
		for calls := 0; calls < 5; calls++ {
			next, done, err := e.PurgeUser(ctx, "uid-u", cp)
			if err != nil {
				t.Fatalf("redelivery from %+v: %v", cp, err)
			}
			if done {
				break
			}
			cp = next
		}
		budgettest.Assert(t, fmt.Sprintf("redelivery from checkpoint %+v", cp), c, budgettest.Budget{Reads: 2})
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("a redelivery wrote %d / deleted %d", c.Writes(), c.Deletes())
		}
	}
	if _, _, err := e.PurgeUser(context.Background(), "uid-u", graph.RequestCheckpoint{Phase: 9}); err == nil {
		t.Error("an unknown checkpoint phase was accepted")
	}
}

// Two loops of the step on one account at the same time (a redelivery while the first is still running): both finish, the
// end state is clean, no graph doc is recreated and no other account's request is touched.
func TestW335b_RequestEraser_ConcurrentLoops(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("raw followRequests seeding")
	const in, out = 300, 120
	for i := 0; i < in; i++ {
		u := fmt.Sprintf("uid-in%03d", i)
		if i%50 == 7 {
			seedRequestDoc(t, w.client, u, "uid-u", time.Duration(i)*time.Second) // a ghost: no graph doc
			continue
		}
		seedGraphWithRequested(t, w.client, u, "uid-u", "uid-keep")
		seedRequestDoc(t, w.client, u, "uid-u", time.Duration(i)*time.Second)
		seedRequestDoc(t, w.client, u, "uid-keep", time.Duration(i)*time.Second)
	}
	for i := 0; i < out; i++ {
		seedRequestDoc(t, w.client, "uid-u", fmt.Sprintf("uid-tgt%03d", i), time.Duration(i)*time.Second)
	}

	e1, e2 := graph.NewRequestEraser(w.graph.repo), graph.NewRequestEraser(w.graph.repo)
	errs := runConcurrently(2, func(i int) error {
		e := e1
		if i == 1 {
			e = e2
		}
		ctx := context.Background()
		var cp graph.RequestCheckpoint
		for calls := 0; calls < 30; calls++ {
			next, done, err := e.PurgeUser(ctx, "uid-u", cp)
			if err != nil {
				return err
			}
			if done {
				return nil
			}
			cp = next
		}
		return fmt.Errorf("loop %d did not finish", i)
	})
	for i, err := range errs {
		if err != nil {
			t.Errorf("loop %d: %v", i, err)
		}
	}
	if n := countRequests(t, w.client, "followerId", "uid-u") + countRequests(t, w.client, "followeeId", "uid-u"); n != 0 {
		t.Errorf("%d request docs naming uid-u remain", n)
	}
	if got := countRequests(t, w.client, "followeeId", "uid-keep"); got != 294 {
		// 300 requesters, 6 ghosts (i%50==7 gives i=7,57,107,157,207,257): 294 kept requests.
		t.Errorf("requests to uid-keep = %d, want 294 (untouched)", got)
	}
	for i := 0; i < in; i++ {
		u := fmt.Sprintf("uid-in%03d", i)
		if i%50 == 7 {
			if docExists(t, w.client, "graph/"+u) {
				t.Fatalf("the purge recreated graph/%s", u)
			}
			continue
		}
		if got := requestedOf(t, w.client, u); !slices.Equal(got, []string{"uid-keep"}) {
			t.Fatalf("graph/%s.requested = %v, want [uid-keep]", u, got)
		}
	}
}

// The export across its 500-row page: exactly 500 and 501 received requests (and sent), every row exactly once, newest
// first, none dropped at the page boundary, both arrays present. Handles are not seeded (no profiles), so no lookup row.
func TestW335b_ExportRequests_PageBoundaries(t *testing.T) {
	for _, n := range []int{500, 501} {
		t.Run(fmt.Sprintf("%d each way", n), func(t *testing.T) {
			w := newWired(t)
			w.SkipInvariantSweep("raw followRequests seeding")
			mustCreateProfile(t, w.identity, "uid-u", "useru")
			for i := 0; i < n; i++ {
				seedRequestDoc(t, w.client, fmt.Sprintf("uid-in%03d", i), "uid-u", time.Duration(i)*time.Second)
				seedRequestDoc(t, w.client, "uid-u", fmt.Sprintf("uid-out%03d", i), time.Duration(i)*time.Second)
			}
			ctx, c := budget.WithCounter(context.Background())
			got, err := w.graph.repo.ExportRequests(ctx, "uid-u")
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("BUDGET ExportRequests %d each way: reads=%d", n, c.Reads())
			if len(got.Sent) != n || len(got.Received) != n {
				t.Fatalf("rows sent/received = %d/%d, want %d each", len(got.Sent), len(got.Received), n)
			}
			seen := map[string]bool{}
			for i, r := range got.Received {
				if seen[r.UserID] {
					t.Fatalf("received row %s twice", r.UserID)
				}
				seen[r.UserID] = true
				if want := fmt.Sprintf("uid-in%03d", i); r.UserID != want {
					t.Fatalf("received[%d] = %s, want %s (newest first)", i, r.UserID, want)
				}
			}
			for i, r := range got.Sent {
				if want := fmt.Sprintf("uid-out%03d", i); r.UserID != want {
					t.Fatalf("sent[%d] = %s, want %s (newest first)", i, r.UserID, want)
				}
			}
			// Reads: 2 sides x n docs, plus an empty page query only when n is a multiple of the page (500: yes), plus the
			// handle lookups for 2n counterparts without profiles (one read per distinct id).
			docReads := int64(2 * n)
			if n%500 == 0 {
				docReads += 2
			}
			if c.Reads() < docReads {
				t.Errorf("reads = %d, below the %d request reads", c.Reads(), docReads)
			}
		})
	}
}
