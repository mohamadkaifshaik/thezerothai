package search

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

func following(req PostsRequest) PostsRequest {
	req.FromFollowing = true
	return req
}

func doWith(t *testing.T, r *rig, uid string, req PostsRequest) *searchv1.SearchPostsResponse {
	t.Helper()
	resp, err := r.svc.PostsWith(context.Background(), uid, req)
	if err != nil {
		t.Fatalf("PostsWith(%+v): %v", req, err)
	}
	return resp
}

// authoredBy builds posts 1..n newest first; post i is by followed when keep(i), else by "stranger".
func authoredBy(n int, keep func(int) bool) []*posts.Post {
	return newestFirst(n, func(i int, p *posts.Post) {
		p.AuthorID = "stranger"
		if keep(i) {
			p.AuthorID = "friend"
		}
	})
}

func followsFriend(s *graph.Snapshot) { s.Following["friend"] = true }

// TestFromFollowing_Flag: from_following with search_filters off is FEATURE_DISABLED search_filters before any read; false never
// checks the flag; search off still wins first.
func TestFromFollowing_Flag(t *testing.T) {
	r := newRig(map[string][]*posts.Post{"go": authoredBy(5, func(int) bool { return true })}, withSnap(followsFriend))
	_, err := r.svc.PostsWith(context.Background(), "u", PostsRequest{Query: "go", FromFollowing: true})
	ae := apiErr(t, err)
	if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagSearchFilters {
		t.Fatalf("got %v %v %v", ae.Code, ae.Reason, ae.Metadata)
	}
	if r.reader.callCount() != 0 {
		t.Fatal("a disabled filter read posts")
	}
	if resp := doWith(t, r, "u", PostsRequest{Query: "go"}); len(resp.GetPosts()) != 5 {
		t.Fatalf("unfiltered = %d rows", len(resp.GetPosts()))
	}
	off := newRig(nil, withFlag(FlagSearchFilters))
	off.svc = New(flagMap{FlagSearchFilters: true}, WithPosts(PostsDeps{Posts: off.reader, Graph: off.graph, Authors: off.authors, CursorKey: testKey, Now: off.now}))
	if ae := apiErr(t, func() error {
		_, err := off.svc.PostsWith(context.Background(), "u", PostsRequest{Query: "go", FromFollowing: true})
		return err
	}()); ae.Metadata["feature"] != FlagSearch {
		t.Fatalf("search off: feature = %q", ae.Metadata["feature"])
	}
}

