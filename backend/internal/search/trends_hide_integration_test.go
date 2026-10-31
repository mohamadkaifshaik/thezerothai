//go:build integration

package search

// W4-25 against the Firestore emulator: trends/hidden (ADR-0028 note 2026-10-31 part 1). Hide and Unhide are 1-read
// transactions with 1 write only when the list changes; Load is 2 reads; Hidden is 1; the sweep's whole-document Put and a
// delete of trends/current never touch the hide list; the cap refuses at 100 keys with 0 writes.

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestTrends_Integration_HideList(t *testing.T) {
	c := emulatorClient(t)
	bg := context.Background()
	store := NewTrendsRepo(c)
	now := time.Now().UTC().Truncate(time.Millisecond)
	op := func(name string, f func(ctx context.Context) (HideResult, error), want HideResult, b budgettest.Budget) {
		t.Helper()
		ctx, cnt := budget.WithCounter(bg)
		got, err := f(ctx)
		if err != nil || got != want {
			t.Fatalf("%s: %+v err %v, want %+v", name, got, err, want)
		}
		budgettest.Assert(t, name, cnt, b)
	}

	// The first hide creates the document; a variant of the same key is a repeat (0 writes).
	op("hide first", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "#Sl_u\u200dr") },
		HideResult{Key: "slur", Changed: true, Count: 1}, budgettest.Budget{Reads: 1, Writes: 1})
	op("hide repeat", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "SLUR") },
		HideResult{Key: "slur", Count: 1}, budgettest.Budget{Reads: 1})
	op("hide second", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "other") },
		HideResult{Key: "other", Changed: true, Count: 2}, budgettest.Budget{Reads: 1, Writes: 1})

	ctx, cnt := budget.WithCounter(bg)
	keys, err := store.Hidden(ctx)
	if err != nil || len(keys) != 2 {
		t.Fatalf("Hidden: %v %v", keys, err)
	}
	budgettest.Assert(t, "Hidden", cnt, budgettest.Budget{Reads: 1})

	// Load with no trends/current: the hide list comes back, 2 reads.
	ctx, cnt = budget.WithCounter(bg)
	doc, hidden, err := store.Load(ctx)
	if err != nil || doc != nil || len(hidden) != 2 {
		t.Fatalf("Load without a list: %v %v %v", doc, hidden, err)
	}
	budgettest.Assert(t, "Load", cnt, budgettest.Budget{Reads: 2})

	// The sweep's Put replaces trends/current as a whole and a delete of it removes it; neither touches the hide list.
	list := &TrendsDoc{ComputedAt: now, Items: []TrendItem{{Tag: "slur", Posts: 9, Authors: 5}, {Tag: "ok", Posts: 5, Authors: 4}}}
	if err := store.Put(bg, list); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Collection("trends").Doc("current").Delete(bg); err != nil {
		t.Fatal(err)
	}
	if keys, _ := store.Hidden(bg); len(keys) != 2 {
		t.Fatalf("hide list after a Put and a delete of current: %v", keys)
	}
	if err := store.Put(bg, list); err != nil {
		t.Fatal(err)
	}

	// GetTrends serves the list without the hidden key, ranks renumbered, 2 reads cold, 0 warm.
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On})
	svc := New(reg, WithTrends(store, nil))
	ctx, cnt = budget.WithCounter(bg)
	got, err := svc.Trends(ctx, "u", 0, "")
	if err != nil || len(got.Trends) != 1 || got.Trends[0].Tag != "ok" || got.Trends[0].Rank != 1 {
		t.Fatalf("GetTrends: %v %v", got, err)
	}
	budgettest.Assert(t, "GetTrends cold", cnt, budgettest.Budget{Reads: 2})
	ctx, cnt = budget.WithCounter(bg)
	if _, err := svc.Trends(ctx, "u", 0, ""); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GetTrends warm", cnt, budgettest.Budget{})

	// The sweep reads the hide list (1 read) and drops the hidden key; it never writes the list.
	reader := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(c), Cache: posts.NewCache(time.Minute, 0, 0)})
	for i, a := range []string{"a", "b", "c"} {
		seedPost(t, c, i+1, a, "POST", now.Add(-time.Duration(5-i)*time.Hour), "", "slur", "ok")
	}
	r := NewRefresher(store, reader, &trendsFakeProtected{set: map[string]bool{}}, newFakeAuthors(), reg,
		RefresherConfig{MinAuthors: 3, MaxPosts: 2000, MinInterval: 12 * time.Hour, Now: func() time.Time { return now.Add(13 * time.Hour) }})
	res, err := r.Run(bg)
	if err != nil || res.Skipped != "" || res.FsReads != 2+3+3 || res.FsWrites != 1 {
		t.Fatalf("sweep: %+v %v, want 8 reads (document, hide list, 3 posts, 3 authors) and 1 write", res, err)
	}
	if cur, _ := store.Get(bg); cur == nil || len(cur.Items) != 1 || cur.Items[0].Tag != "ok" {
		t.Fatalf("sweep list: %+v", cur)
	}

	// Unhide: 1 read, 1 write; again or an unknown key: 1 read, 0 writes.
	op("unhide", func(ctx context.Context) (HideResult, error) { return store.Unhide(ctx, "slur") },
		HideResult{Key: "slur", Changed: true, Count: 1}, budgettest.Budget{Reads: 1, Writes: 1})
	op("unhide repeat", func(ctx context.Context) (HideResult, error) { return store.Unhide(ctx, "slur") },
		HideResult{Key: "slur", Count: 1}, budgettest.Budget{Reads: 1})

	// Rejected input costs nothing.
	ctx, cnt = budget.WithCounter(bg)
	if _, err := store.Hide(ctx, "_\u200d"); !errors.Is(err, ErrEmptyTrendKey) {
		t.Fatalf("empty key: %v", err)
	}
	budgettest.Assert(t, "rejected", cnt, budgettest.Budget{})
}

