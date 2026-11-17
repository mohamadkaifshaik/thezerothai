package search

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// newFeedRig is a service over one global newest-posts fixture (newest first) with search and trending_posts on; opts may
// change the flags (withoutFlag), the graph snapshot, the protected set or the author status.
func newFeedRig(feed []*posts.Post, opts ...rigOpt) *rig {
	r := &rig{reader: &fakeReader{latest: feed}, graph: &fakeGraph{snap: snapshot()}, viewer: &fakeViewer{}, authors: newStatusDir(), clock: t0}
	deps := PostsDeps{Posts: r.reader, Graph: r.graph, Viewer: r.viewer, Authors: r.authors, CursorKey: testKey, Now: r.now}
	fl := flagMap{FlagSearch: true, FlagTrendingPosts: true}
	for _, o := range opts {
		o(r, &deps, fl)
	}
	r.svc = New(fl, WithPosts(deps))
	return r
}

func withoutFlag(name string) rigOpt {
	return func(_ *rig, _ *PostsDeps, fl flagMap) { delete(fl, name) }
}

func postIDs(resp *searchv1.ExplorePostsResponse) []string {
	out := make([]string, 0, len(resp.GetPosts()))
	for _, v := range resp.GetPosts() {
		out = append(out, v.GetPost().GetPostId())
	}
	return out
}

func explorePosts(t *testing.T, r *rig, uid string, size int32, token string) *searchv1.ExplorePostsResponse {
	t.Helper()
	resp, err := r.svc.ExplorePosts(context.Background(), uid, size, token)
	if err != nil {
		t.Fatalf("ExplorePosts(%q, %d, %q): %v", uid, size, token, err)
	}
	return resp
}

// drainPosts follows next_page_token from the first page to the end and returns every id in order plus the page count.
func drainPosts(t *testing.T, r *rig, uid string, size int32) ([]string, int) {
	t.Helper()
	var all []string
	token, pages := "", 0
	for {
		resp := explorePosts(t, r, uid, size, token)
		pages++
		all = append(all, postIDs(resp)...)
		token = resp.GetNextPageToken()
		if token == "" {
			return all, pages
		}
		if pages > 100 {
			t.Fatal("the token chain never ends")
		}
	}
}

func TestExplorePosts_Flags(t *testing.T) {
	feed := []*posts.Post{mkPost(2, "a")}
	tests := []struct {
		name     string
		off      []string
		wantFeat string // "" when the call must succeed
	}{
		{"search off and trending_posts off", []string{FlagSearch, FlagTrendingPosts}, FlagSearch},
		{"search on, trending_posts off", []string{FlagTrendingPosts}, FlagTrendingPosts},
		{"trending_posts on, search off", []string{FlagSearch}, FlagSearch},
		{"both on", nil, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var opts []rigOpt
			for _, f := range tt.off {
				opts = append(opts, withoutFlag(f))
			}
			r := newFeedRig(feed, opts...)
			_, err := r.svc.ExplorePosts(context.Background(), "u1", 0, "")
			if tt.wantFeat == "" {
				if err != nil {
					t.Fatalf("err = %v, want success", err)
				}
				return
			}
			// The same error ExploreMedia returns for its flag: FAILED_PRECONDITION FEATURE_DISABLED, metadata feature=<flag>.
			wantAPIError(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "")
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["feature"] != tt.wantFeat {
				t.Fatalf("err = %v, want feature=%s", err, tt.wantFeat)
			}
			if n := len(r.reader.latestCalls); n != 0 || r.graph.calls.Load() != 0 {
				t.Fatalf("a disabled call read the feed %d times and the graph %d times, want 0 (flags come first)", n, r.graph.calls.Load())
			}
		})
	}
}

// The trending_media flag alone does not open ExplorePosts, and trending_posts alone does not open ExploreMedia.
func TestExplorePosts_FlagIsItsOwn(t *testing.T) {
	r := newFeedRig(nil, withoutFlag(FlagTrendingPosts), withFlag(FlagTrendingMedia))
	if _, err := r.svc.ExplorePosts(context.Background(), "u1", 0, ""); err == nil {
		t.Fatal("ExplorePosts with only trending_media on: want FEATURE_DISABLED")
	}
	r = newFeedRig(nil)
	if _, err := r.svc.ExploreMedia(context.Background(), "u1", 0, ""); err == nil {
		t.Fatal("ExploreMedia with only trending_posts on: want FEATURE_DISABLED")
	}
}

