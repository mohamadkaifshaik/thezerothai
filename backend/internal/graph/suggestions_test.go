package graph

import (
	"context"
	"errors"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func w3Ctx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

// w3Server builds a Server over a service with NO repo, cache or directory: any Firestore access (or any code past the
// flag gate that touches them) would panic, which proves the W3-4 gate reads nothing.
func w3Server(specs ...flags.Spec) *Server {
	return NewServer(New(Deps{Flags: flags.NewRegistry(specs...)}))
}

func featureDisabled(err error) *apierr.Error {
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Code == connect.CodeFailedPrecondition && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		return ae
	}
	return nil
}

func assertUnimplemented(t *testing.T, err error, ticket string) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeUnimplemented || !strings.Contains(err.Error(), ticket) {
		t.Fatalf("err = %v, want Unimplemented naming %s", err, ticket)
	}
}

// TestListSuggestedUsers_FlagMatrix (ADR-0024 D9): ListSuggestedUsers needs FEATURE_GRAPH and FEATURE_FOLLOW_SUGGESTIONS
// on for the caller. Passing both runs the RPC (it reads the caller graph); anything else is FEATURE_DISABLED with the
// right metadata and touches no storage. No outcome writes or deletes anything.
func TestListSuggestedUsers_FlagMatrix(t *testing.T) {
	const in, out = "in-cohort", "out-of-cohort"
	pct := flags.Spec{Name: FollowSuggestionsFlagName, Mode: flags.Percent, Percent: 50}
	var pIn, pOut string
	for i := 0; i < 1000 && (pIn == "" || pOut == ""); i++ {
		uid := "p" + string(rune('a'+i%26)) + string(rune('a'+(i/26)%26)) + string(rune('a'+(i/676)%26))
		if flags.NewRegistry(pct).Enabled(uid, FollowSuggestionsFlagName) {
			pIn = uid
		} else {
			pOut = uid
		}
	}
	if pIn == "" || pOut == "" {
		t.Fatal("could not find uids on both sides of the percent bucket")
	}
	graphOn := flags.Spec{Name: graphFlagName, Mode: flags.On}
	allow := map[string]struct{}{in: {}}
	sug := func(m flags.Mode) flags.Spec {
		return flags.Spec{Name: FollowSuggestionsFlagName, Mode: m, Allowlist: allow}
	}

	tests := []struct {
		name string
		reg  []flags.Spec
		uid  string
		// want is "" when the call must pass the gate, else the feature name in the FEATURE_DISABLED metadata ("-" = none).
		want string
	}{
		{"off", []flags.Spec{graphOn, sug(flags.Off)}, in, FollowSuggestionsFlagName},
		{"not registered", []flags.Spec{graphOn}, in, FollowSuggestionsFlagName},
		{"allowlist, caller in", []flags.Spec{graphOn, sug(flags.Allowlist)}, in, ""},
		{"allowlist, caller out", []flags.Spec{graphOn, sug(flags.Allowlist)}, out, FollowSuggestionsFlagName},
		{"allowlist empty", []flags.Spec{graphOn, {Name: FollowSuggestionsFlagName, Mode: flags.Allowlist}}, out, FollowSuggestionsFlagName},
		{"percent, caller in the bucket", []flags.Spec{graphOn, pct}, pIn, ""},
		{"percent, caller outside", []flags.Spec{graphOn, pct}, pOut, FollowSuggestionsFlagName},
		{"percent 0", []flags.Spec{graphOn, {Name: FollowSuggestionsFlagName, Mode: flags.Percent}}, out, FollowSuggestionsFlagName},
		{"on", []flags.Spec{graphOn, sug(flags.On)}, out, ""},
		{"retired (on forever)", []flags.Spec{graphOn, flags.NewRetired(FollowSuggestionsFlagName)}, out, ""},
		// FEATURE_GRAPH is checked first: the whole-service answer carries no feature metadata.
		{"graph off beats an on suggestions flag", []flags.Spec{{Name: graphFlagName, Mode: flags.Off}, sug(flags.On)}, in, "-"},
		{"graph not registered", []flags.Spec{sug(flags.On)}, in, "-"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx, counter := budget.WithCounter(w3Ctx(tt.uid))
			repo := newFakeRepo()
			_, err := w312Server(repo, tt.reg...).ListSuggestedUsers(ctx, connect.NewRequest(&graphv1.ListSuggestedUsersRequest{}))
			if (repo.calls > 0) != (tt.want == "") {
				t.Errorf("caller graph reads = %d with want %q: the gate must open storage exactly when it passes", repo.calls, tt.want)
			}
			if tt.want == "" {
				if err != nil {
					t.Fatalf("err = %v, want the gate passed", err)
				}
			} else {
				ae := featureDisabled(err)
				if ae == nil {
					t.Fatalf("err = %#v, want FAILED_PRECONDITION FEATURE_DISABLED", err)
				}
				wantFeature := tt.want
				if wantFeature == "-" {
					wantFeature = ""
				}
				if ae.Metadata["feature"] != wantFeature {
					t.Errorf("metadata feature = %q, want %q", ae.Metadata["feature"], wantFeature)
				}
			}
			budgettest.Assert(t, "ListSuggestedUsers", counter, budgettest.Budget{})
		})
	}
}

// TestW3Stubs_Unauthenticated: no caller identity is Unauthenticated before any flag check.
func TestW3Stubs_Unauthenticated(t *testing.T) {
	srv := w3Server(flags.Spec{Name: graphFlagName, Mode: flags.On}, flags.Spec{Name: FollowSuggestionsFlagName, Mode: flags.On})
	_, err := srv.ListSuggestedUsers(context.Background(), connect.NewRequest(&graphv1.ListSuggestedUsersRequest{}))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnauthenticated {
		t.Errorf("ListSuggestedUsers: err = %v, want Unauthenticated", err)
	}
	_, err = srv.GetProfileRelationship(context.Background(), connect.NewRequest(&graphv1.GetProfileRelationshipRequest{}))
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnauthenticated {
		t.Errorf("GetProfileRelationship: err = %v, want Unauthenticated", err)
	}
}

// TestFollowSuggestions_EnabledFeaturesOnlyForAllowlisted: GetMe.enabled_features (Registry.EnabledFeatures) lists
// "follow_suggestions" for allowlisted uids only, and never while the flag is off.
func TestFollowSuggestions_EnabledFeaturesOnlyForAllowlisted(t *testing.T) {
	allow := map[string]struct{}{"in": {}}
	reg := flags.NewRegistry(flags.Spec{Name: FollowSuggestionsFlagName, Mode: flags.Allowlist, Allowlist: allow})
	if got := reg.EnabledFeatures("in"); len(got) != 1 || got[0] != FollowSuggestionsFlagName {
		t.Errorf("EnabledFeatures(in) = %v, want [%s]", got, FollowSuggestionsFlagName)
	}
	if got := reg.EnabledFeatures("out"); len(got) != 0 {
		t.Errorf("EnabledFeatures(out) = %v, want none", got)
	}
	off := flags.NewRegistry(flags.Spec{Name: FollowSuggestionsFlagName, Mode: flags.Off, Allowlist: allow})
	if got := off.EnabledFeatures("in"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}
}
