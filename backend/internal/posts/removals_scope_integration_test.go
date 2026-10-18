//go:build integration

package posts

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// refreshReads is the shared refresh's reads the request logged (the refresh runs under a detached counter, RID-4).
func refreshReads(info *logger.RequestInfo) int64 {
	v, ok := info.Get("removal_log_reads")
	if !ok {
		return 0
	}
	n, _ := v.(int64)
	return n
}

// TestRemovalLog_SharedInstantBurstBudget is the B1 regression on the real repo, per feed (amendment 2026-10-18 (b)):
// a 120-entry single-timestamp burst by "spammer" costs the cold load once and one read per TTL after it; a viewer
// who does not show the spammer is never reset and pays only the 1-read window query; the spammer's own feed resets.
func TestRemovalLog_SharedInstantBurstBudget(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedSharedInstantRemovals(t, repo, 120)

	now := time.Now()
	log := NewRemovalLog(repo, time.Minute, func() time.Time { return now })
	cutoff := now.Add(-time.Hour)
	call := func(authors ...string) (ids []string, trunc bool, reqReads, refresh int64) {
		ictx, info := logger.WithRequestInfo(context.Background())
		ctx, c := budget.WithCounter(ictx)
		ids, trunc, err := log.RemovedSince(ctx, cutoff, RemovalScope{Authors: authors})
		if err != nil {
			t.Fatal(err)
		}
		return ids, trunc, c.Reads(), refreshReads(info)
	}

	ids, trunc, req, refresh := call("viewer")
	if trunc || len(ids) != 0 {
		t.Fatalf("viewer that does not show the spammer: ids=%d trunc=%v, want none/false", len(ids), trunc)
	}
	if refresh != RemovalMaxIDs || req != 1 {
		t.Fatalf("cold: refresh reads=%d (want %d, detached) request reads=%d (want 1: the empty window query)", refresh, RemovalMaxIDs, req)
	}
	if _, trunc, req, refresh = call("spammer"); !trunc || refresh != 0 || req > RemovalWindowWorstReads {
		t.Fatalf("spammer's own feed: trunc=%v refresh=%d request reads=%d, want a reset within %d reads", trunc, refresh, req, RemovalWindowWorstReads)
	}
	for step := 1; step <= 5; step++ {
		now = now.Add(time.Minute)
		if _, trunc, _, refresh = call("viewer"); trunc || refresh != 1 {
			t.Fatalf("TTL step %d: trunc=%v refresh reads=%d, want false/1", step, trunc, refresh)
		}
	}
}

// TestRemovalSource_WindowScopesByAuthor runs the per-feed window query on the emulator: author filter (== for one
// author, in for several), the (after, upTo] bounds, newest first, the Limit and the read charge.
func TestRemovalSource_WindowScopesByAuthor(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedSharedInstantRemovalsBy(t, repo, "alice", 3) // ids 1..3
	seedSharedInstantRemovalsBy(t, repo, "bob", 2)   // ids 1..2 again: overwrites two of alice's with bob's
	ctx := context.Background()
	all, err := repo.Newest(ctx, time.Now().Add(-time.Hour), 10)
	if err != nil || len(all) != 3 {
		t.Fatalf("seed: %d entries err=%v", len(all), err)
	}
	after, upTo := time.Now().Add(-time.Hour), time.Now().Add(time.Hour)

	cctx, c := budget.WithCounter(ctx)
	got, err := repo.Window(cctx, []string{"bob"}, after, upTo, 10)
	if err != nil || len(got) != 2 || got[0].AuthorID != "bob" {
		t.Fatalf("one author: %+v err=%v", got, err)
	}
	budgettest.Assert(t, "Window == author", c, budgettest.Budget{Reads: 2})

	cctx, c = budget.WithCounter(ctx)
	if got, err = repo.Window(cctx, []string{"alice", "bob", "nobody"}, after, upTo, 10); err != nil || len(got) != 3 {
		t.Fatalf("in: %+v err=%v", got, err)
	}
	budgettest.Assert(t, "Window in", c, budgettest.Budget{Reads: 3})

	cctx, c = budget.WithCounter(ctx)
	if got, err = repo.Window(cctx, []string{"alice", "bob"}, after, upTo, 2); err != nil || len(got) != 2 {
		t.Fatalf("limit: %+v err=%v", got, err)
	}
	budgettest.Assert(t, "Window limit", c, budgettest.Budget{Reads: 2})

	// Bounds: strictly after, and up to and including upTo.
	at := all[0].At
	if got, err = repo.Window(ctx, []string{"alice", "bob"}, at, upTo, 10); err != nil || len(got) != 0 {
		t.Fatalf("after == createdAt must exclude: %+v err=%v", got, err)
	}
	if got, err = repo.Window(ctx, []string{"alice", "bob"}, after, at, 10); err != nil || len(got) == 0 {
		t.Fatalf("upTo == createdAt must include: %+v err=%v", got, err)
	}
	cctx, c = budget.WithCounter(ctx)
	if got, err = repo.Window(cctx, []string{"nobody"}, after, upTo, 10); err != nil || len(got) != 0 {
		t.Fatalf("empty: %+v err=%v", got, err)
	}
	budgettest.Assert(t, "Window empty", c, budgettest.Budget{Reads: 1})
}

