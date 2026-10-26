package engagement

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func uidCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

// bookmarkCall invokes one of the three handlers with an empty request.
type bookmarkCall struct {
	name string
	// perCaller is true for the RPC that needs the flag on for the caller (AddBookmark).
	perCaller bool
	// ticket is the ticket the Unimplemented answer names.
	ticket string
	call   func(*Server, context.Context) error
}

func bookmarkCalls() []bookmarkCall {
	return []bookmarkCall{
		{"AddBookmark", true, "W2-3", func(s *Server, ctx context.Context) error {
			_, err := s.AddBookmark(ctx, connect.NewRequest(&engagementv1.AddBookmarkRequest{}))
			return err
		}},
		{"RemoveBookmark", false, "W2-3", func(s *Server, ctx context.Context) error {
			_, err := s.RemoveBookmark(ctx, connect.NewRequest(&engagementv1.RemoveBookmarkRequest{}))
			return err
		}},
		{"ListBookmarks", false, "W2-4", func(s *Server, ctx context.Context) error {
			_, err := s.ListBookmarks(ctx, connect.NewRequest(&engagementv1.ListBookmarksRequest{}))
			return err
		}},
	}
}

// featureDisabledErr returns the FEATURE_DISABLED apierr in err, or nil when err is anything else.
func featureDisabledErr(err error) *apierr.Error {
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Code == connect.CodeFailedPrecondition && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		return ae
	}
	return nil
}

// assertUnimplemented checks the post-gate answer: CodeUnimplemented naming the ticket that fills the RPC in.
func assertUnimplemented(t *testing.T, err error, ticket string) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeUnimplemented || !strings.Contains(err.Error(), ticket) {
		t.Fatalf("err = %v, want Unimplemented naming %s", err, ticket)
	}
}

// TestBookmarkServer_FlagMatrix (ADR-0023 D5): AddBookmark needs FEATURE_BOOKMARKS on for the caller; ListBookmarks
// and RemoveBookmark only need it not globally off. FEATURE_POSTS is needed by all three and FEATURE_ENGAGEMENT by
// none. Whatever the outcome, no Firestore read, write or delete is charged: the handlers have no repo yet.
func TestBookmarkServer_FlagMatrix(t *testing.T) {
	const in, out = "in-cohort", "out-of-cohort"
	// Uids on both sides of a 50% bucket, found by probing the real registry.
	pct := flags.Spec{Name: "bookmarks", Mode: flags.Percent, Percent: 50}
	var pIn, pOut string
	for i := 0; i < 1000 && (pIn == "" || pOut == ""); i++ {
		uid := "p" + string(rune('a'+i%26)) + string(rune('a'+(i/26)%26)) + string(rune('a'+(i/676)%26))
		if flags.NewRegistry(pct).Enabled(uid, "bookmarks") {
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
		// wantAdd: AddBookmark passes the gate; wantOthers: ListBookmarks and RemoveBookmark do.
		wantAdd, wantOthers bool
	}{
		{"off", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.Off}}, in, false, false},
		{"not registered", []flags.Spec{postsOn}, in, false, false},
		{"allowlist, caller in", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.Allowlist, Allowlist: allow}}, in, true, true},
		{"allowlist, caller out", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.Allowlist, Allowlist: allow}}, out, false, true},
		{"allowlist empty", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.Allowlist}}, out, false, true},
		{"percent, caller in the bucket", []flags.Spec{postsOn, pct}, pIn, true, true},
		{"percent, caller outside", []flags.Spec{postsOn, pct}, pOut, false, true},
		{"percent 0 is a rollout, not the kill switch", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.Percent}}, out, false, true},
		{"on", []flags.Spec{postsOn, {Name: "bookmarks", Mode: flags.On}}, out, true, true},
		{"retired (on forever)", []flags.Spec{postsOn, flags.NewRetired("bookmarks")}, out, true, true},
		// FEATURE_ENGAGEMENT is not registered in the cases above and off here: bookmarks must not depend on it.
		{"engagement off, bookmarks on", []flags.Spec{postsOn, {Name: "engagement", Mode: flags.Off}, {Name: "bookmarks", Mode: flags.On}}, in, true, true},
		{"posts off beats an on bookmarks", []flags.Spec{{Name: "posts", Mode: flags.Off}, {Name: "bookmarks", Mode: flags.On}}, in, false, false},
	}
	for _, tt := range tests {
		for _, c := range bookmarkCalls() {
			want := tt.wantOthers
			if c.perCaller {
				want = tt.wantAdd
			}
			t.Run(tt.name+"/"+c.name, func(t *testing.T) {
				ctx, counter := budget.WithCounter(uidCtx(tt.uid))
				err := c.call(NewServer(&stubSvc{}, flags.NewRegistry(tt.reg...)), ctx)
				if want {
					assertUnimplemented(t, err, c.ticket)
				} else if featureDisabledErr(err) == nil {
					t.Fatalf("err = %#v, want FAILED_PRECONDITION FEATURE_DISABLED", err)
				}
				budgettest.Assert(t, c.name, counter, budgettest.Budget{})
			})
		}
	}
}