// TestFromFollowing_KeepsOnlyFollowedAuthors: every tab drops strangers and the caller's own posts; other filters still apply
// (a followed author the caller mutes stays out).
func TestFromFollowing_KeepsOnlyFollowedAuthors(t *testing.T) {
	rows := newestFirst(6, func(i int, p *posts.Post) {
		switch i {
		case 6, 4:
			p.AuthorID = "friend"
		case 5:
			p.AuthorID = "u" // the caller
		case 3:
			p.AuthorID = "muted"
		default:
			p.AuthorID = "stranger"
		}
	})
	snap := func(s *graph.Snapshot) {
		s.Following["friend"], s.Following["muted"] = true, true
		s.Muted["muted"] = true
	}
	for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_TOP, searchv1.SearchTab_SEARCH_TAB_LATEST} {
		r := newRig(map[string][]*posts.Post{"go": rows}, withSnap(snap), withFlag(FlagSearchFilters))
		got := ids(doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: tab})))
		if len(got) != 2 || !contains(got, idOf(6)) || !contains(got, idOf(4)) {
			t.Fatalf("%v: got %v", tab, got)
		}
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// TestFromFollowing_RecallCapAndResume: LATEST scans at most 3 windows (entry 30, then two older windows of 20), stops early once
// page_size rows are kept, and its token resumes after the last queried row; a following token does not open an unfiltered call.
func TestFromFollowing_RecallCapAndResume(t *testing.T) {
	// 200 posts; only every 25th is by a followed author: posts 200, 175, 150, ...
	rows := authoredBy(200, func(i int) bool { return i%25 == 0 })
	r := newRig(map[string][]*posts.Post{"go": rows}, withSnap(followsFriend), withFlag(FlagSearchFilters))
	latest := searchv1.SearchTab_SEARCH_TAB_LATEST
	p1 := doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: latest, PageSize: 10}))
	// Windows: posts 200..171 (entry), 170..151, 150..131 => kept 200, 175, 150; the cap stops it with a token.
	if got := ids(p1); len(got) != 3 || got[0] != idOf(200) || got[2] != idOf(150) {
		t.Fatalf("page 1 = %v", got)
	}
	if p1.GetNextPageToken() == "" {
		t.Fatal("a capped scan must issue a token")
	}
	if n := r.reader.callCount(); n != 3 {
		t.Fatalf("windows read = %d, want 3 (recall cap)", n)
	}
	p2 := doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: latest, PageSize: 10, PageToken: p1.GetNextPageToken()}))
	if got := ids(p2); len(got) != 3 || got[0] != idOf(125) || got[2] != idOf(75) {
		t.Fatalf("page 2 = %v (must resume after post 131)", got)
	}
	// The token of a following chain is refused by an unfiltered call, and the reverse.
	if _, err := r.svc.PostsWith(context.Background(), "u", PostsRequest{Query: "go", Tab: latest, PageSize: 10, PageToken: p1.GetNextPageToken()}); apiErr(t, err).Metadata["field"] != "page_token" {
		t.Fatal("a following token opened an unfiltered call")
	}
	plain := doWith(t, r, "u", PostsRequest{Query: "go", Tab: latest, PageSize: 10})
	if _, err := r.svc.PostsWith(context.Background(), "u", following(PostsRequest{Query: "go", Tab: latest, PageSize: 10, PageToken: plain.GetNextPageToken()})); apiErr(t, err).Metadata["field"] != "page_token" {
		t.Fatal("an unfiltered token opened a following call")
	}
}

// TestFromFollowing_StopsEarlyAndCuts: with enough followed posts in the first window, one window is read and the page is cut at
// page_size with the token after the last returned row.
func TestFromFollowing_StopsEarlyAndCuts(t *testing.T) {
	rows := authoredBy(40, func(i int) bool { return i%2 == 0 })
	r := newRig(map[string][]*posts.Post{"go": rows}, withSnap(followsFriend), withFlag(FlagSearchFilters))
	latest := searchv1.SearchTab_SEARCH_TAB_LATEST
	p1 := doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: latest, PageSize: 5}))
	if got := ids(p1); len(got) != 5 || got[4] != idOf(32) || p1.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v token %q", got, p1.GetNextPageToken())
	}
	if n := r.reader.callCount(); n != 1 {
		t.Fatalf("windows read = %d, want 1", n)
	}
	p2 := doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: latest, PageSize: 5, PageToken: p1.GetNextPageToken()}))
	if got := ids(p2); len(got) != 5 || got[0] != idOf(30) {
		t.Fatalf("page 2 = %v", got)
	}
}

// TestFromFollowing_EndOfTag: a window that is not full ends the chain (no token) and an empty result is an empty page.
func TestFromFollowing_EndOfTag(t *testing.T) {
	rows := authoredBy(12, func(i int) bool { return i == 3 })
	r := newRig(map[string][]*posts.Post{"go": rows}, withSnap(followsFriend), withFlag(FlagSearchFilters))
	for _, tab := range []searchv1.SearchTab{searchv1.SearchTab_SEARCH_TAB_LATEST, searchv1.SearchTab_SEARCH_TAB_MEDIA} {
		resp := doWith(t, r, "u", following(PostsRequest{Query: "go", Tab: tab}))
		if resp.GetNextPageToken() != "" {
			t.Fatalf("%v: token at the end of the tag", tab)
		}
		if tab == searchv1.SearchTab_SEARCH_TAB_LATEST && (len(resp.GetPosts()) != 1 || ids(resp)[0] != idOf(3)) {
			t.Fatalf("latest = %v", ids(resp))
		}
		if tab == searchv1.SearchTab_SEARCH_TAB_MEDIA && len(resp.GetPosts()) != 0 {
			t.Fatalf("media without images = %v", ids(resp))
		}
	}
}
