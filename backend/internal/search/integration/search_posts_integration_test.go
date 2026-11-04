//go:build integration

// Package integration runs SearchPosts against the Firestore emulator with the real graph and posts services wired as
// apiserver.Build wires them (a snapshot-based posts.Audience over the protected-set loader). It lives in its own
// directory, like the timeline integration tests, so the search package's import discipline still covers search itself.
//
// The userLikes lookup (engagement's cached read) is stood in for by countingViewer, which tallies its calls: a page with
// rows asks once, a page without rows or a rejected request never asks.
package integration

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/search"
)

var cursorKey = []byte("0123456789abcdef0123456789abcdef")

type allOn struct{}

func (allOn) Enabled(string, string) bool { return true }
func (allOn) GloballyOff(string) bool     { return false }

// countingViewer is engagement's cached userLikes read: it tallies its calls.
type countingViewer struct{ calls atomic.Int64 }

func (v *countingViewer) Viewer(context.Context, string) posts.ViewerSet {
	v.calls.Add(1)
	return posts.ViewerSet{}
}

// instance is one search service plus the tally of its userLikes lookups.
type instance struct {
	search.Service
	viewer *countingViewer
}

// viewerCalls is how many userLikes lookups the instance has made so far.
func (i *instance) viewerCalls() int64 { return i.viewer.calls.Load() }

func newClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

// newInstance is one Cloud Run instance: its own caches over the shared emulator project. A new instance is the cold case.
func newInstance(t *testing.T, client *firestore.Client) *instance {
	t.Helper()
	graphSvc := graph.New(graph.Deps{
		Repo: graph.NewFirestoreRepo(client), Cache: graph.NewCache(time.Minute), Flags: allOn{}, CursorKey: cursorKey,
	})
	postsSvc := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(client), Cache: posts.NewCache(time.Minute, 20_000, 1_000), Events: posts.NopEvents{}})
	viewer := &countingViewer{}
	return &instance{viewer: viewer, Service: search.New(allOn{}, search.WithPosts(search.PostsDeps{
		Posts: postsSvc, Graph: graphSvc, Viewer: viewer, Audience: posts.NewSnapshotAudience(nil),
		CursorKey: cursorKey, TagEntries: 100,
	}))}
}

func pid(n int) string { return fmt.Sprintf("%019d", n) }

var base = time.Now().Add(-2 * time.Hour).UTC().Truncate(time.Millisecond)

// seed writes post n of tag (createdAt rises with n) by author, with images and a like count.
func seed(t *testing.T, client *firestore.Client, n int, author, tag string, images int, likes int64) {
	t.Helper()
	media := []map[string]any{}
	for i := 0; i < images; i++ {
		media = append(media, map[string]any{"mediaId": fmt.Sprintf("m%d-%d", n, i), "url": "https://x/" + pid(n), "thumbUrl": "https://x/t" + pid(n), "width": 10, "height": 10})
	}
	doc := map[string]any{
		"authorId": author, "author": map[string]any{"userId": author, "handle": "h" + author},
		"kind": "POST", "isReply": false, "text": "post #" + tag, "conversationId": pid(n), "hashtags": []string{tag},
		"mentions": []map[string]any{}, "likeCount": likes, "repostCount": 0, "replyCount": 0, "quoteCount": 0,
		"visibility": "PUBLIC", "createdAt": base.Add(time.Duration(n) * time.Second), "hasMedia": images > 0,
	}
	if images > 0 {
		doc["media"] = media
	}
	if _, err := client.Collection("posts").Doc(pid(n)).Set(context.Background(), doc); err != nil {
		t.Fatalf("seed %d: %v", n, err)
	}
}

func seedBlocked(t *testing.T, client *firestore.Client, uid string, blocked ...string) {
	t.Helper()
	if _, err := client.Collection("graph").Doc(uid).Set(context.Background(), map[string]any{"blocked": blocked, "following": []string{}, "muted": []string{}}); err != nil {
		t.Fatal(err)
	}
}

func run(t *testing.T, svc search.Service, uid, q string, tab searchv1.SearchTab, size int32, token string) *searchv1.SearchPostsResponse {
	t.Helper()
	resp, err := svc.Posts(context.Background(), uid, q, tab, size, token)
	if err != nil {
		t.Fatalf("Posts(%v): %v", tab, err)
	}
	return resp
}

