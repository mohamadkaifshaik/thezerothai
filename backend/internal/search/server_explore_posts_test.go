package search

import (
	"context"
	"reflect"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// explorePostsServer is the Connect handler over a wired service whose flags come from reg.
func explorePostsServer(reg FlagChecker, feed []*posts.Post) (*Server, *fakeReader) {
	rd := &fakeReader{latest: feed}
	deps := PostsDeps{Posts: rd, Graph: &fakeGraph{snap: snapshot()}, Viewer: &fakeViewer{}, Authors: newStatusDir(), CursorKey: testKey, Now: func() time.Time { return t0 }}
	return NewServer(New(reg, WithPosts(deps))), rd
}

// TestServer_ExplorePosts_FlagModes: every FEATURE_TRENDING_POSTS mode, with search on for everyone. A caller the flag
// leaves out gets FAILED_PRECONDITION FEATURE_DISABLED feature=trending_posts and reads nothing; a caller it lets in gets a page.
func TestServer_ExplorePosts_FlagModes(t *testing.T) {
	const in, out = "uid-in", "uid-out"
	modes := []struct {
		name    string
		spec    flags.Spec
		wantIn  bool
		wantOut bool
	}{
		{"off", flags.Spec{Name: FlagTrendingPosts, Mode: flags.Off}, false, false},
		{"allowlist", flags.Spec{Name: FlagTrendingPosts, Mode: flags.Allowlist, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 0 + allowlist", flags.Spec{Name: FlagTrendingPosts, Mode: flags.Percent, Allowlist: map[string]struct{}{in: {}}}, true, false},
		{"percent 100", flags.Spec{Name: FlagTrendingPosts, Mode: flags.Percent, Percent: 100}, true, true},
		{"on", flags.Spec{Name: FlagTrendingPosts, Mode: flags.On}, true, true},
	}
	for _, m := range modes {
		t.Run(m.name, func(t *testing.T) {
			// trending_media is on for everyone: it must open nothing here.
			reg := flags.NewRegistry(flags.Spec{Name: FlagSearch, Mode: flags.On}, flags.Spec{Name: FlagTrendingMedia, Mode: flags.On}, m.spec)
			srv, rd := explorePostsServer(reg, []*posts.Post{mkPost(1, "a")})
			for uid, wantOn := range map[string]bool{in: m.wantIn, out: m.wantOut} {
				before := len(rd.latestCalls)
				resp, err := srv.ExplorePosts(signedIn(uid), connect.NewRequest(&searchv1.ExplorePostsRequest{}))
				if wantOn {
					if err != nil || len(resp.Msg.GetPosts()) != 1 {
						t.Errorf("%s: err = %v, want one post", uid, err)
					}
					continue
				}
				ae := apiErr(t, err)
				if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagTrendingPosts {
					t.Errorf("%s: %v / %v feature=%q, want FAILED_PRECONDITION FEATURE_DISABLED feature=%s", uid, ae.Code, ae.Reason, ae.Metadata["feature"], FlagTrendingPosts)
				}
				if len(rd.latestCalls) != before {
					t.Errorf("%s: a disabled call read the feed", uid)
				}
			}
		})
	}
}

// TestServer_ExplorePosts_PassesRequestAndCaller: the handler takes the uid from the token (never the request), passes
// page_size and page_token through, and refuses an unauthenticated call before any read.
func TestServer_ExplorePosts_PassesRequestAndCaller(t *testing.T) {
	reg := flags.NewRegistry(flags.Spec{Name: FlagSearch, Mode: flags.On}, flags.Spec{Name: FlagTrendingPosts, Mode: flags.On})
	srv, rd := explorePostsServer(reg, []*posts.Post{mkPost(3, "a"), mkPost(2, "a"), mkPost(1, "a")})

	if _, err := srv.ExplorePosts(context.Background(), connect.NewRequest(&searchv1.ExplorePostsRequest{})); apiErr(t, err).Code != connect.CodeUnauthenticated {
		t.Fatalf("no caller: err = %v, want Unauthenticated", err)
	}
	if len(rd.latestCalls) != 0 {
		t.Fatal("an unauthenticated call read the feed")
	}

	first, err := srv.ExplorePosts(signedIn("uid-a"), connect.NewRequest(&searchv1.ExplorePostsRequest{PageSize: 2}))
	if err != nil {
		t.Fatal(err)
	}
	if got := postIDs(first.Msg); !reflect.DeepEqual(got, []string{idOf(3), idOf(2)}) || first.Msg.GetNextPageToken() == "" {
		t.Fatalf("page 1 = %v token %q, want posts 3 and 2 and a token", got, first.Msg.GetNextPageToken())
	}
	next := &searchv1.ExplorePostsRequest{PageSize: 2, PageToken: first.Msg.GetNextPageToken()}
	second, err := srv.ExplorePosts(signedIn("uid-a"), connect.NewRequest(next))
	if err != nil {
		t.Fatal(err)
	}
	if got := postIDs(second.Msg); !reflect.DeepEqual(got, []string{idOf(1)}) || second.Msg.GetNextPageToken() != "" {
		t.Fatalf("page 2 = %v token %q, want post 1 and no token", got, second.Msg.GetNextPageToken())
	}
	// The token is sealed to the caller: another signed-in user cannot replay it.
	_, err = srv.ExplorePosts(signedIn("uid-b"), connect.NewRequest(next))
	if ae := apiErr(t, err); ae.Reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || ae.Metadata["field"] != "page_token" {
		t.Fatalf("foreign token: %v field=%q, want VALIDATION page_token", ae.Reason, ae.Metadata["field"])
	}
}