func TestExplorePosts_RowRules(t *testing.T) {
	reply := func(p *posts.Post) { p.IsReply, p.Kind = true, posts.KindReply }
	repost := func(p *posts.Post) { p.Kind, p.EmbeddedAuthorID = posts.KindRepost, "a" }
	quoteOf := func(author string) func(*posts.Post) {
		return func(p *posts.Post) { p.Kind, p.EmbeddedAuthorID = posts.KindQuote, author }
	}
	hidden := func(p *posts.Post) { p.Moderation = posts.ModerationTakenDown }
	feed := []*posts.Post{
		mkPost(12, "a"),                // plain root post: kept
		mkPost(11, "a", withMediaOwn),  // root post with images: kept (this feed is not media-only)
		mkPost(10, "b", quoteOf("a")),  // quote: kept
		mkPost(9, "a", reply),          // reply: never lists
		mkPost(8, "a", repost),         // REPOST: never lists
		mkPost(7, "a", hidden),         // taken down: dropped
		mkPost(6, "bad"),               // per-case author
		mkPost(5, "b", quoteOf("bad")), // quote of the per-case author
		mkPost(4, "prot"),              // protected author
		mkPost(3, "u1"),                // the caller's own post: kept
		mkPost(2, "gone"),              // per-case author status
		mkPost(1, "b", func(p *posts.Post) { p.IsReply = true }), // a reply stored with kind POST still never lists
	}
	base := []string{idOf(12), idOf(11), idOf(10), idOf(3)}
	with := func(extra ...string) []string {
		set := map[string]bool{}
		for _, id := range append(append([]string{}, base...), extra...) {
			set[id] = true
		}
		var out []string
		for _, p := range feed {
			if set[p.ID] {
				out = append(out, p.ID)
			}
		}
		return out
	}
	// The default rig: nobody blocked or muted, nobody protected, everyone ACTIVE.
	everyone := with(idOf(6), idOf(5), idOf(4), idOf(2))
	tests := []struct {
		name string
		opts []rigOpt
		want []string
	}{
		{"no viewer rule: replies, REPOSTs and hidden posts dropped", nil, everyone},
		{"protected author followed: kept", []rigOpt{
			withProtected(fakeProtected{set: protectedSet{"prot": true}}),
			withSnap(func(s *graph.Snapshot) { s.Following["prot"] = true }),
		}, everyone},
		{"caller blocks the author (and quotes of them)", []rigOpt{withSnap(func(s *graph.Snapshot) { s.Blocked["bad"] = true })}, with(idOf(4), idOf(2))},
		{"the author blocks the caller (and quotes of them)", []rigOpt{withSnap(func(s *graph.Snapshot) { s.BlockedBy["bad"] = true })}, with(idOf(4), idOf(2))},
		{"caller mutes the author (and quotes of them)", []rigOpt{withSnap(func(s *graph.Snapshot) { s.Muted["bad"] = true })}, with(idOf(4), idOf(2))},
		{"suspended author dropped", []rigOpt{withAuthorStatus("gone", "suspended")}, with(idOf(6), idOf(5), idOf(4))},
		{"deleting author dropped", []rigOpt{withAuthorStatus("gone", "deleting")}, with(idOf(6), idOf(5), idOf(4))},
		{"missing author dropped", []rigOpt{withAuthorStatus("gone", "missing")}, with(idOf(6), idOf(5), idOf(4))},
		{"protected author not followed: dropped", []rigOpt{withProtected(fakeProtected{set: protectedSet{"prot": true}})}, with(idOf(6), idOf(5), idOf(2))},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newFeedRig(feed, tt.opts...)
			got := postIDs(explorePosts(t, r, "u1", 50, ""))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("ids = %v, want %v", got, tt.want)
			}
		})
	}
}

