package engagement

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// assertLikesListUnimplemented checks the post-gate answer: CodeUnimplemented naming the ticket that fills the RPC in.
func assertLikesListUnimplemented(t *testing.T, err error, ticket string) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeUnimplemented || !strings.Contains(err.Error(), ticket) {
		t.Fatalf("err = %v, want Unimplemented naming %s", err, ticket)
	}
}

func listLikedPosts(s *Server, ctx context.Context) error {
	_, err := s.ListLikedPosts(ctx, connect.NewRequest(&engagementv1.ListLikedPostsRequest{}))
	return err
}

// TestListLikedPosts_FlagMatrix (ADR-0024 D9): ListLikedPosts needs FEATURE_LIKES_LIST on for the caller and
// FEATURE_POSTS, and never FEATURE_ENGAGEMENT. A passed gate answers Unimplemented naming W3-10. Whatever the outcome,
// no Firestore read, write or delete is charged: the handler has no repo yet.
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
			err := listLikedPosts(NewServer(&stubSvc{}, flags.NewRegistry(tt.reg...)), ctx)
			if tt.pass {
				assertLikesListUnimplemented(t, err, "W3-10")
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
