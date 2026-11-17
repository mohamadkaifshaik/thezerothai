package search

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// newMediaRig is a service over one global media feed fixture (newest first) and the given flags.
func newMediaRig(fl flagMap, feed []*posts.Post, snap func(*graph.Snapshot)) *rig {
	r := &rig{reader: &fakeReader{media: feed}, graph: &fakeGraph{snap: snapshot()}, viewer: &fakeViewer{}, authors: newStatusDir(), clock: t0}
	if snap != nil {
		snap(&r.graph.snap)
	}
	deps := PostsDeps{Posts: r.reader, Graph: r.graph, Viewer: r.viewer, Authors: r.authors, CursorKey: testKey, Now: r.now}
	r.svc = New(fl, WithPosts(deps))
	return r
}

func withMediaOwn(p *posts.Post) { p.Media = []posts.MediaRef{{ID: "m", URL: "u"}} }

func feedIDs(resp *searchv1.ExploreMediaResponse) []string {
	ids := make([]string, 0, len(resp.GetPosts()))
	for _, v := range resp.GetPosts() {
		ids = append(ids, v.GetPost().GetPostId())
	}
	return ids
}

func explore(t *testing.T, r *rig, uid string, size int32, token string) *searchv1.ExploreMediaResponse {
	t.Helper()
	resp, err := r.svc.ExploreMedia(context.Background(), uid, size, token)
	if err != nil {
		t.Fatalf("ExploreMedia(%q, %d, %q): %v", uid, size, token, err)
	}
	return resp
}

func TestExploreMedia_Flags(t *testing.T) {
	feed := []*posts.Post{mkPost(2, "a", withMediaOwn)}
	tests := []struct {
		name     string
		fl       flagMap
		wantFeat string // "" when the call must succeed
	}{
		{"search off and trending off", flagMap{}, FlagSearch},
		{"search on, trending off", flagMap{FlagSearch: true}, FlagTrendingMedia},
		{"trending on, search off", flagMap{FlagTrendingMedia: true}, FlagSearch},
		{"both on", flagMap{FlagSearch: true, FlagTrendingMedia: true}, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newMediaRig(tt.fl, feed, nil)
			_, err := r.svc.ExploreMedia(context.Background(), "u1", 0, "")
			if tt.wantFeat == "" {
				if err != nil {
					t.Fatalf("err = %v, want success", err)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Metadata["feature"] != tt.wantFeat {
				t.Fatalf("err = %v, want FEATURE_DISABLED feature=%s", err, tt.wantFeat)
			}
			if n := len(r.reader.mediaCalls); n != 0 {
				t.Fatalf("a disabled call read %d times, want 0 (flags are checked before any read)", n)
			}
		})
	}
}

func TestExploreMedia_RowRules(t *testing.T) {
	reply := mkPost(4, "a", withMediaOwn)
	reply.IsReply, reply.Kind = true, posts.KindReply
	repost := mkPost(3, "a")
	repost.Kind = posts.KindRepost
	feed := []*posts.Post{
		mkPost(6, "b", withMediaOwn), // root with its own images: kept
		mkPost(5, "a", withMediaOwn), // kept
		reply,                        // a reply never lists
		repost,                       // a REPOST never lists
		mkPost(2, "c"),               // no images
		mkPost(1, "bad", withMediaOwn),
	}
	tests := []struct {
		name string
		snap func(*graph.Snapshot)
		want []string
	}{
		{"root media kept, reply/repost/no-media dropped", nil, []string{idOf(6), idOf(5), idOf(1)}},
		{"a blocked author's post is dropped", func(s *graph.Snapshot) { s.Blocked["bad"] = true }, []string{idOf(6), idOf(5)}},
		{"a muted author's post is dropped", func(s *graph.Snapshot) { s.Muted["bad"] = true }, []string{idOf(6), idOf(5)}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newMediaRig(flagMap{FlagSearch: true, FlagTrendingMedia: true}, feed, tt.snap)
			got := feedIDs(explore(t, r, "u1", 10, ""))
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("ids = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestExploreMedia_PagesNewestFirstWithToken(t *testing.T) {
	var feed []*posts.Post
	for n := 5; n >= 1; n-- {
		feed = append(feed, mkPost(n, "a", withMediaOwn))
	}
	r := newMediaRig(flagMap{FlagSearch: true, FlagTrendingMedia: true}, feed, nil)
	want := [][]string{{idOf(5), idOf(4)}, {idOf(3), idOf(2)}, {idOf(1)}}
	token := ""
	for i, page := range want {
		resp := explore(t, r, "u1", 2, token)
		if got := feedIDs(resp); !reflect.DeepEqual(got, page) {
			t.Fatalf("page %d ids = %v, want %v", i+1, got, page)
		}
		token = resp.GetNextPageToken()
		if (token == "") != (i == len(want)-1) {
			t.Fatalf("page %d token empty = %v, want only the last page to end the feed", i+1, token == "")
		}
	}
}

func TestExploreMedia_InvalidInputsReadNothing(t *testing.T) {
	feed := []*posts.Post{mkPost(2, "a", withMediaOwn), mkPost(1, "a", withMediaOwn)}
	r := newMediaRig(flagMap{FlagSearch: true, FlagTrendingMedia: true}, feed, nil)
	first := explore(t, r, "u1", 1, "")
	if first.GetNextPageToken() == "" {
		t.Fatal("setup: want a next page token from the first page")
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
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			before := len(r.reader.mediaCalls)
			_, err := r.svc.ExploreMedia(context.Background(), tt.uid, tt.size, tt.token)
			wantAPIError(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, tt.field)
			if len(r.reader.mediaCalls) != before {
				t.Fatalf("a rejected call read the feed")
			}
		})
	}
}

func TestExploreMedia_NotWiredIsUnimplemented(t *testing.T) {
	svc := New(flagMap{FlagSearch: true, FlagTrendingMedia: true})
	_, err := svc.ExploreMedia(context.Background(), "u1", 0, "")
	wantAPIError(t, err, connect.CodeUnimplemented, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "")
}
