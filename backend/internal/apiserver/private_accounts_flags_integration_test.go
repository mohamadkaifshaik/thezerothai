//go:build integration

package apiserver

// Wire contract of the ADR-0025 D12 flag gate (ticket W3-25b) over the real Build chain on the emulators:
// FEATURE_PRIVATE_ACCOUNTS (private_accounts) is listed in startup feature_flags and in GetMe.enabled_features only for
// the allowlisted caller; UpdateProfile(is_private=true) is FEATURE_DISABLED feature=private_accounts with 0 reads past the
// interceptor and 0 writes for everyone else; is_private=false is accepted whatever the flag; ListFollowRequests and
// RespondToFollowRequest are FEATURE_DISABLED for a public caller while the flag is globally off and past the
// gate otherwise they run (W3-28a: an empty page, and INVALID_ARGUMENT for an empty respond request). The toggle itself (W3-26a) is in privacy_toggle_integration_test.go.

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const privateAccountsFeature = "private_accounts"

func paAssertDisabled(t *testing.T, what string, err error) {
	t.Helper()
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if got := d.GetMetadata()["feature"]; got != privateAccountsFeature {
		t.Errorf("%s: metadata = %v, want feature=%s", what, d.GetMetadata(), privateAccountsFeature)
	}
}

func TestPrivateAccountsContract_FlagOff(t *testing.T) {
	token, _ := mintToken(t, "")
	env := newChain(t, func(c *config.Config) { c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On} })
	if got := w3StartupFlags(t, env)[privateAccountsFeature]; got != "off" {
		t.Errorf("startup feature_flags lists %s as %v, want off", privateAccountsFeature, got)
	}
	env.createProfile(t, token)

	me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if slices.Contains(me.Msg.GetEnabledFeatures(), privateAccountsFeature) {
		t.Errorf("enabled_features = %v lists %s with the flag off", me.Msg.GetEnabledFeatures(), privateAccountsFeature)
	}

	yes, no := true, false
	_, err = env.identity.UpdateProfile(context.Background(), authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: "pa-off-key-00000001", IsPrivate: &yes}))
	paAssertDisabled(t, "UpdateProfile(is_private=true)", err)
	w3NoWrites(t, env, "/dzeroth.identity.v1.IdentityService/UpdateProfile") // 0 reads past the interceptor's 1, 0 writes

	// The undo rule: is_private=false is accepted whatever the flag.
	if _, err := env.identity.UpdateProfile(context.Background(), authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: "pa-off-key-00000002", IsPrivate: &no})); err != nil {
		t.Errorf("UpdateProfile(is_private=false) with the flag off: %v, want accepted", err)
	}

	g := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url)
	_, err = g.ListFollowRequests(context.Background(), authed(token, &graphv1.ListFollowRequestsRequest{}))
	paAssertDisabled(t, "ListFollowRequests", err)
	_, err = g.RespondToFollowRequest(context.Background(), authed(token, &graphv1.RespondToFollowRequestRequest{}))
	paAssertDisabled(t, "RespondToFollowRequest", err)
	w3NoWrites(t, env, graphv1connect.GraphServiceListFollowRequestsProcedure)
	w3NoWrites(t, env, graphv1connect.GraphServiceRespondToFollowRequestProcedure)
}

func TestPrivateAccountsContract_AllowlistCohort(t *testing.T) {
	insideToken, insideUID := mintToken(t, "")
	outsideToken, _ := mintToken(t, "")
	env := newChain(t, func(cfg *config.Config) {
		cfg.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		cfg.FeaturePrivateAccounts = flags.Spec{Name: privateAccountsFeature, Mode: flags.Allowlist, Allowlist: map[string]struct{}{insideUID: {}}}
	})
	if got := w3StartupFlags(t, env)[privateAccountsFeature]; got != "allowlist" {
		t.Errorf("startup feature_flags lists %s as %v, want allowlist", privateAccountsFeature, got)
	}
	env.createProfile(t, insideToken)
	env.createProfile(t, outsideToken)

	for token, listed := range map[string]bool{insideToken: true, outsideToken: false} {
		me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if got := slices.Contains(me.Msg.GetEnabledFeatures(), privateAccountsFeature); got != listed {
			t.Errorf("enabled_features = %v, %s listed = %v, want %v", me.Msg.GetEnabledFeatures(), privateAccountsFeature, got, listed)
		}
	}

	yes := true
	// Outside: refused before any read; a mixed request is refused whole.
	name := "Renamed"
	_, err := env.identity.UpdateProfile(context.Background(), authed(outsideToken, &identityv1.UpdateProfileRequest{IdempotencyKey: "pa-out-key-00000001", IsPrivate: &yes, DisplayName: &name}))
	paAssertDisabled(t, "outside UpdateProfile(is_private=true)", err)
	// Inside: past the gate the toggle commits (W3-26a; its budget is TestPrivacyToggle_Chain). Undo it so the shared emulator
	// set does not keep this uid.
	if _, err = env.identity.UpdateProfile(context.Background(), authed(insideToken, &identityv1.UpdateProfileRequest{IdempotencyKey: "pa-in-key-000000001", IsPrivate: &yes})); err != nil {
		t.Fatalf("inside UpdateProfile(is_private=true): %v", err)
	}
	no := false
	if _, err = env.identity.UpdateProfile(context.Background(), authed(insideToken, &identityv1.UpdateProfileRequest{IdempotencyKey: "pa-in-key-000000002", IsPrivate: &no})); err != nil {
		t.Fatalf("inside UpdateProfile(is_private=false): %v", err)
	}

	g := graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url)
	// Allowlist is a rollout, not the kill switch: both callers pass the gate and reach the handlers.
	for who, token := range map[string]string{"inside": insideToken, "outside": outsideToken} {
		if _, err := g.ListFollowRequests(context.Background(), authed(token, &graphv1.ListFollowRequestsRequest{})); err != nil {
			t.Errorf("%s ListFollowRequests: err = %v, want an empty page past the gate", who, err)
		}
		_, err := g.RespondToFollowRequest(context.Background(), authed(token, &graphv1.RespondToFollowRequestRequest{}))
		if connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Errorf("%s RespondToFollowRequest: err = %v, want INVALID_ARGUMENT (past the gate, empty idempotency key)", who, err)
		}
	}
}
