//go:build integration

// Package integration runs SearchPosts against the Firestore emulator with the real graph and posts services wired as
// apiserver.Build wires them (a snapshot-based posts.Audience over the protected-set loader). It lives in its own
// directory, like the timeline integration tests, so the search package's import discipline still covers search itself.
//
// Budgets: every figure asserted here is the documented ceiling MINUS the account-status interceptor read, because these
// tests call the service below the interceptors. The userLikes read (1 with engagement or bookmarks on) is stood in for by
// chargingViewer, which bills one read exactly as engagement's cold read would.
package integration

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

var cursorKey = []byte("0123456789abcdef0123456789abcdef")

type allOn struct{}

func (allOn) Enabled(string, string) bool { return true }
func (allOn) GloballyOff(string) bool     { return false }

// chargingViewer is engagement's cached userLikes read as the budget sees it: 1 read per call.
type chargingViewer struct{}

func (chargingViewer) Viewer(ctx context.Context, _ string) posts.ViewerSet {
	if c := budget.FromContext(ctx); c != nil {
		c.AddReads(1)
	}
	return posts.ViewerSet{}
}

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
func newInstance(t *testing.T, client *firestore.Client) search.Service {
	t.Helper()
	graphSvc := graph.New(graph.Deps{
		Repo: graph.NewFirestoreRepo(client), Cache: graph.NewCache(time.Minute), Flags: allOn{}, CursorKey: cursorKey,
		FollowsPerDay: 500, NewAccountFollowsPerDay: 500, BlocksPerDay: 500, NewAccountBlocksPerDay: 500, NewAccountWindow: time.Nanosecond,
	})
	postsSvc := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(client), Cache: posts.NewCache(time.Minute, 20_000, 1_000), Events: posts.NopEvents{}})
	return search.New(allOn{}, search.WithPosts(search.PostsDeps{
		Posts: postsSvc, Graph: graphSvc, Viewer: chargingViewer{}, Audience: posts.NewSnapshotAudience(nil),
		CursorKey: cursorKey, TagEntries: 100,
	}))
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

func run(t *testing.T, svc search.Service, uid, q string, tab searchv1.SearchTab, size int32, token string) (*searchv1.SearchPostsResponse, *budget.Counter) {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	resp, err := svc.Posts(ctx, uid, q, tab, size, token)
	if err != nil {
		t.Fatalf("Posts(%v): %v", tab, err)
	}
	return resp, c
}

