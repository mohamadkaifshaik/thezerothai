package engagement

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// stubLikes is the LikesList behind the handler: it records every call and answers with a canned page or error.
type stubLikes struct {
	calls []string
	ctxs  []context.Context
	page  LikesPage
	err   error
}

func (s *stubLikes) ListLikedPosts(ctx context.Context, uid string, size int32, token string) (LikesPage, error) {
	s.calls = append(s.calls, fmt.Sprintf("%s:%d:%s", uid, size, token))
	s.ctxs = append(s.ctxs, ctx)
	return s.page, s.err
}

func listLikedPosts(s *Server, ctx context.Context) error {
	_, err := s.ListLikedPosts(ctx, connect.NewRequest(&engagementv1.ListLikedPostsRequest{}))
	return err
}

// TestListLikedPosts_FlagMatrix (ADR-0024 D9): ListLikedPosts needs FEATURE_LIKES_LIST on for the caller and
// FEATURE_POSTS, and never FEATURE_ENGAGEMENT. A passed gate reaches LikesList exactly once, a refused one never does.
// Whatever the outcome, this layer charges no Firestore read, write or delete.
func TestListLikedPosts_FlagMatrix(t *testing.T) {
	const in, out = "in-cohort", "out-of-cohort"
	pct := flags.Spec{Name: LikesListFlagName, Mode: flags.Percent, Percent: 50}
	var pIn, pOut string
	for i := 0; i < 1000 && (pIn == "" || pOut == ""); i++ {
		uid := "p" + string(rune('a'+i%26)) + string(rune('a'+(i/26)%26)) + string(rune('a'+(i/676)%26))
		if flags.NewRegistry(pct).Enabled(uid, LikesListFlagName) {
			pIn = uid
		} else {
			pOut = uid
		}
	}
	if pIn == "" || pOut == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	postsOn := flags.Spec{Name: "posts", Mode: flags.On}
	allow := map[string]struct{}{in: {}}

	tests := []struct {
		name string
		reg  []flags.Spec
		uid  string
		// pass: the call gets through the gate; feature: the metadata feature of a rejection ("" = the posts gate).
		pass    bool
		feature string
	}{
		{"off", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.Off}}, in, false, LikesListFlagName},
		{"not registered", []flags.Spec{postsOn}, in, false, LikesListFlagName},
		{"allowlist, caller in", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.Allowlist, Allowlist: allow}}, in, true, ""},
		{"allowlist, caller out", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.Allowlist, Allowlist: allow}}, out, false, LikesListFlagName},
		{"allowlist empty", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.Allowlist}}, out, false, LikesListFlagName},
		{"percent, caller in the bucket", []flags.Spec{postsOn, pct}, pIn, true, ""},
		{"percent, caller outside", []flags.Spec{postsOn, pct}, pOut, false, LikesListFlagName},
		{"percent 0", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.Percent}}, out, false, LikesListFlagName},
		{"on", []flags.Spec{postsOn, {Name: LikesListFlagName, Mode: flags.On}}, out, true, ""},
		{"retired (on forever)", []flags.Spec{postsOn, flags.NewRetired(LikesListFlagName)}, out, true, ""},
		// FEATURE_ENGAGEMENT is off here: the likes list must not depend on it.
		{"engagement off, likes_list on", []flags.Spec{postsOn, {Name: "engagement", Mode: flags.Off}, {Name: LikesListFlagName, Mode: flags.On}}, in, true, ""},
		{"posts off beats an on likes_list", []flags.Spec{{Name: "posts", Mode: flags.Off}, {Name: LikesListFlagName, Mode: flags.On}}, in, false, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, counter := budget.WithCounter(uidCtx(tt.uid))
			sl := &stubLikes{}
			err := listLikedPosts(NewServer(&stubSvc{}, flags.NewRegistry(tt.reg...), WithLikesList(sl)), ctx)
			if wantCalls := map[bool]int{true: 1, false: 0}[tt.pass]; len(sl.calls) != wantCalls {
				t.Errorf("LikesList calls = %v, want %d", sl.calls, wantCalls)
			}
			if tt.pass {
				if err != nil {
					t.Fatalf("err = %v, want the gate to pass", err)
				}
			} else {
				ae := featureDisabledErr(err)
				if ae == nil {
					t.Fatalf("err = %#v, want FAILED_PRECONDITION FEATURE_DISABLED", err)
				}
				if ae.Metadata["feature"] != tt.feature {
					t.Errorf("metadata feature = %q, want %q", ae.Metadata["feature"], tt.feature)
				}
			}
			budgettest.Assert(t, "ListLikedPosts", counter, budgettest.Budget{})
		})
	}
}

// TestListLikedPosts_UnauthenticatedAndNilFlags: no caller identity is Unauthenticated before any flag check, and a
// Server built without a flag checker is off for everyone.
func TestListLikedPosts_UnauthenticatedAndNilFlags(t *testing.T) {
	on := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: LikesListFlagName, Mode: flags.On})
	var ae *apierr.Error
	if err := listLikedPosts(NewServer(&stubSvc{}, on), context.Background()); !errors.As(err, &ae) || ae.Code != connect.CodeUnauthenticated {
		t.Errorf("err = %v, want Unauthenticated", err)
	}
	if err := listLikedPosts(NewServer(&stubSvc{}, nil), uidCtx("u")); featureDisabledErr(err) == nil {
		t.Errorf("nil flags: err = %v, want FEATURE_DISABLED", err)
	}
}

