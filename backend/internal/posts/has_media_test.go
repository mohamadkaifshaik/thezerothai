package posts

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

// TestHasMediaFor pins the one definition of posts.hasMedia (ADR-0024 D4): the post's own stored images, never for a
// REPOST. The W3-8 backfill calls the same function.
func TestHasMediaFor(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		kind  Kind
		media int
		want  bool
	}{
		{"root with one image", KindPost, 1, true},
		{"root with four images", KindPost, 4, true},
		{"root text only", KindPost, 0, false},
		{"reply with an image", KindReply, 1, true},
		{"reply text only", KindReply, 0, false},
		{"quote with its own image", KindQuote, 2, true},
		{"quote text only", KindQuote, 0, false},
		{"repost is always false", KindRepost, 0, false},
		{"repost never counts even a stray ref", KindRepost, 1, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := HasMediaFor(tt.kind, tt.media); got != tt.want {
				t.Fatalf("HasMediaFor(%s, %d) = %v, want %v", tt.kind, tt.media, got, tt.want)
			}
		})
	}
}

// TestToDoc_HasMedia: every create path funnels a Post through toDoc (CreatePost root, reply and quote, the scheduled
// publish sweep and the REPOST doc), so the stored value is derived from the post's own Media there and never from a
// field a caller set. A text-only post and a REPOST store an explicit false (no omitempty), and the original's images
// inside a REPOST's embed do not count.
func TestToDoc_HasMedia(t *testing.T) {
	t.Parallel()
	img := []MediaRef{{ID: "1", URL: "https://x/1", ThumbURL: "https://x/t1"}}
	original := &Post{ID: "0000000000000000001", AuthorID: "a", Author: AuthorSnapshot{UserID: "a"}, Kind: KindPost, Media: img}
	repost := NewRepostPost("0000000000000000009", time.UnixMilli(9000).UTC(), AuthorSnapshot{UserID: "b"}, 1, original)

	tests := []struct {
		name string
		p    *Post
		want bool
	}{
		{"CreatePost root with images", &Post{Kind: KindPost, Media: img}, true},
		{"CreatePost root text only", &Post{Kind: KindPost}, false},
		{"CreatePost reply with its own image", &Post{Kind: KindReply, IsReply: true, Media: img}, true},
		{"CreatePost reply text only", &Post{Kind: KindReply, IsReply: true}, false},
		{"CreatePost quote with its own image", &Post{Kind: KindQuote, Media: img, Embedded: snapshotOf(original)}, true},
		{"CreatePost quote of an image post, no image of its own", &Post{Kind: KindQuote, Embedded: snapshotOf(original)}, false},
		{"publish sweep with images", &Post{Kind: KindPost, Media: img, ConversationID: "x"}, true},
		{"publish sweep text only", &Post{Kind: KindPost, ConversationID: "x"}, false},
		{"REPOST of an image post", repost, false},
		{"a caller-set field does not decide it", &Post{Kind: KindPost, HasMedia: true}, false},
		{"a caller-set false does not decide it", &Post{Kind: KindPost, Media: img, HasMedia: false}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			d := toDoc(tt.p)
			if d.HasMedia != tt.want {
				t.Fatalf("toDoc(...).HasMedia = %v, want %v", d.HasMedia, tt.want)
			}
			if got := d.toPost("1"); got.HasMedia != tt.want {
				t.Fatalf("toPost HasMedia = %v, want %v", got.HasMedia, tt.want)
			}
		})
	}
	if repost.Embedded == nil || len(repost.Embedded.Media) != 1 || len(repost.Media) != 0 {
		t.Fatalf("test setup: the REPOST should carry the original's images only in its embed, got %+v", repost)
	}
}

// TestPostDoc_HasMediaTag: the stored field is `hasMedia` (the name the W3-2 composite index and the backfill use) and
// has no omitempty, so false is written explicitly (a text-only post and a REPOST are "false", a legacy doc is
// "missing": the only difference the backfill's "where missing" and "rerun writes 0" rely on).
func TestPostDoc_HasMediaTag(t *testing.T) {
	t.Parallel()
	f, ok := reflect.TypeOf(postDoc{}).FieldByName("HasMedia")
	if !ok {
		t.Fatal("postDoc has no HasMedia field")
	}
	if tag := f.Tag.Get("firestore"); tag != "hasMedia" || strings.Contains(tag, "omitempty") {
		t.Fatalf("firestore tag = %q, want exactly %q", tag, "hasMedia")
	}
}