// A quote of a protected author the caller does not follow is kept with the embed stripped (embed_viewer_state PROTECTED),
// as on ExploreMedia and SearchPosts.
func TestExplorePosts_QuoteOfProtectedKeptStripped(t *testing.T) {
	q := mkPost(1, "b", func(p *posts.Post) { p.Kind, p.EmbeddedAuthorID = posts.KindQuote, "prot" })
	r := newFeedRig([]*posts.Post{q}, withProtected(fakeProtected{set: protectedSet{"prot": true}}))
	resp := explorePosts(t, r, "u1", 0, "")
	if len(resp.GetPosts()) != 1 {
		t.Fatalf("posts = %v, want the quote", postIDs(resp))
	}
	if st := resp.GetPosts()[0].GetEmbedViewerState(); st != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED {
		t.Fatalf("embed_viewer_state = %v, want PROTECTED", st)
	}
}

// Paging: every kept post exactly once, newest first, whatever the page size, with dropped rows between the kept ones and
// with posts that share one createdAt (the id breaks the tie, as __name__ DESC does in Firestore).
func TestExplorePosts_PagingNoGapsNoDuplicates(t *testing.T) {
	var feed []*posts.Post
	for n := 130; n >= 1; n-- {
		p := mkPost(n, "a")
		switch {
		case n%3 == 0:
			p.IsReply, p.Kind = true, posts.KindReply
		case n%7 == 0:
			p.Moderation = posts.ModerationTakenDown
		}
		if n%5 == 0 { // pairs share a timestamp: n and n-1 both at n-1's createdAt
			p.CreatedAt = mkPost(n-1, "a").CreatedAt
		}
		feed = append(feed, p)
	}
	// Re-sort the fixture into the query order (createdAt DESC, id DESC).
	for i := 1; i < len(feed); i++ {
		for j := i; j > 0 && (feed[j].CreatedAt.After(feed[j-1].CreatedAt) || (feed[j].CreatedAt.Equal(feed[j-1].CreatedAt) && feed[j].ID > feed[j-1].ID)); j-- {
			feed[j], feed[j-1] = feed[j-1], feed[j]
		}
	}
	var want []string
	for _, p := range feed {
		if !p.IsReply && p.Visible() {
			want = append(want, p.ID)
		}
	}
	for _, size := range []int32{1, 2, 7, 20, 50} {
		r := newFeedRig(feed)
		got, _ := drainPosts(t, r, "u1", size)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("page_size %d: drained %d ids, want %d (gap, duplicate or order change)\n got %v\nwant %v", size, len(got), len(want), got, want)
		}
		for _, n := range r.reader.latestCalls {
			if n != postsFeedWindow {
				t.Fatalf("page_size %d: a call scanned %d rows, want the fixed %d", size, n, postsFeedWindow)
			}
		}
	}
}

// A whole scan window of dropped rows returns an EMPTY page with a token, and the token moves past them.
func TestExplorePosts_EmptyPageKeepsToken(t *testing.T) {
	var feed []*posts.Post
	for n := postsFeedWindow + 3; n >= 1; n-- {
		p := mkPost(n, "a")
		if n > 3 {
			p.IsReply, p.Kind = true, posts.KindReply
		}
		feed = append(feed, p)
	}
	r := newFeedRig(feed)
	first := explorePosts(t, r, "u1", 10, "")
	if len(first.GetPosts()) != 0 || first.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v token %q, want empty with a token", postIDs(first), first.GetNextPageToken())
	}
	second := explorePosts(t, r, "u1", 10, first.GetNextPageToken())
	if got, want := postIDs(second), []string{idOf(3), idOf(2), idOf(1)}; !reflect.DeepEqual(got, want) {
		t.Fatalf("page 2 = %v, want %v", got, want)
	}
	if second.GetNextPageToken() != "" {
		t.Fatal("page 2 reached the end of the feed: want no token")
	}
}

func TestExplorePosts_PageSizeClamp(t *testing.T) {
	var feed []*posts.Post
	for n := 120; n >= 1; n-- {
		feed = append(feed, mkPost(n, "a"))
	}
	tests := []struct {
		size int32
		want int
	}{
		{0, limits.DefaultPageSize},
		{1, 1},
		{limits.MaxPageSize, limits.MaxPageSize},
		{limits.MaxPageSize + 1, limits.MaxPageSize},
		{10000, limits.MaxPageSize},
	}
	for _, tt := range tests {
		r := newFeedRig(feed)
		resp := explorePosts(t, r, "u1", tt.size, "")
		if len(resp.GetPosts()) != tt.want || resp.GetNextPageToken() == "" {
			t.Fatalf("page_size %d: %d posts token %q, want %d and a token", tt.size, len(resp.GetPosts()), resp.GetNextPageToken(), tt.want)
		}
		if !reflect.DeepEqual(r.reader.latestCalls, []int{postsFeedWindow}) {
			t.Fatalf("page_size %d: scans %v, want one of %d", tt.size, r.reader.latestCalls, postsFeedWindow)
		}
	}
}

