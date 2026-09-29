//go:build integration

// purge_integration_test.go exercises graph.Eraser against the Firestore emulator (ADR-0008 T11/D10):
// full cascade, crash-resume, replay safety, concurrent runs and missing counterparts.
package graph_test

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// purgeToCompletion loops PurgeUser from cp until done, retrying transient errors (a concurrent run can make
// a batch fail its Exists precondition; the next call re-queries).
func purgeToCompletion(t *testing.T, repo *graph.FirestoreRepo, uid string, cp graph.Checkpoint) {
	t.Helper()
	failures := 0
	for i := 0; i < 200; i++ {
		next, done, err := repo.PurgeUser(context.Background(), uid, cp)
		if err != nil {
			if failures++; failures > 10 {
				t.Errorf("PurgeUser: %v", err)
				return
			}
			continue
		}
		if done {
			return
		}
		cp = next
	}
	t.Error("PurgeUser did not finish in 200 calls")
}

func countFollowDocs(t *testing.T, client *firestore.Client, field, uid string) int {
	t.Helper()
	docs, err := client.Collection("follows").Where(field, "==", uid).Limit(1000).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

// purgeFixture: U follows f1..f3, is followed by g1,g2, blocks b1, is blocked by c1, and is muted by m1.
func purgeFixture(t *testing.T) wired {
	t.Helper()
	w := newWired(t)
	for _, u := range []string{"uid-u", "uid-f1", "uid-f2", "uid-f3", "uid-g1", "uid-g2", "uid-b1", "uid-c1", "uid-m1"} {
		mustCreateProfile(t, w.identity, u, "user"+u[4:])
	}
	ctx := context.Background()
	steps := []error{}
	call := func(_ graph.Relationship, err error) { steps = append(steps, err) }
	for _, f := range []string{"uid-f1", "uid-f2", "uid-f3"} {
		call(w.graph.Follow(ctx, "uid-u", key1, f))
	}
	for _, g := range []string{"uid-g1", "uid-g2"} {
		call(w.graph.Follow(ctx, g, key1, "uid-u"))
	}
	call(w.graph.Block(ctx, "uid-u", key2, "uid-b1"))
	call(w.graph.Block(ctx, "uid-c1", key2, "uid-u"))
	call(w.graph.Mute(ctx, "uid-m1", key3, "uid-u"))
	for i, err := range steps {
		if err != nil {
			t.Fatalf("fixture step %d: %v", i, err)
		}
	}
	return w
}

func assertPurged(t *testing.T, w wired) {
	t.Helper()
	if n := countFollowDocs(t, w.client, "followerId", "uid-u") + countFollowDocs(t, w.client, "followeeId", "uid-u"); n != 0 {
		t.Errorf("%d follows docs still reference uid-u", n)
	}
	for _, f := range []string{"uid-f1", "uid-f2", "uid-f3"} {
		if fg, fr := counts(t, w, f); fg != 0 || fr != 0 {
			t.Errorf("%s counters = %d/%d, want 0/0", f, fg, fr)
		}
	}
	for _, g := range []string{"uid-g1", "uid-g2"} {
		if fg, fr := counts(t, w, g); fg != 0 || fr != 0 {
			t.Errorf("%s counters = %d/%d, want 0/0 (decremented exactly once)", g, fg, fr)
		}
		if a := graphArrays(t, w.client, g); contains(a["following"], "uid-u") {
			t.Errorf("%s still follows uid-u: %v", g, a)
		}
	}
	if a := graphArrays(t, w.client, "uid-b1"); contains(a["blockedBy"], "uid-u") {
		t.Errorf("b1.blockedBy = %v", a)
	}
	if a := graphArrays(t, w.client, "uid-c1"); contains(a["blocked"], "uid-u") {
		t.Errorf("c1.blocked = %v", a)
	}
	if docExists(t, w.client, "graph/uid-u") {
		t.Error("graph/uid-u must be deleted")
	}
	// Muted entries are unindexed arrays: cleaned lazily, so m1's mute of the purged user may remain.
	if a := graphArrays(t, w.client, "uid-m1"); !contains(a["muted"], "uid-u") {
		t.Errorf("m1.muted = %v (expected the lazy-clean-up leftover)", a)
	}
}

func TestPurgeUser_Integration_FullCascade(t *testing.T) {
	w := purgeFixture(t)
	purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
	assertPurged(t, w)

	// Replaying a finished purge (Pub/Sub redelivery) is a harmless no-op.
	purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
	assertPurged(t, w)
}

func TestPurgeUser_Integration_CrashAfterFirstBatchThenResume(t *testing.T) {
	w := purgeFixture(t)
	ctx := context.Background()
	// First batch (step 1), then the process "dies": nothing but the checkpoint survives.
	cp, done, err := w.graph.repo.PurgeUser(ctx, "uid-u", graph.Checkpoint{})
	if err != nil || done {
		t.Fatalf("first batch: %v done=%v", err, done)
	}
	// Resume both with the returned checkpoint and, separately in the same test, from scratch (lost checkpoint).
	purgeToCompletion(t, w.graph.repo, "uid-u", cp)
	assertPurged(t, w)
	purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
	assertPurged(t, w)
}

func TestPurgeUser_Integration_LostCheckpointMidPurgeDoesNotDoubleDecrement(t *testing.T) {
	w := purgeFixture(t)
	ctx := context.Background()
	// Run steps 1 and 2 to completion, then restart from zero: edges are gone, counters must stay exact.
	cp := graph.Checkpoint{}
	for cp.Step < 3 {
		var err error
		if cp, _, err = w.graph.repo.PurgeUser(ctx, "uid-u", cp); err != nil {
			t.Fatal(err)
		}
	}
	purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
	assertPurged(t, w)
}

func TestPurgeUser_Integration_ConcurrentRunsNoDoubleDecrement(t *testing.T) {
	w := purgeFixture(t)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
		}()
	}
	wg.Wait()
	assertPurged(t, w)
}