// TestRemovalLog_WritersStampTheAuthor: every writer records the post's author, RESTORED entries included.
func TestRemovalLog_WritersStampTheAuthor(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedPost(t, client, pid(1), "u-a", false, 1_700_000_000_000)
	seedPost(t, client, pid(2), "u-b", false, 1_700_000_000_001)
	seedPost(t, client, pid(3), "u-b", false, 1_700_000_000_002)
	now := time.Now()
	author := func(id string) string {
		snap, err := repo.removalRef(id).Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		var d removalDoc
		if err := snap.DataTo(&d); err != nil {
			t.Fatal(err)
		}
		return d.AuthorID
	}
	if _, err := repo.Takedown(context.Background(), pid(1), now); err != nil || author(pid(1)) != "u-a" {
		t.Fatalf("takedown author=%q err=%v", author(pid(1)), err)
	}
	if _, err := repo.Restore(context.Background(), pid(1), now); err != nil || author(pid(1)) != "u-a" {
		t.Fatalf("restore author=%q err=%v", author(pid(1)), err)
	}
	if _, done, err := repo.HideAuthor(context.Background(), "u-b", ModerationCheckpoint{}, now); err != nil || !done || author(pid(2)) != "u-b" || author(pid(3)) != "u-b" {
		t.Fatalf("hide: done=%v err=%v authors=%q,%q", done, err, author(pid(2)), author(pid(3)))
	}
	if _, done, err := repo.RestoreAuthor(context.Background(), "u-b", ModerationCheckpoint{}, now); err != nil || !done || author(pid(2)) != "u-b" {
		t.Fatalf("restore author: done=%v err=%v author=%q", done, err, author(pid(2)))
	}
}

// TestPurgeUser_DeletesTheUsersRemovalEntries (right to delete, ADR-0011 Q10): phase 2 removes exactly the entries
// whose authorId is the user, after the copies phase; other authors' entries stay. Deletes one per entry.
func TestPurgeUser_DeletesTheUsersRemovalEntries(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	withCopyPhase(repo, client)
	b := client.Batch()
	for i := range 3 {
		b.Set(repo.removalRef(pid(100+i)), removalDoc{State: string(RemovalRemoved), AuthorID: "u-gone", ExpireAt: time.Now().Add(time.Hour)})
	}
	b.Set(repo.removalRef(pid(200)), removalDoc{State: string(RemovalRemoved), AuthorID: "u-stays", ExpireAt: time.Now().Add(time.Hour)})
	if _, err := b.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	cp, done, calls := Checkpoint{}, false, 0
	ctx, c := budget.WithCounter(context.Background())
	for !done && calls < 10 {
		var err error
		if cp, done, err = repo.PurgeUser(ctx, "u-gone", cp); err != nil {
			t.Fatalf("PurgeUser: %v", err)
		}
		calls++
	}
	if !done {
		t.Fatal("purge did not finish")
	}
	if c.Deletes() != 3 {
		t.Fatalf("deletes = %d, want 3", c.Deletes())
	}
	for i := range 3 {
		if snap, _ := repo.removalRef(pid(100 + i)).Get(context.Background()); snap != nil && snap.Exists() {
			t.Fatalf("entry %d survived the purge", i)
		}
	}
	if snap, err := repo.removalRef(pid(200)).Get(context.Background()); err != nil || !snap.Exists() {
		t.Fatalf("another author's entry was touched: err=%v", err)
	}
}