func ids(r *searchv1.SearchPostsResponse) []string {
	var out []string
	for _, v := range r.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

// exact asserts the read count is the documented figure, not only under it: a regression to FEWER reads would mean a
// skipped filter or cache. Writes and deletes must be 0 (the Budget zero value).
func exact(t *testing.T, name string, c *budget.Counter, reads int64) {
	t.Helper()
	budgettest.Assert(t, name, c, budgettest.Budget{Reads: reads})
	if c.Reads() != reads {
		t.Errorf("%s: Reads() = %d, want exactly %d", name, c.Reads(), reads)
	}
}

// Budgets (documented figure minus the interceptor read): page 1, TOP and MEDIA page 1 33 -> 32; page 1 at page_size 50
// 53 -> 52; older pages 23 / 53 -> 22 / 52; MEDIA scan 33 -> 32; warm 0 to 3 -> 0 to 2. The tag below has fewer rows than
// the worst case, so the figures asserted are the exact counts for these rows.
func TestSearchPosts_Budgets(t *testing.T) {
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
		p1, c1 := run(t, svc, "u", "#Go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(p1.Posts) != 20 || p1.NextPageToken == "" || ids(p1)[0] != pid(45) {
			t.Fatalf("page 1: %d posts, token %q, first %v", len(p1.Posts), p1.NextPageToken, ids(p1)[:1])
		}
		exact(t, "LATEST page 1 cold", c1, 1+30+1) // graph + entry 30 + userLikes

		_, c1w := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		exact(t, "LATEST page 1 warm", c1w, 1) // userLikes only: the graph and the entry are cached

		p2, c2 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, p1.NextPageToken)
		if len(p2.Posts) != 20 || p2.NextPageToken == "" || ids(p2)[0] != pid(25) {
			t.Fatalf("page 2: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}
		exact(t, "LATEST older 20", c2, 20+1) // query 20 + userLikes; the graph is cached

		p3, c3 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, p2.NextPageToken)
		if len(p3.Posts) != 5 || p3.NextPageToken != "" || ids(p3)[4] != pid(1) {
			t.Fatalf("page 3: %d posts, token %q", len(p3.Posts), p3.NextPageToken)
		}
		exact(t, "LATEST last page", c3, 5+1) // the 5 documents the query returned + userLikes
	})

	t.Run("LATEST: page 1 at page_size 50 skips the entry", func(t *testing.T) {
		svc := newInstance(t, client)
		p1, c1 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 50, "")
		if len(p1.Posts) != 45 || p1.NextPageToken != "" {
			t.Fatalf("page_size 50: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		exact(t, "LATEST page 1 at 50", c1, 1+45+1)
	})

	t.Run("TOP: ranked by engagement, one page, no token", func(t *testing.T) {
		svc := newInstance(t, client)
		resp, c := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
		if resp.NextPageToken != "" || len(resp.Posts) != 20 || fmt.Sprint(ids(resp)[:3]) != fmt.Sprint([]string{pid(44), pid(20), pid(45)}) {
			t.Fatalf("TOP: %d posts, token %q, head %v", len(resp.Posts), resp.NextPageToken, ids(resp)[:3])
		}
		exact(t, "TOP cold", c, 1+30+1)
	})

	t.Run("MEDIA: the entry, then a scan to the end", func(t *testing.T) {
		svc := newInstance(t, client)
		p1, c1 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_MEDIA, 0, "")
		// The entry is posts 45..16: images at 45, 40, 35, 30, 25, 20.
		if len(p1.Posts) != 6 || p1.NextPageToken == "" || ids(p1)[0] != pid(45) {
			t.Fatalf("MEDIA page 1: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		exact(t, "MEDIA page 1 cold", c1, 1+30+1)
		p2, c2 := run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_MEDIA, 0, p1.NextPageToken)
		// The scan reads posts 15..1 (15 < 30): the end. Images at 15, 10, 5.
		if len(p2.Posts) != 3 || p2.NextPageToken != "" {
			t.Fatalf("MEDIA scan: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}
		exact(t, "MEDIA scan", c2, 15+1)
	})

	t.Run("a second viewer shares the warm entry and pays only their own graph and userLikes", func(t *testing.T) {
		svc := newInstance(t, client)
		run(t, svc, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		_, c := run(t, svc, "other", "go", searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
		exact(t, "second viewer, warm entry", c, 1+1)
	})

	t.Run("an empty tag bills the minimum 1 for the entry", func(t *testing.T) {
		svc := newInstance(t, client)
		resp, c := run(t, svc, "u", "nosuchtag", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
		if len(resp.Posts) != 0 || resp.NextPageToken != "" {
			t.Fatalf("empty: %d posts token %q", len(resp.Posts), resp.NextPageToken)
		}
		exact(t, "empty tag", c, 1) // the empty query; no rows, so no graph and no userLikes read
	})

	t.Run("rejections read nothing", func(t *testing.T) {
		svc := newInstance(t, client)
		for _, q := range []string{"two words", "@alice", "#123"} {
			resp, c := run(t, svc, "u", q, searchv1.SearchTab_SEARCH_TAB_TOP, 0, "")
			if !resp.UnsupportedQuery {
				t.Errorf("%q must be unsupported", q)
			}
			exact(t, "unsupported "+q, c, 0)
		}
		ctx, c := budget.WithCounter(context.Background())
		if _, err := svc.Posts(ctx, "u", "go", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "garbage"); err == nil {
			t.Fatal("a garbage token must fail")
		}
		exact(t, "bad token", c, 0)
	})
}

// A blocked author's rows are dropped against the real graph. Page 1 filters the whole 25-row entry first (W4-27), so the 5
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
	p1, c := run(t, svc, "u", "blk", searchv1.SearchTab_SEARCH_TAB_LATEST, 0, "")
	if len(p1.Posts) != 5 || p1.NextPageToken != "" || ids(p1)[0] != pid(5) {
		t.Fatalf("page 1: %d posts, token %q; want the 5 visible rows and no token", len(p1.Posts), p1.NextPageToken)
	}
	exact(t, "20 of 25 rows dropped", c, 1+25+1) // graph + the 25-post entry + userLikes (5 rows returned)
}

// LATEST windows are fixed tiers (W4-27, ADR-0028 note 2026-10-31 part 3). Reads here are the document figures minus the
// interceptor's read: page 1 at k <= 30 cold 32 (graph 1 + entry 30 + userLikes 1), at k 31..50 52; an older page 22 at
// k <= 20 (the graph is cached on the instance) and 52 at k 21..50; a tail page 1 + the rows left + userLikes.
func TestSearchPosts_LatestWindowBudgets(t *testing.T) {
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
		p1, c1 := run(t, svc, "u", "win", latest, 20, "")
		exact(t, "page 1 at k=20 cold", c1, 1+30+1)
		o1, c2 := run(t, svc, "u", "win", latest, 1, p1.NextPageToken) // k picks the tier, not the query size: 20 rows
		if len(o1.Posts) != 1 || o1.NextPageToken == "" {
			t.Fatalf("older page at k=1: %d posts, token %q", len(o1.Posts), o1.NextPageToken)
		}
		exact(t, "older page at k=1 (20-row window)", c2, 20+1)
		o21, c3 := run(t, svc, "u", "win", latest, 21, p1.NextPageToken)
		if len(o21.Posts) != 21 || o21.NextPageToken == "" {
			t.Fatalf("older page at k=21: %d posts, token %q", len(o21.Posts), o21.NextPageToken)
		}
		exact(t, "older page at k=21 (50-row window)", c3, 50+1)
	})

	t.Run("page 1 at 31 is one 50-row query", func(t *testing.T) {
		svc := newInstance(t, client)
		p1, c := run(t, svc, "u", "win", latest, 31, "")
		if len(p1.Posts) != 31 || p1.NextPageToken == "" {
			t.Fatalf("page 1 at k=31: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		exact(t, "page 1 at k=31 cold", c, 1+50+1)
	})

	t.Run("a tail page reads the rows left", func(t *testing.T) {
		svc := newInstance(t, client)
		p1, c1 := run(t, svc, "u", "small", latest, 1, "")
		if len(p1.Posts) != 1 || p1.NextPageToken == "" {
			t.Fatalf("page 1 at k=1: %d posts, token %q", len(p1.Posts), p1.NextPageToken)
		}
		exact(t, "page 1 of a 25-post tag", c1, 1+25+1)
		p2, c2 := run(t, svc, "u", "small", latest, 20, p1.NextPageToken)
		if len(p2.Posts) != 20 || p2.NextPageToken == "" || ids(p2)[0] != pid(224) {
			t.Fatalf("tail page: %d posts, token %q", len(p2.Posts), p2.NextPageToken)
		}
		exact(t, "tail page: 24 rows left", c2, 24+1)
		p3, c3 := run(t, svc, "u", "small", latest, 20, p2.NextPageToken)
		if len(p3.Posts) != 4 || p3.NextPageToken != "" {
			t.Fatalf("last tail page: %d posts, token %q", len(p3.Posts), p3.NextPageToken)
		}
		exact(t, "last tail page: 4 rows left", c3, 4+1)
	})
}