func TestExplorePosts_InvalidInputsReadNothing(t *testing.T) {
	feed := []*posts.Post{mkPost(2, "a"), mkPost(1, "a")}
	r := newFeedRig(feed, withFlag(FlagTrendingMedia))
	r.reader.media = []*posts.Post{mkPost(2, "a", withMediaOwn), mkPost(1, "a", withMediaOwn)}
	first := explorePosts(t, r, "u1", 1, "")
	if first.GetNextPageToken() == "" {
		t.Fatal("setup: want a next page token from the first page")
	}
	mediaPage, err := r.svc.ExploreMedia(context.Background(), "u1", 1, "")
	if err != nil {
		t.Fatalf("setup ExploreMedia: %v", err)
	}
	if mediaPage.GetNextPageToken() == "" {
		t.Fatal("setup: want a next page token from ExploreMedia")
	}
	tests := []struct {
		name  string
		uid   string
		size  int32
		token string
		field string
	}{
		{"negative page_size", "u1", -1, "", "page_size"},
		{"garbage token", "u1", 1, "not-a-token", "page_token"},
		{"token of another caller", "u2", 1, first.GetNextPageToken(), "page_token"},
		{"an ExploreMedia token", "u1", 1, mediaPage.GetNextPageToken(), "page_token"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			before := len(r.reader.latestCalls)
			_, err := r.svc.ExplorePosts(context.Background(), tt.uid, tt.size, tt.token)
			wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, tt.field)
			if len(r.reader.latestCalls) != before {
				t.Fatalf("a rejected call read the feed")
			}
		})
	}
}

func TestExplorePosts_NotWiredIsUnimplemented(t *testing.T) {
	svc := New(flagMap{FlagSearch: true, FlagTrendingPosts: true})
	_, err := svc.ExplorePosts(context.Background(), "u1", 0, "")
	wantAPIError(t, err, connect.CodeUnimplemented, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "")
}

func TestExplorePosts_QueryErrorIsAnError(t *testing.T) {
	r := newFeedRig([]*posts.Post{mkPost(1, "a")})
	r.reader.err = errors.New("firestore down")
	if _, err := r.svc.ExplorePosts(context.Background(), "u1", 0, ""); err == nil {
		t.Fatal("want the query error")
	}
}

// The rows are standard post cards: the viewer's liked and bookmarked flags come from one userLikes read per page with
// rows, and an empty page reads no viewer state and no graph.
func TestExplorePosts_ViewerFlags(t *testing.T) {
	r := newFeedRig([]*posts.Post{mkPost(2, "a"), mkPost(1, "a")}, withFlag(posts.EngagementFlagName))
	r.viewer.set = posts.NewViewerSetWithBookmarks([]string{idOf(2)}, nil, []string{idOf(1)})
	resp := explorePosts(t, r, "u1", 0, "")
	if r.viewer.calls.Load() != 1 {
		t.Fatalf("userLikes reads = %d, want 1", r.viewer.calls.Load())
	}
	byID := map[string]*postsv1.PostView{}
	for _, v := range resp.GetPosts() {
		byID[v.GetPost().GetPostId()] = v
	}
	if !byID[idOf(2)].GetLikedByViewer() || !byID[idOf(1)].GetBookmarkedByViewer() || byID[idOf(1)].GetLikedByViewer() {
		t.Fatalf("viewer flags wrong: %v", resp.GetPosts())
	}

	empty := newFeedRig(nil, withFlag(posts.EngagementFlagName))
	if resp := explorePosts(t, empty, "u1", 0, ""); len(resp.GetPosts()) != 0 || resp.GetNextPageToken() != "" {
		t.Fatalf("empty feed: %v token %q", postIDs(resp), resp.GetNextPageToken())
	}
	if empty.viewer.calls.Load() != 0 || empty.graph.calls.Load() != 0 {
		t.Fatalf("empty feed: viewer reads %d graph reads %d, want 0 0", empty.viewer.calls.Load(), empty.graph.calls.Load())
	}
}
