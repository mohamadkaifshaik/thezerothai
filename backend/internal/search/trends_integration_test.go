//go:build integration

package search

// against the Firestore emulator: the real trends/current repo, the real posts.Reader.CreatedAfter, the
// refresher end to end, and GetTrends through the instance copy.

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func emulatorClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	c, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func seedPost(t *testing.T, c *firestore.Client, n int, author, kind string, at time.Time, moderation string, tags ...string) {
	t.Helper()
	doc := map[string]any{"authorId": author, "kind": kind, "hashtags": tags, "createdAt": at, "text": "t", "visibility": "PUBLIC"}
	if moderation != "" {
		doc["moderation"] = moderation
	}
	if _, err := c.Collection("posts").Doc(fmt.Sprintf("%020d", n)).Set(context.Background(), doc); err != nil {
		t.Fatal(err)
	}
}

func TestTrends_Integration_RefreshAndGetTrends(t *testing.T) {
	c := emulatorClient(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	store := NewTrendsRepo(c)
	reader := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(c), Cache: posts.NewCache(time.Minute, 0, 0)})
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On})
	prot := &trendsFakeProtected{set: map[string]bool{"p": true}}
	r := NewRefresher(store, reader, prot, newFakeAuthors(), reg, RefresherConfig{MinAuthors: 3, MaxPosts: 2000, MinInterval: 12 * time.Hour, Denylist: []string{"banned"},
		Now: func() time.Time { return now }})

	// 3 authors on #launch (+ a taken-down, a REPOST and a protected author's post that must not count), 1 author on #spam x5,
	// #banned x3 authors, a post older than 24 h (outside the first window).
	at := func(h int) time.Time { return now.Add(-time.Duration(h) * time.Hour) }
	seedPost(t, c, 1, "a", "POST", at(10), "", "launch", "banned")
	seedPost(t, c, 2, "b", "POST", at(9), "", "launch", "banned")
	seedPost(t, c, 3, "c", "POST", at(8), "", "launch", "banned")
	seedPost(t, c, 4, "d", "POST", at(7), "TAKEN_DOWN", "launch")
	seedPost(t, c, 5, "e", "REPOST", at(6), "")
	seedPost(t, c, 6, "p", "POST", at(5), "", "launch")
	for i := 0; i < 5; i++ {
		seedPost(t, c, 10+i, "s", "POST", at(4), "", "spam")
	}
	seedPost(t, c, 30, "a", "POST", at(30), "", "ancient")
	const newPosts = 12 // 1,2,3,4,5,6 and 10..14 inside the window; the ancient one is outside

	// GetTrends before any run: no document, an empty list.
	svc := New(reg, WithTrends(store, nil))
	ctx := context.Background()
	got, err := svc.Trends(ctx, "u", 0, "")
	if err != nil || len(got.Trends) != 0 || got.ComputedAt != nil {
		t.Fatalf("before the first run: %v %v", got, err)
	}

	// The run scans the 11 new posts and writes the document.
	res, err := r.Run(context.Background())
	if err != nil || res.Skipped != "" || res.PostsScanned != newPosts-1 {
		t.Fatalf("res %+v err %v", res, err)
	}
	doc, err := store.Get(context.Background())
	if err != nil || doc == nil {
		t.Fatalf("doc %v err %v", doc, err)
	}
	if len(doc.Items) != 1 || doc.Items[0] != (TrendItem{Tag: "launch", Posts: 3, Authors: 3}) {
		t.Fatalf("items = %+v, want only #launch with 3 authors (banned, spam, protected, hidden and REPOST excluded)", doc.Items)
	}
	if doc.Backlog || doc.PostsScanned != newPosts-1 || doc.ComputedAt.IsZero() || doc.Watermark.ID != fmt.Sprintf("%020d", 14) {
		t.Fatalf("doc %+v", doc)
	}

	// A second run inside the interval is skipped as fresh and leaves the document as it was.
	if res, err := r.Run(context.Background()); err != nil || res.Skipped != SkipFresh {
		t.Fatalf("second run: %+v %v, want skipped fresh", res, err)
	}
	// The kill switch skips the run before any work against the real store.
	off := NewRefresher(store, reader, prot, nil, flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.Off}), RefresherConfig{})
	if res, err := off.Run(context.Background()); err != nil || res.Skipped != SkipFlagOff {
		t.Fatalf("flag off: %+v %v", res, err)
	}
	if after, err := store.Get(context.Background()); err != nil || after == nil || !after.ComputedAt.Equal(doc.ComputedAt) || after.Watermark != doc.Watermark {
		t.Fatalf("the skipped runs changed the document: %+v -> %+v (%v)", doc, after, err)
	}

	// GetTrends cold: the instance of this service never loaded the document after the run (it cached "no list" 10 min).
	fresh := New(reg, WithTrends(store, nil))
	got, err = fresh.Trends(context.Background(), "u", 0, "la")
	if err != nil || len(got.Trends) != 1 || got.Trends[0].Tag != "launch" || got.Trends[0].PostCount != 3 || got.ComputedAt == nil {
		t.Fatalf("GetTrends: %v %v", got, err)
	}
	if _, err := fresh.Trends(context.Background(), "u", 0, ""); err != nil {
		t.Fatal(err)
	}
}

// TestTrends_Integration_ProjectedPostsSkipCache: the reader returns every projected post in the window and keeps
// them out of the posts cache.
func TestTrends_Integration_ProjectedPostsSkipCache(t *testing.T) {
	c := emulatorClient(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	pc := posts.NewCache(time.Minute, 0, 0)
	reader := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(c), Cache: pc})
	for i := 1; i <= 40; i++ {
		seedPost(t, c, i, fmt.Sprintf("u%d", i%4), "POST", now.Add(-time.Duration(41-i)*time.Minute), "", "x")
	}
	page, err := reader.CreatedAfter(context.Background(), posts.Position{CreatedAt: now.Add(-24 * time.Hour)}, 500)
	if err != nil || len(page) != 40 {
		t.Fatalf("page %d err %v", len(page), err)
	}
	// A projected post never reaches the posts cache.
	for _, p := range page {
		if _, ok := pc.GetPost(p.ID); ok {
			t.Fatalf("projected post %s was stored in the posts cache", p.ID)
		}
	}
}