// TestLikesList_EnabledFeaturesOnlyForAllowlisted: GetMe.enabled_features (Registry.EnabledFeatures) lists "likes_list"
// for allowlisted uids only, and never while the flag is off.
func TestLikesList_EnabledFeaturesOnlyForAllowlisted(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: LikesListFlagName, Mode: flags.Allowlist, Allowlist: allow})
	if got := reg.EnabledFeatures("in"); !slices.Contains(got, LikesListFlagName) {
		t.Errorf("EnabledFeatures(in) = %v, want likes_list", got)
	}
	if got := reg.EnabledFeatures("out"); slices.Contains(got, LikesListFlagName) {
		t.Errorf("EnabledFeatures(out) = %v, want no likes_list", got)
	}
	off := flags.NewRegistry(flags.Spec{Name: LikesListFlagName, Mode: flags.Off, Allowlist: allow})
	if got := off.EnabledFeatures("in"); slices.Contains(got, LikesListFlagName) {
		t.Errorf("EnabledFeatures with the flag off = %v, want no likes_list", got)
	}
}

// Past the gate the handler forwards the request's page size and token with the TOKEN's uid (the request has no user id),
// under an RPC deadline, and renders each live post with posts.ToView and the page's viewer set.
func TestListLikedPosts_Handler(t *testing.T) {
	on := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: LikesListFlagName, Mode: flags.On})
	a := &posts.Post{ID: pid(9), AuthorID: "author", Text: "nine", Kind: posts.KindPost, Visibility: posts.VisibilityPublic}
	b := &posts.Post{ID: pid(8), AuthorID: "author", Text: "eight", Kind: posts.KindPost, Visibility: posts.VisibilityPublic}
	sl := &stubLikes{page: LikesPage{Posts: []*posts.Post{a, b}, Viewer: posts.NewViewerSet([]string{pid(9)}, nil), NextPageToken: "next-token"}}
	srv := NewServer(&stubSvc{}, on, WithLikesList(sl))

	resp, err := srv.ListLikedPosts(uidCtx("alice"), connect.NewRequest(&engagementv1.ListLikedPostsRequest{PageSize: 7, PageToken: "tok"}))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(sl.calls, []string{"alice:7:tok"}) {
		t.Errorf("service calls = %v, want one call with the token uid, size 7 and token tok", sl.calls)
	}
	if dl, ok := sl.ctxs[0].Deadline(); !ok || time.Until(dl) > rpcDeadline {
		t.Errorf("service ctx deadline = %v (%v), want one within %s", dl, ok, rpcDeadline)
	}
	got := resp.Msg.GetPosts()
	if len(got) != 2 || got[0].GetPost().GetPostId() != pid(9) || got[1].GetPost().GetPostId() != pid(8) || resp.Msg.GetNextPageToken() != "next-token" {
		t.Fatalf("response = %v, want [%s %s] and next-token", resp.Msg, pid(9), pid(8))
	}
	if !got[0].GetLikedByViewer() || got[1].GetLikedByViewer() {
		t.Errorf("liked_by_viewer = %v/%v, want true/false from the viewer set", got[0].GetLikedByViewer(), got[1].GetLikedByViewer())
	}

	// An empty page is an empty list and the empty token, not an error.
	sl.page = LikesPage{}
	resp, err = srv.ListLikedPosts(uidCtx("alice"), connect.NewRequest(&engagementv1.ListLikedPostsRequest{}))
	if err != nil || len(resp.Msg.GetPosts()) != 0 || resp.Msg.GetNextPageToken() != "" {
		t.Errorf("empty page: %v, %v", resp, err)
	}

	// A service error passes through untouched (the service already mapped it to a Connect code).
	want := apierr.Validation("page_token", "page_token is invalid or expired")
	sl.err = want
	if _, err = srv.ListLikedPosts(uidCtx("alice"), connect.NewRequest(&engagementv1.ListLikedPostsRequest{})); !errors.Is(err, want) {
		t.Errorf("err = %v, want the service error unchanged", err)
	}
}

// Without a LikesList the RPC is Unimplemented after the gate, never a nil dereference; NewServer picks the service up
// from svc when it implements LikesList (the Module does), so apiserver needs no extra wiring; WithLikesList overrides it.
func TestListLikedPosts_Wiring(t *testing.T) {
	on := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: LikesListFlagName, Mode: flags.On})
	err := listLikedPosts(NewServer(&stubSvc{}, on), uidCtx("u"))
	if connect.CodeOf(err) != connect.CodeUnimplemented || !strings.Contains(err.Error(), "not wired") {
		t.Errorf("err = %v, want Unimplemented \"not wired\"", err)
	}

	both := struct {
		Service
		LikesList
	}{&stubSvc{}, &stubLikes{}}
	if s := NewServer(both, on); s.likes == nil {
		t.Error("NewServer did not take the LikesList from svc")
	}
	override := &stubLikes{}
	if s := NewServer(both, on, WithLikesList(override)); s.likes != LikesList(override) {
		t.Error("WithLikesList did not override the default")
	}
	var _ LikesList = (*Module)(nil)
}