func ids(r *searchv1.SearchPostsResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// wantViewerCalls fails unless the instance has made exactly n userLikes lookups so far.
func wantViewerCalls(t *testing.T, svc *instance, name string, n int64) {
	t.Helper()
	if got := svc.viewerCalls(); got != n {
		t.Errorf("%s: %d userLikes lookups, want %d", name, got, n)
	}
}

// TestSearchPosts_Pages walks the tabs over real documents: page contents and tokens, the shared warm entry, and the
// requests that must not reach the viewer state.
func TestSearchPosts_Pages(t *testing.T) {
	client := newClient(t)
	// 45 posts tagged #go: every 5th has an image and three carry likes; one post of another tag.
	for n := 1; n <= 45; n++ {
		img, likes := 0, int64(0)
		if n%5 == 0 {
			img = 1
		}
		if n == 10 || n == 20 || n == 44 {
			likes = int64(n)
		}
		seed(t, client, n, "a", "go", img, likes)
	}
	seed(t, client, 100, "b", "rare", 0, 0)
	seedBlocked(t, client, "u", "nobody")

	t.Run("LATEST: pages of 20 + 20 + 5, cold then older", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "#Go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(p1.Posts) != 20 || p1.NextPageToken == "" || ids(p1)[0] != pid(45) {
			t.Fatalf("page 1: %d posts, token %q, first %v", len(p1.Posts), p1.NextPageToken, ids(p1)[:1])
		}

		warm := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if fmt.Sprint(ids(warm)) != fmt.Sprint(ids(p1)) {
			t.Fatalf("warm page 1 = %v, want the cold page %v", ids(warm), ids(p1))
		}

		p2 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, p1.NextPageToken)
		if len(p2.Posts) != 20 || p2.NextPageToken == "" || ids(p2)[0] != pid(25) {
			t.Fatalf("page 2: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}

		p3 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, p2.NextPageToken)
		if len(p3.Posts) != 5 || p3.NextPageToken != "" || ids(p3)[4] != pid(1) {
			t.Fatalf("page 3: %d posts, token %q", len(p3.Posts), p3.NextPageToken)
		}
		wantViewerCalls(t, svc, "four pages with rows", 4)
	})

	t.Run("LATEST: a warm instance serves page 1 from its cached entry", func(t *testing.T) {
		const tag = "cached"
		for n := 301; n <= 305; n++ {
			seed(t, client, n, "a", tag, 0, 0)
		}
		svc := newInstance(t, client)
		cold := run(t, svc, "u", tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(cold.Posts) != 5 || ids(cold)[0] != pid(305) {
			t.Fatalf("cold: %d posts, first %v", len(cold.Posts), ids(cold))
		}
		// The newest post is deleted behind the instance back: a warm call still answers from the entry it built.
		if _, err := client.Collection("posts").Doc(pid(305)).Delete(context.Background()); err != nil {
			t.Fatal(err)
		}
		warm := run(t, svc, "u", tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(warm.Posts) != 5 || ids(warm)[0] != pid(305) {
			t.Errorf("warm: %d posts, first %v; want the cached entry with %s still in it", len(warm.Posts), ids(warm), pid(305))
		}
		// A fresh instance has no entry and sees the deletion.
		fresh := run(t, newInstance(t, client), "u", tag, searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(fresh.Posts) != 4 || ids(fresh)[0] != pid(304) {
			t.Errorf("fresh instance: %d posts, first %v; want 4 starting at %s", len(fresh.Posts), ids(fresh), pid(304))
		}
	})

	t.Run("LATEST: page 1 at page_size 50 skips the entry", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 50, "")
		if len(p1.Posts) != 45 || p1.NextPageToken != "" {
			t.Fatalf("page_size 50: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
	})

	t.Run("TOP: ranked by engagement, one page, no token", func(t *testing.T) {
		svc := newInstance(t, client)
		resp := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
		if resp.NextPageToken != "" || len(resp.Posts) != 20 || fmt.Sprint(ids(resp)[:3]) != fmt.Sprint([]string{pid(44), pid(20), pid(45)}) {
			t.Fatalf("TOP: %d posts, token %q, head %v", len(resp.Posts), resp.NextPageToken, ids(resp)[:3])
		}
	})

	t.Run("MEDIA: the entry, then a scan to the end", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_MEDIA, 0, "")
		// The entry is posts 45..16: images at 45, 40, 35, 30, 25, 20.
		if len(p1.Posts) != 6 || p1.NextPageToken == "" || ids(p1)[0] != pid(45) {
			t.Fatalf("MEDIA page 1: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		p2 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_MEDIA, 0, p1.NextPageToken)
		// The scan reads posts 15..1 (15 < 30): the end. Images at 15, 10, 5.
		if len(p2.Posts) != 3 || p2.NextPageToken != "" {
			t.Fatalf("MEDIA scan: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}
	})

	t.Run("a second viewer shares the warm entry and asks for their own userLikes", func(t *testing.T) {
		svc := newInstance(t, client)
		first := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		second := run(t, svc, "other", "go", searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
		if len(first.Posts) != 20 || len(second.Posts) != 20 {
			t.Fatalf("pages of %d and %d posts, want 20 each", len(first.Posts), len(second.Posts))
		}
		wantViewerCalls(t, svc, "two viewers", 2)
	})

	t.Run("an empty tag answers an empty page without asking for userLikes", func(t *testing.T) {
		svc := newInstance(t, client)
		resp := run(t, svc, "u", "nosuchtag", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(resp.Posts) != 0 || resp.NextPageToken != "" {
			t.Fatalf("empty: %d posts token %q", len(resp.Posts), resp.NextPageToken)
		}
		wantViewerCalls(t, svc, "empty tag", 0)
	})

	t.Run("rejections never reach the viewer state", func(t *testing.T) {
		svc := newInstance(t, client)
		for _, q := range []string{"two words", "@alice", "#123"} {
			resp := run(t, svc, "u", q, searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
			if !resp.UnsupportedQuery {
				t.Errorf("%q must be unsupported", q)
			}
		}
		if _, err := svc.Posts(context.Background(), "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "garbage"); err == nil {
			t.Fatal("a garbage token must fail")
		}
		wantViewerCalls(t, svc, "rejections", 0)
	})
}

// A blocked author's rows are dropped against the real graph. Page 1 filters the whole 25-row entry first, so the 5
// visible rows come back and, the entry not being full, no token follows (the old cut returned an empty page and a token).
func TestSearchPosts_BlockedAuthorAgainstTheRealGraph(t *testing.T) {
	client := newClient(t)
	for n := 1; n <= 25; n++ {
		author := "a"
		if n > 5 { // the newest 20 are by "bad"
			author = "bad"
		}
		seed(t, client, n, author, "blk", 0, 0)
	}
	seedBlocked(t, client, "u", "bad")
	svc := newInstance(t, client)
	p1 := run(t, svc, "u", "blk", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
	if len(p1.Posts) != 5 || p1.NextPageToken != "" || ids(p1)[0] != pid(5) {
		t.Fatalf("page 1: %d posts, token %q; want the 5 visible rows and no token", len(p1.Posts), p1.NextPageToken)
	}
}

// LATEST windows are fixed tiers (part 3): page 1 at k <= 30 comes from a 30-row entry, at k 31..50 from a 50-row query;
// an older page at k <= 20 is a 20-row window and at k 21..50 a 50-row one; a tail page is whatever rows are left. The
// query sizes themselves are checked in service_posts_latest_test.go against the fake reader.
func TestSearchPosts_LatestWindows(t *testing.T) {
	client := newClient(t)
	for n := 1; n <= 130; n++ {
		seed(t, client, n, "a", "win", 0, 0)
	}
	for n := 201; n <= 225; n++ { // a small tag of 25 posts: its end is reached on page 1
		seed(t, client, n, "a", "small", 0, 0)
	}
	seedBlocked(t, client, "u", "nobody")
	latest := searchv1.SearchTab_SEARCH_TAB_LATEST

	t.Run("page 1 at 20 then older pages at 1 and 21", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "win", latest, 20, "")
		o1 := run(t, svc, "u", "win", latest, 1, p1.NextPageToken) // k picks the tier, not the query size: 20 rows
		if len(o1.Posts) != 1 || o1.NextPageToken == "" {
			t.Fatalf("older page at k=1: %d posts, token %q", len(o1.Posts), o1.NextPageToken)
		}
		o21 := run(t, svc, "u", "win", latest, 21, p1.NextPageToken)
		if len(o21.Posts) != 21 || o21.NextPageToken == "" {
			t.Fatalf("older page at k=21: %d posts, token %q", len(o21.Posts), o21.NextPageToken)
		}
	})

	t.Run("page 1 at 31 is one 50-row query", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "win", latest, 31, "")
		if len(p1.Posts) != 31 || p1.NextPageToken == "" {
			t.Fatalf("page 1 at k=31: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
	})

	t.Run("a tail page reads the rows left", func(t *testing.T) {
		svc := newInstance(t, client)
		p1 := run(t, svc, "u", "small", latest, 1, "")
		if len(p1.Posts) != 1 || p1.NextPageToken == "" {
			t.Fatalf("page 1 at k=1: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		p2 := run(t, svc, "u", "small", latest, 20, p1.NextPageToken)
		if len(p2.Posts) != 20 || p2.NextPageToken == "" || ids(p2)[0] != pid(224) {
			t.Fatalf("tail page: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}
		p3 := run(t, svc, "u", "small", latest, 20, p2.NextPageToken)
		if len(p3.Posts) != 4 || p3.NextPageToken != "" {
			t.Fatalf("last tail page: %d posts, token %q", len(p3.Posts), p3.NextPageToken)
		}
	})
}
