package posts

import (
	"context"
	"testing"
	"time"
)

// Unit tests for Reader.ByHashtag and Reader.CreatedAfter against the fake repo.

func TestByHashtag(t *testing.T) {
	t.Parallel()
	p1, p2 := post("0000000000000000001", "a"), post("0000000000000000002", "b")
	before := &Position{CreatedAt: time.UnixMilli(5000).UTC(), ID: "0000000000000000005"}

	t.Run("passes tag, window and clamped limit, fills the posts cache", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.queryResult = []*Post{p2, p1}
		svc, cache := newSvc(repo)
		got, err := svc.ByHashtag(context.Background(), "go", Window{Before: before}, 500)
		if err != nil || len(got) != 2 {
			t.Fatalf("got=%d err=%v, want 2, nil", len(got), err)
		}
		if repo.lastTag != "go" || repo.lastLimit != MaxLimit || repo.lastWindow.Before != before {
			t.Fatalf("repo saw tag=%q limit=%d window=%+v", repo.lastTag, repo.lastLimit, repo.lastWindow)
		}
		if _, ok := cache.GetPost(p1.ID); !ok {
			t.Fatal("ByHashtag results are full posts and must fill the posts cache")
		}
	})

	t.Run("an empty result is fine and limit 0 is the default page", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		svc, _ := newSvc(repo)
		got, err := svc.ByHashtag(context.Background(), "go", Window{}, 0)
		if err != nil || len(got) != 0 {
			t.Fatalf("got=%d err=%v, want 0, nil", len(got), err)
		}
		if repo.lastLimit != 20 {
			t.Fatalf("limit = %d, want 20", repo.lastLimit)
		}
	})

	t.Run("bad input is refused before any query", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		svc, _ := newSvc(repo)
		for name, call := range map[string]func(context.Context) error{
			"empty tag": func(ctx context.Context) error { _, e := svc.ByHashtag(ctx, "", Window{}, 5); return e },
			"hash tag":  func(ctx context.Context) error { _, e := svc.ByHashtag(ctx, "#go", Window{}, 5); return e },
			"space tag": func(ctx context.Context) error { _, e := svc.ByHashtag(ctx, "g o", Window{}, 5); return e },
			"bad window": func(ctx context.Context) error {
				_, e := svc.ByHashtag(ctx, "go", Window{Before: &Position{}}, 5)
				return e
			},
		} {
			if err := call(context.Background()); err == nil {
				t.Errorf("%s: want an error", name)
			}
		}
		if repo.queryCalls != 0 {
			t.Fatalf("repo queried %d times", repo.queryCalls)
		}
	})
}

func TestCreatedAfter(t *testing.T) {
	t.Parallel()
	wm := Position{CreatedAt: time.UnixMilli(5000).UTC(), ID: "0000000000000000005"}

	t.Run("limit clamps to 500, default 20, and projected posts are never cached", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.queryResult = []*Post{{ID: "0000000000000000006", AuthorID: "a", Hashtags: []string{"go"}, CreatedAt: wm.CreatedAt.Add(time.Second)}}
		svc, cache := newSvc(repo)
		for limit, want := range map[int]int{0: 20, -3: 20, 7: 7, 500: 500, 9999: MaxCreatedAfterLimit} {
			got, err := svc.CreatedAfter(context.Background(), wm, limit)
			if err != nil || len(got) != 1 {
				t.Fatalf("limit %d: got=%d err=%v", limit, len(got), err)
			}
			if repo.lastLimit != want || repo.lastCAfter != wm {
				t.Fatalf("limit %d: repo saw limit=%d after=%+v, want %d and the watermark", limit, repo.lastLimit, repo.lastCAfter, want)
			}
		}
		if _, ok := cache.GetPost("0000000000000000006"); ok {
			t.Fatal("a projected post must never be stored in the posts cache")
		}
		if _, ok := cache.AuthorRecent("a"); ok {
			t.Fatal("a projected post must never reach the author-recent cache")
		}
	})

	t.Run("a zero watermark time is refused before any query", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		svc, _ := newSvc(repo)
		if _, err := svc.CreatedAfter(context.Background(), Position{}, 10); err == nil || repo.queryCalls != 0 {
			t.Fatalf("err=%v queries=%d, want an error and no query", err, repo.queryCalls)
		}
	})
}