// TestBookmarkServer_DisabledShape: the bookmarks gate (not the posts gate) names the feature in the metadata.
func TestBookmarkServer_DisabledShape(t *testing.T) {
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "bookmarks", Mode: flags.Off})
	postsOff := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.Off}, flags.Spec{Name: "bookmarks", Mode: flags.On})
	for _, c := range bookmarkCalls() {
		ae := featureDisabledErr(c.call(NewServer(&stubSvc{}, reg), uidCtx("u")))
		if ae == nil || ae.Metadata["feature"] != "bookmarks" {
			t.Errorf("%s: bookmarks gate error = %#v, want FEATURE_DISABLED with feature=bookmarks", c.name, ae)
		}
		// FEATURE_POSTS off: the same code and reason, but not naming bookmarks.
		ae = featureDisabledErr(c.call(NewServer(&stubSvc{}, postsOff), uidCtx("u")))
		if ae == nil || ae.Metadata["feature"] != "" {
			t.Errorf("%s: posts gate error = %#v, want FEATURE_DISABLED without a feature", c.name, ae)
		}
	}
}

// TestBookmarkServer_UnauthenticatedAndNilFlags: no caller identity is Unauthenticated before any flag check, and a
// Server built without a flag checker is off for everyone.
func TestBookmarkServer_UnauthenticatedAndNilFlags(t *testing.T) {
	on := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "bookmarks", Mode: flags.On})
	for _, c := range bookmarkCalls() {
		var ae *apierr.Error
		if err := c.call(NewServer(&stubSvc{}, on), context.Background()); !errors.As(err, &ae) || ae.Code != connect.CodeUnauthenticated {
			t.Errorf("%s: err = %v, want Unauthenticated", c.name, err)
		}
		if err := c.call(NewServer(&stubSvc{}, nil), uidCtx("u")); featureDisabledErr(err) == nil {
			t.Errorf("%s with nil flags: err = %v, want FEATURE_DISABLED", c.name, err)
		}
	}
}

// kindOnlyFlags is a FlagChecker without GloballyOff: the Server falls back to the per-caller answer for all three.
type kindOnlyFlags struct{ on map[string]map[string]bool } // name -> uid -> on

func (k kindOnlyFlags) Enabled(uid, name string) bool { return k.on[name][uid] }

func TestBookmarkServer_CheckerWithoutGloballyOff(t *testing.T) {
	fl := kindOnlyFlags{on: map[string]map[string]bool{"posts": {"in": true, "out": true}, "bookmarks": {"in": true}}}
	for _, c := range bookmarkCalls() {
		for uid, want := range map[string]bool{"in": true, "out": false} {
			err := c.call(NewServer(&stubSvc{}, fl), uidCtx(uid))
			if got := connect.CodeOf(err) == connect.CodeUnimplemented; got != want {
				t.Errorf("%s as %s: passed the gate = %v (err %v), want %v", c.name, uid, got, err, want)
			}
		}
	}
}

// TestBookmarks_EnabledFeaturesOnlyForAllowlisted: GetMe.enabled_features (Registry.EnabledFeatures) lists
// "bookmarks" for allowlisted uids only, and never while the flag is off.
func TestBookmarks_EnabledFeaturesOnlyForAllowlisted(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: BookmarksFlagName, Mode: flags.Allowlist, Allowlist: allow})
	if got := reg.EnabledFeatures("in"); !slices.Contains(got, "bookmarks") {
		t.Errorf("EnabledFeatures(in) = %v, want bookmarks", got)
	}
	if got := reg.EnabledFeatures("out"); slices.Contains(got, "bookmarks") {
		t.Errorf("EnabledFeatures(out) = %v, want no bookmarks", got)
	}
	off := flags.NewRegistry(flags.Spec{Name: BookmarksFlagName, Mode: flags.Off, Allowlist: allow})
	if got := off.EnabledFeatures("in"); slices.Contains(got, "bookmarks") {
		t.Errorf("EnabledFeatures with the flag off = %v, want no bookmarks", got)
	}
}