// Nothing to remove is success, creates nothing and writes 0.
func TestTrends_Integration_UnhideWithoutDocument(t *testing.T) {
	c := emulatorClient(t)
	store := NewTrendsRepo(c)
	ctx, cnt := budget.WithCounter(context.Background())
	res, err := store.Unhide(ctx, "nothing")
	if err != nil || res.Changed {
		t.Fatalf("unhide: %+v %v", res, err)
	}
	budgettest.Assert(t, "unhide missing", cnt, budgettest.Budget{Reads: 1})
	if snap, err := c.Collection("trends").Doc("hidden").Get(context.Background()); err == nil && snap.Exists() {
		t.Fatal("unhide created trends/hidden")
	}
}

// The 101st key is refused with ErrHiddenFull and 0 writes; a key already on the list at the cap is a repeat.
func TestTrends_Integration_HideListCap(t *testing.T) {
	c := emulatorClient(t)
	store := NewTrendsRepo(c)
	tags := make([]string, maxHiddenTags)
	for i := range tags {
		tags[i] = fmt.Sprintf("tag%03d", i)
	}
	if _, err := c.Collection("trends").Doc("hidden").Set(context.Background(), map[string]any{"schemaVersion": 1, "tags": tags, "updatedAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	ctx, cnt := budget.WithCounter(context.Background())
	res, err := store.Hide(ctx, "onemore")
	if !errors.Is(err, ErrHiddenFull) || res.Count != maxHiddenTags {
		t.Fatalf("101st: %+v %v", res, err)
	}
	budgettest.Assert(t, "hide at the cap", cnt, budgettest.Budget{Reads: 1})
	if res, err := store.Hide(context.Background(), "tag007"); err != nil || res.Changed {
		t.Fatalf("repeat at the cap: %+v %v", res, err)
	}
}
