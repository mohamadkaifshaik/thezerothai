//go:build integration

package posts

import (
	"context"
	"slices"
	"testing"
	"time"
)

// queryRecorder wraps a RemovalSource and records which query each call ran.
type queryRecorder struct {
	RemovalSource
	names []string
}

func (q *queryRecorder) Newest(ctx context.Context, floor time.Time, limit int) ([]RemovalEntry, error) {
	q.names = append(q.names, "newest")
	return q.RemovalSource.Newest(ctx, floor, limit)
}

func (q *queryRecorder) After(ctx context.Context, afterAt time.Time, afterID string, limit int) ([]RemovalEntry, error) {
	q.names = append(q.names, "after")
	return q.RemovalSource.After(ctx, afterAt, afterID, limit)
}

func (q *queryRecorder) Window(ctx context.Context, authors []string, after, upTo time.Time, limit int) ([]RemovalEntry, error) {
	q.names = append(q.names, "window")
	return q.RemovalSource.Window(ctx, authors, after, upTo, limit)
}

// TestRemovalLog_SharedInstantBurst is the B1 regression on the real repo, per feed (amendment 2026-10-18 (b)):
// a 120-entry single-timestamp burst by "spammer" loads the cache once and every TTL after it is only an incremental
// query; a viewer who does not show the spammer is never reset; the spammer's own feed resets.
func TestRemovalLog_SharedInstantBurst(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedSharedInstantRemovals(t, repo, 120)

	now := time.Now()
	// The real clock may sit before defaultRemovalAuthorScopedFrom; move the cutover before the window.
	rec := &queryRecorder{RemovalSource: repo}
	log := NewRemovalLog(rec, time.Minute, func() time.Time { return now }, WithAuthorScopedFromForTest(now.Add(-24*time.Hour)))
	cutoff := now.Add(-time.Hour)
	call := func(authors ...string) (ids []string, trunc bool, queries []string) {
		before := len(rec.names)
		ids, trunc, err := log.RemovedSince(context.Background(), cutoff, RemovalScope{Authors: authors})
		if err != nil {
			t.Fatal(err)
		}
		return ids, trunc, append([]string(nil), rec.names[before:]...)
	}

	ids, trunc, queries := call("viewer")
	if trunc || len(ids) != 0 {
		t.Fatalf("viewer that does not show the spammer: ids=%d trunc=%v, want none/false", len(ids), trunc)
	}
	if len(queries) == 0 || queries[0] != "newest" {
		t.Fatalf("cold: queries = %v, want the cache loaded by a newest query first", queries)
	}
	if _, trunc, _ = call("spammer"); !trunc {
		t.Fatal("the spammer's own feed must be reset (120 ids cannot be listed)")
	}
	for step := 1; step <= 5; step++ {
		now = now.Add(time.Minute)
		if _, trunc, queries = call("viewer"); trunc || len(queries) == 0 || queries[0] != "after" || slices.Contains(queries, "newest") {
			t.Fatalf("TTL step %d: trunc=%v queries=%v, want false and an incremental after query without a reload", step, trunc, queries)
		}
	}
}

// TestRemovalSource_WindowScopesByAuthor runs the per-feed window query on the emulator: author filter (== for one
// author, in for several), the (after, upTo] bounds, newest first, and the Limit.
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

	got, err := repo.Window(ctx, []string{"bob"}, after, upTo, 10)
	if err != nil || len(got) != 2 || got[0].AuthorID != "bob" {
		t.Fatalf("one author: %+v err=%v", got, err)
	}

	if got, err = repo.Window(ctx, []string{"alice", "bob", "nobody"}, after, upTo, 10); err != nil || len(got) != 3 {
		t.Fatalf("in: %+v err=%v", got, err)
	}

	if got, err = repo.Window(ctx, []string{"alice", "bob"}, after, upTo, 2); err != nil || len(got) != 2 {
		t.Fatalf("limit: %+v err=%v", got, err)
	}

	// Bounds: strictly after, and up to and including upTo.
	at := all[0].At
	if got, err = repo.Window(ctx, []string{"alice", "bob"}, at, upTo, 10); err != nil || len(got) != 0 {
		t.Fatalf("after == createdAt must exclude: %+v err=%v", got, err)
	}
	if got, err = repo.Window(ctx, []string{"alice", "bob"}, after, at, 10); err != nil || len(got) == 0 {
		t.Fatalf("upTo == createdAt must include: %+v err=%v", got, err)
	}
	if got, err = repo.Window(ctx, []string{"nobody"}, after, upTo, 10); err != nil || len(got) != 0 {
		t.Fatalf("empty: %+v err=%v", got, err)
	}
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

// TestPurgeUser_DeletesTheUsersRemovalEntries (right to delete): phase 2 removes exactly the entries
// whose authorId is the user, after the copies phase; other authors' entries stay.
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
	ctx := context.Background()
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
	for i := range 3 {
		if snap, _ := repo.removalRef(pid(100 + i)).Get(context.Background()); snap != nil && snap.Exists() {
			t.Fatalf("entry %d survived the purge", i)
		}
	}
	if snap, err := repo.removalRef(pid(200)).Get(context.Background()); err != nil || !snap.Exists() {
		t.Fatalf("another author's entry was touched: err=%v", err)
	}
}