func TestPurgeUser_Integration_StepBudgets(t *testing.T) {
	w := purgeFixture(t)
	ctx, counter := budget.WithCounter(context.Background())
	if _, _, err := w.graph.repo.PurgeUser(ctx, "uid-u", graph.Checkpoint{}); err != nil {
		t.Fatal(err)
	}
	// Step 1 with 3 outgoing edges: 3 edge reads, 3 followee counter writes, 3 edge deletes.
	budgettest.Assert(t, "PurgeUser step 1 (3 edges)", counter, budgettest.Budget{Reads: 3, Writes: 3, Deletes: 3})
}

func TestPurgeUser_Integration_MissingCounterpartIsSkipped(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-u", "useru")
	mustCreateProfile(t, w.identity, "uid-real", "userreal")
	ctx := context.Background()
	if _, err := w.graph.Follow(ctx, "uid-u", key1, "uid-real"); err != nil {
		t.Fatal(err)
	}
	// Edges whose counterpart was already purged: no users/graph doc for "ghost".
	seedEdge(t, w, "uid-u", "ghost-followee", time.Now().UTC())
	seedEdge(t, w, "ghost-follower", "uid-u", time.Now().UTC())

	purgeToCompletion(t, w.graph.repo, "uid-u", graph.Checkpoint{})
	if n := countFollowDocs(t, w.client, "followerId", "uid-u") + countFollowDocs(t, w.client, "followeeId", "uid-u"); n != 0 {
		t.Errorf("%d follows docs left", n)
	}
	if docExists(t, w.client, "users/ghost-followee") || docExists(t, w.client, "graph/ghost-follower") {
		t.Error("purge must never resurrect a deleted counterpart doc")
	}
	if _, fr := counts(t, w, "uid-real"); fr != 0 {
		t.Errorf("real followee followersCount = %d, want 0", fr)
	}
}

// TestPurgeUser_Integration_MultiBatch runs step 1 over more than one page (250 edges/batch).
func TestPurgeUser_Integration_MultiBatch(t *testing.T) {
	if testing.Short() {
		t.Skip("creates 260 profiles")
	}
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-u", "useru")
	const n = 260
	for i := 0; i < n; i++ {
		f := fmt.Sprintf("uid-x%03d", i)
		mustCreateProfile(t, w.identity, f, fmt.Sprintf("userx%03d", i))
		// Seeded directly: real Follow calls would trip the new-account follow quota (50/day).
		seedEdge(t, w, "uid-u", f, time.Now().UTC())
	}
	calls := 0
	cp := graph.Checkpoint{}
	for {
		next, done, err := w.graph.repo.PurgeUser(context.Background(), "uid-u", cp)
		if err != nil {
			t.Fatal(err)
		}
		calls++
		if done {
			break
		}
		cp = next
	}
	if calls < 3 {
		t.Errorf("calls = %d, want the 260 edges split across at least two step-1 batches", calls)
	}
	for i := 0; i < n; i += 37 {
		snap, err := w.client.Doc(fmt.Sprintf("users/uid-x%03d", i)).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if v, _ := snap.DataAt("followersCount"); v != int64(-1) {
			t.Errorf("uid-x%03d followersCount = %d, want -1 (seeded from 0, decremented exactly once)", i, v)
		}
	}
	if countFollowDocs(t, w.client, "followerId", "uid-u") != 0 {
		t.Error("edges left")
	}
}