// TestPostDoc_LegacyDecodesFalse: a doc written before W3 has no hasMedia and reads false, even when it has images
// (nothing but the tab index reads the stored field until the backfill ran).
func TestPostDoc_LegacyDecodesFalse(t *testing.T) {
	t.Parallel()
	legacy := postDoc{AuthorID: "a", Kind: "POST", Media: []mediaDoc{{MediaID: "1", URL: "u", ThumbURL: "t"}}}.toPost("7")
	if legacy.HasMedia {
		t.Fatal("a pre-W3 doc must decode HasMedia=false")
	}
	if len(legacy.Media) != 1 {
		t.Fatalf("legacy media lost: %+v", legacy.Media)
	}
}

func TestByAuthorMediaAndKind(t *testing.T) {
	t.Parallel()
	p1, p2 := post("0000000000000000001", "a"), post("0000000000000000002", "a")
	before := &Position{CreatedAt: time.UnixMilli(5000).UTC(), ID: "0000000000000000005"}
	after := &Position{CreatedAt: time.UnixMilli(1000).UTC(), ID: "0000000000000000001"}

	t.Run("media passes the author, window and a clamped limit, charges query reads and fills the cache", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.queryResult = []*Post{p2, p1}
		svc, cache := newSvc(repo)
		w := Window{Before: before, After: after}
		var got []*Post
		var err error
		if r := reads(t, func(ctx context.Context) { got, err = svc.ByAuthorMedia(ctx, "a", w, 500) }); err != nil || len(got) != 2 || r != 2 {
			t.Fatalf("got=%d err=%v reads=%d, want 2, nil, 2", len(got), err, r)
		}
		if !repo.lastMedia || repo.lastAuthor != "a" || repo.lastLimit != MaxLimit || repo.lastWindow != w {
			t.Fatalf("repo saw media=%v author=%q limit=%d window=%+v", repo.lastMedia, repo.lastAuthor, repo.lastLimit, repo.lastWindow)
		}
		if _, ok := cache.GetPost(p1.ID); !ok {
			t.Fatal("query results must fill the posts cache like ByAuthor")
		}
	})

	t.Run("reposts query the REPOST kind with the default page size for limit 0", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		svc, _ := newSvc(repo)
		var got []*Post
		var err error
		if r := reads(t, func(ctx context.Context) { got, err = svc.ByAuthorKind(ctx, "a", KindRepost, Window{}, 0) }); err != nil || len(got) != 0 || r != 1 {
			t.Fatalf("got=%d err=%v reads=%d, want 0, nil, 1 (an empty query bills 1)", len(got), err, r)
		}
		if repo.lastKind != KindRepost || repo.lastMedia || repo.lastAuthor != "a" || repo.lastLimit != 20 {
			t.Fatalf("repo saw kind=%q media=%v author=%q limit=%d", repo.lastKind, repo.lastMedia, repo.lastAuthor, repo.lastLimit)
		}
	})

	t.Run("bad input is refused before any read", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		svc, _ := newSvc(repo)
		calls := map[string]func(context.Context) error{
			"media no author":   func(ctx context.Context) error { _, e := svc.ByAuthorMedia(ctx, "", Window{}, 5); return e },
			"reposts no author": func(ctx context.Context) error { _, e := svc.ByAuthorKind(ctx, "", KindRepost, Window{}, 5); return e },
			"media bad window": func(ctx context.Context) error {
				_, e := svc.ByAuthorMedia(ctx, "a", Window{Before: &Position{}}, 5)
				return e
			},
			"reposts bad window": func(ctx context.Context) error {
				_, e := svc.ByAuthorKind(ctx, "a", KindRepost, Window{After: &Position{}}, 5)
				return e
			},
			"empty kind": func(ctx context.Context) error { _, e := svc.ByAuthorKind(ctx, "a", "", Window{}, 5); return e },
			"unknown kind": func(ctx context.Context) error {
				_, e := svc.ByAuthorKind(ctx, "a", Kind("POLL"), Window{}, 5)
				return e
			},
		}
		for name, call := range calls {
			var err error
			if r := reads(t, func(ctx context.Context) { err = call(ctx) }); err == nil || r != 0 {
				t.Errorf("%s: err=%v reads=%d, want an error and 0 reads", name, err, r)
			}
		}
		if repo.queryCalls != 0 {
			t.Fatalf("the repo was queried %d times", repo.queryCalls)
		}
	})

	t.Run("a repo error is returned", func(t *testing.T) {
		t.Parallel()
		repo := newFakeRepo()
		repo.queryErr = errBoom
		svc, _ := newSvc(repo)
		if _, err := svc.ByAuthorMedia(context.Background(), "a", Window{}, 5); !errors.Is(err, errBoom) {
			t.Fatalf("err = %v, want the repo error", err)
		}
	})
}
