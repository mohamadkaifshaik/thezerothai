//go:build integration

package search

// against the Firestore emulator: trends/hidden (part 1). Hide and Unhide are transactions that write only when the
// list changes; the sweep's whole-document Put and a delete of trends/current never touch the hide list; the cap
// refuses at 100 keys without a write.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestTrends_Integration_HideList(t *testing.T) {
	c := emulatorClient(t)
	bg := context.Background()
	store := NewTrendsRepo(c)
	now := time.Now().UTC().Truncate(time.Millisecond)
	op := func(name string, f func(ctx context.Context) (HideResult, error), want HideResult) {
		t.Helper()
		got, err := f(bg)
		if err != nil || got != want {
			t.Fatalf("%s: %+v err %v, want %+v", name, got, err, want)
		}
	}

	// The first hide creates the document; a variant of the same key is a repeat (Changed false).
	op("hide first", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "#Sl_u\u200dr") },
		HideResult{Key: "slur", Changed: true, Count: 1})
	op("hide repeat", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "SLUR") },
		HideResult{Key: "slur", Count: 1})
	op("hide second", func(ctx context.Context) (HideResult, error) { return store.Hide(ctx, "other") },
		HideResult{Key: "other", Changed: true, Count: 2})

	keys, err := store.Hidden(bg)
	if err != nil || len(keys) != 2 {
		t.Fatalf("Hidden: %v %v", keys, err)
	}

	// Load with no trends/current: the hide list comes back.
	doc, hidden, err := store.Load(bg)
	if err != nil || doc != nil || len(hidden) != 2 {
		t.Fatalf("Load without a list: %v %v %v", doc, hidden, err)
	}

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

	// GetTrends serves the list without the hidden key, ranks renumbered.
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On})
	svc := New(reg, WithTrends(store, nil))
	got, err := svc.Trends(bg, "u", 0, "")
	if err != nil || len(got.Trends) != 1 || got.Trends[0].Tag != "ok" || got.Trends[0].Rank != 1 {
		t.Fatalf("GetTrends: %v %v", got, err)
	}
	if _, err := svc.Trends(bg, "u", 0, ""); err != nil {
		t.Fatal(err)
	}

	// The sweep reads the hide list and drops the hidden key; it never writes the list.
	reader := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(c), Cache: posts.NewCache(time.Minute, 0, 0)})
	for i, a := range []string{"a", "b", "c"} {
		seedPost(t, c, i+1, a, "POST", now.Add(-time.Duration(5-i)*time.Hour), "", "slur", "ok")
	}
	r := NewRefresher(store, reader, &trendsFakeProtected{set: map[string]bool{}}, newFakeAuthors(), reg,
		RefresherConfig{MinAuthors: 3, MaxPosts: 2000, MinInterval: 12 * time.Hour, Now: func() time.Time { return now.Add(13 * time.Hour) }})
	res, err := r.Run(bg)
	if err != nil || res.Skipped != "" {
		t.Fatalf("sweep: %+v %v", res, err)
	}
	if cur, _ := store.Get(bg); cur == nil || len(cur.Items) != 1 || cur.Items[0].Tag != "ok" {
		t.Fatalf("sweep list: %+v", cur)
	}
	if keys, _ := store.Hidden(bg); len(keys) != 2 {
		t.Fatalf("hide list after the sweep: %v, want it untouched", keys)
	}

	// Unhide changes the list; again or an unknown key leaves it alone.
	op("unhide", func(ctx context.Context) (HideResult, error) { return store.Unhide(ctx, "slur") },
		HideResult{Key: "slur", Changed: true, Count: 1})
	op("unhide repeat", func(ctx context.Context) (HideResult, error) { return store.Unhide(ctx, "slur") },
		HideResult{Key: "slur", Count: 1})

	// Rejected input is refused.
	if _, err := store.Hide(bg, "_\u200d"); !errors.Is(err, ErrEmptyTrendKey) {
		t.Fatalf("empty key: %v", err)
	}
}

// Nothing to remove is success and creates nothing.
func TestTrends_Integration_UnhideWithoutDocument(t *testing.T) {
	c := emulatorClient(t)
	store := NewTrendsRepo(c)
	ctx := context.Background()
	res, err := store.Unhide(ctx, "nothing")
	if err != nil || res.Changed {
		t.Fatalf("unhide: %+v %v", res, err)
	}
	if snap, err := c.Collection("trends").Doc("hidden").Get(context.Background()); err == nil && snap.Exists() {
		t.Fatal("unhide created trends/hidden")
	}
}

// The 101st key is refused with ErrHiddenFull and nothing is written; a key already on the list at the cap is a repeat.
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
	ctx := context.Background()
	res, err := store.Hide(ctx, "onemore")
	if !errors.Is(err, ErrHiddenFull) || res.Count != maxHiddenTags {
		t.Fatalf("101st: %+v %v", res, err)
	}
	if keys, err := store.Hidden(ctx); err != nil || len(keys) != maxHiddenTags || slices.Contains(keys, "onemore") {
		t.Fatalf("hide list after the refusal: %d keys, err %v, want the original %d", len(keys), err, maxHiddenTags)
	}
	if res, err := store.Hide(context.Background(), "tag007"); err != nil || res.Changed {
		t.Fatalf("repeat at the cap: %+v %v", res, err)
	}
}
