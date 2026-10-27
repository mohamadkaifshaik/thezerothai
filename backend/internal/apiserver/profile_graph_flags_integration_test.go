//go:build integration

package apiserver

// Wire contract of the ADR-0024 D9 flag gates (ticket W3-4) over the real Build chain on the emulators: GetMe.enabled_features
// lists profile_extras, profile_tabs, likes_list and follow_suggestions only for the allowlisted caller; with the flags off
// ListLikedPosts and ListSuggestedUsers answer FAILED_PRECONDITION + FEATURE_DISABLED (metadata feature=likes_list /
// follow_suggestions) and never write; GetProfileRelationship needs only FEATURE_GRAPH and passes the gate; in allowlist mode a
// caller outside the list is refused while the one inside gets through the gate: ListLikedPosts then answers an empty
// list (W3-10), the other two still reach their Unimplemented stubs (W3-11, W3-12). Helpers
// come from posts_restricted_test.go and posts_contract_test.go.

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

var w3FlagNames = []string{"profile_extras", "profile_tabs", "likes_list", "follow_suggestions"}

// w3RPCs calls the three gated RPCs and returns their errors by short name.
func w3RPCs(eng engagementv1connect.EngagementServiceClient, g graphv1connect.GraphServiceClient, token string) map[string]error {
	ctx := context.Background()
	out := map[string]error{}
	_, out["ListLikedPosts"] = eng.ListLikedPosts(ctx, authed(token, &engagementv1.ListLikedPostsRequest{}))
	_, out["ListSuggestedUsers"] = g.ListSuggestedUsers(ctx, authed(token, &graphv1.ListSuggestedUsersRequest{}))
	_, out["GetProfileRelationship"] = g.GetProfileRelationship(ctx, authed(token, &graphv1.GetProfileRelationshipRequest{UserId: "someone-else"}))
	return out
}

// w3FeatureOf is the feature a gated RPC names when its own flag is the one that rejected it.
var w3FeatureOf = map[string]string{"ListLikedPosts": "likes_list", "ListSuggestedUsers": "follow_suggestions"}

func w3AssertDisabled(t *testing.T, name string, err error) {
	t.Helper()
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if got := d.GetMetadata()["feature"]; got != w3FeatureOf[name] {
		t.Errorf("%s: metadata = %v, want feature=%s", name, d.GetMetadata(), w3FeatureOf[name])
	}
}

func w3AssertUnimplemented(t *testing.T, who, name string, err error) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeUnimplemented || !strings.Contains(err.Error(), "W3-") {
		t.Errorf("%s %s: err = %v, want Unimplemented naming its W3 ticket (gate open)", who, name, err)
	}
}

// w3NoWrites asserts the request lines of rpc logged no write or delete and at most the interceptor's one read.
func w3NoWrites(t *testing.T, env *chainEnv, rpc string) {
	t.Helper()
	lines := env.logs.requestLines(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	for _, l := range lines {
		num := func(k string) float64 { v, _ := l[k].(float64); return v }
		if num("fs_reads") > 1 || num("fs_writes") != 0 || num("fs_deletes") != 0 {
			t.Errorf("%s logged reads=%v writes=%v deletes=%v, want <= 1 read (the account-status interceptor) and no writes", rpc, num("fs_reads"), num("fs_writes"), num("fs_deletes"))
		}
	}
}

// w3StartupFlags returns the flags map of the startup `feature_flags` log line (ADR-0008 D6; W3-4 observability).
func w3StartupFlags(t *testing.T, env *chainEnv) map[string]any {
	t.Helper()
	env.logs.mu.Lock()
	defer env.logs.mu.Unlock()
	for _, line := range strings.Split(env.logs.buf.String(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil && rec["msg"] == "feature_flags" {
			flagsMap, _ := rec["flags"].(map[string]any)
			return flagsMap
		}
	}
	t.Fatal("no feature_flags startup line")
	return nil
}

func TestProfileGraphContract_FlagOff(t *testing.T) {
	token, _ := mintToken(t, "")
	env := newChain(t, func(c *config.Config) { c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On} })
	startup := w3StartupFlags(t, env)
	for _, n := range w3FlagNames {
		if got, ok := startup[n]; !ok || got != "off" {
			t.Errorf("startup feature_flags line = %v, want %s listed as off", startup, n)
		}
	}

	env.createProfile(t, token)

	me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	for _, n := range w3FlagNames {
		if slices.Contains(me.Msg.GetEnabledFeatures(), n) {
			t.Errorf("enabled_features = %v lists %s with the flag off", me.Msg.GetEnabledFeatures(), n)
		}
	}
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url)
	g := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url)
	for name, err := range w3RPCs(eng, g, token) {
		if name == "GetProfileRelationship" {
			// FEATURE_GRAPH only: with the W3 flags off it still passes the gate.
			w3AssertUnimplemented(t, "flags off:", name, err)
			continue
		}
		w3AssertDisabled(t, name, err)
	}
	w3NoWrites(t, env, engagementv1connect.EngagementServiceListLikedPostsProcedure)
	w3NoWrites(t, env, graphv1connect.GraphServiceListSuggestedUsersProcedure)
	w3NoWrites(t, env, graphv1connect.GraphServiceGetProfileRelationshipProcedure)
}

func TestProfileGraphContract_AllowlistCohort(t *testing.T) {
	insideToken, insideUID := mintToken(t, "")
	outsideToken, _ := mintToken(t, "")
	env := newChain(t, func(cfg *config.Config) {
		cfg.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		in := map[string]struct{}{insideUID: {}}
		cfg.FeatureProfileExtras = flags.Spec{Name: "profile_extras", Mode: flags.Allowlist, Allowlist: in}
		cfg.FeatureProfileTabs = flags.Spec{Name: "profile_tabs", Mode: flags.Allowlist, Allowlist: in}
		cfg.FeatureLikesList = flags.Spec{Name: "likes_list", Mode: flags.Allowlist, Allowlist: in}
		cfg.FeatureFollowSuggestions = flags.Spec{Name: "follow_suggestions", Mode: flags.Allowlist, Allowlist: in}
	})
	env.createProfile(t, insideToken)
	env.createProfile(t, outsideToken)

	for token, listed := range map[string]bool{insideToken: true, outsideToken: false} {
		me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		for _, n := range w3FlagNames {
			if got := slices.Contains(me.Msg.GetEnabledFeatures(), n); got != listed {
				t.Errorf("enabled_features = %v, %s listed = %v, want %v", me.Msg.GetEnabledFeatures(), n, got, listed)
			}
		}
	}

	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url)
	g := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url)
	// Inside: every RPC passes the gate. ListLikedPosts (W3-10) answers an empty list for a caller with no likes; the
	// others are Unimplemented until W3-11 / W3-12.
	for name, err := range w3RPCs(eng, g, insideToken) {
		if name == "ListLikedPosts" {
			if err != nil {
				t.Errorf("inside ListLikedPosts: err = %v, want an empty list past the gate", err)
			}
			continue
		}
		w3AssertUnimplemented(t, "inside", name, err)
	}
	// Outside: the two flag-gated RPCs are refused; GetProfileRelationship only needs graph, which is on for everyone.
	for name, err := range w3RPCs(eng, g, outsideToken) {
		if name == "GetProfileRelationship" {
			w3AssertUnimplemented(t, "outside", name, err)
			continue
		}
		w3AssertDisabled(t, name, err)
	}
}
