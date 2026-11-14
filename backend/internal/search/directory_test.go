package search

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type fakeListSearcher struct {
	page    lists.SearchListsPage
	err     error
	calls   int
	prefix  string
	size    int32
	gotTok  string
	gotUser string
}

func (f *fakeListSearcher) SearchLists(_ context.Context, viewer, prefix string, size int32, tok string) (lists.SearchListsPage, error) {
	f.calls++
	f.gotUser, f.prefix, f.size, f.gotTok = viewer, prefix, size, tok
	return f.page, f.err
}

type fakeCommunitySearcher struct {
	page   communities.SearchPage
	calls  int
	prefix string
}

func (f *fakeCommunitySearcher) SearchCommunities(_ context.Context, _, prefix string, _ int32, _ string) (communities.SearchPage, error) {
	f.calls++
	f.prefix = prefix
	return f.page, nil
}

func onFlags(names ...string) *flags.Registry {
	specs := make([]flags.Spec, 0, len(names))
	for _, n := range names {
		specs = append(specs, flags.Spec{Name: n, Mode: flags.On})
	}
	return flags.NewRegistry(specs...)
}

type dirCall func(*Server, context.Context, string) error

func callLists(s *Server, ctx context.Context, q string) error {
	_, err := s.SearchLists(ctx, connect.NewRequest(&searchv1.SearchListsRequest{Query: q}))
	return err
}

func callCommunities(s *Server, ctx context.Context, q string) error {
	_, err := s.SearchCommunities(ctx, connect.NewRequest(&searchv1.SearchCommunitiesRequest{Query: q}))
	return err
}

// TestDirectory_FlagOrder: each of the three flags off is FEATURE_DISABLED naming that flag, checked before the grammar and before
// the module seam (0 calls); all on reaches the seam.
func TestDirectory_FlagOrder(t *testing.T) {
	for _, rpc := range []struct {
		name   string
		module string
		call   dirCall
	}{{"SearchLists", lists.FlagName, callLists}, {"SearchCommunities", communities.FlagName, callCommunities}} {
		all := []string{FlagSearch, FlagSearchLists, rpc.module}
		for i, off := range all {
			t.Run(rpc.name+"/"+off+" off", func(t *testing.T) {
				on := append(append([]string(nil), all[:i]...), all[i+1:]...)
				ls, cs := &fakeListSearcher{}, &fakeCommunitySearcher{}
				srv := NewServer(New(onFlags(on...), WithDirectory(DirectoryDeps{Lists: ls, Communities: cs})))
				ae := apiErr(t, rpc.call(srv, signedIn("u1"), "")) // an invalid query too: the flag wins
				if ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != off {
					t.Fatalf("got %v feature=%q, want FEATURE_DISABLED feature=%s", ae.Reason, ae.Metadata["feature"], off)
				}
				if ls.calls+cs.calls != 0 {
					t.Fatal("a disabled call reached a module")
				}
			})
		}
		t.Run(rpc.name+"/unwired is Unimplemented", func(t *testing.T) {
			srv := NewServer(New(onFlags(all...)))
			if ae := apiErr(t, rpc.call(srv, signedIn("u1"), "go")); ae.Code != connect.CodeUnimplemented {
				t.Fatalf("code = %v", ae.Code)
			}
		})
	}
}

// TestDirectory_Validation: the grammar runs before the seam; the seam receives the folded query.
func TestDirectory_Validation(t *testing.T) {
	ls, cs := &fakeListSearcher{}, &fakeCommunitySearcher{}
	svc := New(onFlags(FlagSearch, FlagSearchLists, lists.FlagName, communities.FlagName), WithDirectory(DirectoryDeps{Lists: ls, Communities: cs}))
	ctx := signedIn("u1")
	bad := []struct {
		name, query, field string
		size               int32
	}{
		{"empty", "  ", "query", 0},
		{"too long", "abcdefghijabcdefghijabcdefghijk", "query", 0},
		{"control", "a\x07b", "query", 0},
		{"bidi", "a\u202eb", "query", 0},
		{"negative page size", "go", "page_size", -1},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			for _, call := range []func() error{
				func() error { _, err := svc.Lists(ctx, "u1", tc.query, tc.size, ""); return err },
				func() error { _, err := svc.Communities(ctx, "u1", tc.query, tc.size, ""); return err },
			} {
				ae := apiErr(t, call())
				if ae.Code != connect.CodeInvalidArgument || ae.Metadata["field"] != tc.field {
					t.Fatalf("got %v field=%q, want VALIDATION %s", ae.Code, ae.Metadata["field"], tc.field)
				}
			}
		})
	}
	if ls.calls+cs.calls != 0 {
		t.Fatal("an invalid request reached a module")
	}
	if _, err := svc.Lists(ctx, "u1", "  Go Devs ", 5, "tok"); err != nil {
		t.Fatal(err)
	}
	if ls.prefix != "go devs" || ls.size != 5 || ls.gotTok != "tok" || ls.gotUser != "u1" {
		t.Fatalf("seam got %+v", ls)
	}
	if _, err := svc.Communities(ctx, "u1", "CAF\u00c9", 0, ""); err != nil || cs.prefix != "caf\u00e9" {
		t.Fatalf("communities seam got %q, %v", cs.prefix, err)
	}
}

// TestSearchLists_FollowFieldsFollowTheFlag: follower_count and followed_by_viewer only with list_follows on for the caller.
func TestSearchLists_FollowFieldsFollowTheFlag(t *testing.T) {
	page := lists.SearchListsPage{
		Views:         []lists.View{{Header: lists.Header{ID: "0000000000000000001", Name: "Go", FollowerCount: 4}, FollowedByViewer: true}},
		NextPageToken: "next",
	}
	for _, follows := range []bool{false, true} {
		names := []string{FlagSearch, FlagSearchLists, lists.FlagName}
		if follows {
			names = append(names, lists.FollowFlagName)
		}
		svc := New(onFlags(names...), WithDirectory(DirectoryDeps{Lists: &fakeListSearcher{page: page}}))
		resp, err := svc.Lists(signedIn("u1"), "u1", "go", 0, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(resp.GetLists()) != 1 || resp.GetNextPageToken() != "next" || resp.GetLists()[0].GetName() != "Go" {
			t.Fatalf("resp = %v", resp)
		}
		got := resp.GetLists()[0]
		if follows != (got.GetFollowerCount() == 4 && got.GetFollowedByViewer()) {
			t.Fatalf("follows=%v: follower_count=%d followed=%v", follows, got.GetFollowerCount(), got.GetFollowedByViewer())
		}
	}
}

func TestSearchCommunities_Renders(t *testing.T) {
	cs := &fakeCommunitySearcher{page: communities.SearchPage{
		Views: []communities.View{{Community: communities.Community{ID: "0000000000000000009", Name: "Go", Status: communities.StatusActive}, Role: communities.RoleMember}},
	}}
	svc := New(onFlags(FlagSearch, FlagSearchLists, communities.FlagName), WithDirectory(DirectoryDeps{Communities: cs}))
	resp, err := svc.Communities(signedIn("u1"), "u1", "go", 0, "")
	if err != nil || len(resp.GetCommunities()) != 1 || resp.GetCommunities()[0].GetCommunityId() != "0000000000000000009" ||
		resp.GetCommunities()[0].GetViewerRole().String() != "COMMUNITY_ROLE_MEMBER" {
		t.Fatalf("resp = %v, %v", resp, err)
	}
}
