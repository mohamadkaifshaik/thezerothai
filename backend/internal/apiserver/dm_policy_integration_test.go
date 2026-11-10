//go:build integration

package apiserver

// F9 over the real Build chain: UpdateProfile.dm_policy is gated by FEATURE_DM_POLICY, another user's GetProfile shows
// it (the recipient picker greys the account out), and SendMessage answers the one CANNOT_MESSAGE through the real identity Directory.

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestDMPolicy_FlagOffRefusesFollowingOnly(t *testing.T) {
	ctx := context.Background()
	e := newChain(t, nil)
	token, _ := mintToken(t, "")
	e.createProfile(t, token)
	pol := identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY
	_, err := e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("dm1"), DmPolicy: &pol}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "dm_policy" {
		t.Errorf("metadata = %v, want feature=dm_policy", d.GetMetadata())
	}
	// The undo is never gated.
	undo := identityv1.DmPolicy_DM_POLICY_EVERYONE_REQUESTS
	if _, err := e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("dm2"), DmPolicy: &undo})); err != nil {
		t.Errorf("EVERYONE_REQUESTS with the flag off: %v", err)
	}
	// UNSPECIFIED is not a valid request.
	unspec := identityv1.DmPolicy_DM_POLICY_UNSPECIFIED
	_, err = e.identity.UpdateProfile(ctx, authed(token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("dm3"), DmPolicy: &unspec}))
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
}

func TestDMPolicy_OnShowsToOthersAndRoundTrips(t *testing.T) {
	ctx := context.Background()
	e := newChain(t, func(c *config.Config) {
		c.FeatureDMPolicy = flags.Spec{Name: "dm_policy", Mode: flags.On}
	})
	mine, myUID := mintToken(t, "")
	e.createProfile(t, mine)
	other, _ := mintToken(t, "")
	e.createProfile(t, other)

	pol := identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY
	up, err := e.identity.UpdateProfile(ctx, authed(mine, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("dm4"), DmPolicy: &pol}))
	if err != nil || up.Msg.GetProfile().GetDmPolicy() != pol {
		t.Fatalf("UpdateProfile = %v, %v", up, err)
	}
	// Another user's view of the profile carries it.
	got, err := e.identity.GetProfile(ctx, authed(other, &identityv1.GetProfileRequest{Target: &identityv1.GetProfileRequest_UserId{UserId: myUID}}))
	if err != nil || got.Msg.GetProfile().GetDmPolicy() != pol {
		t.Fatalf("GetProfile = %v, %v", got, err)
	}
	me, err := e.identity.GetMe(ctx, authed(mine, &identityv1.GetMeRequest{}))
	if err != nil || me.Msg.GetProfile().GetDmPolicy() != pol {
		t.Fatalf("GetMe = %v, %v", me, err)
	}
	found := false
	for _, f := range me.Msg.GetEnabledFeatures() {
		found = found || f == "dm_policy"
	}
	if !found {
		t.Errorf("enabled_features = %v, want dm_policy", me.Msg.GetEnabledFeatures())
	}
}

// TestDMPolicy_SendMessageThroughTheRealDirectory: the policy bob saved with UpdateProfile reaches SendMessage through the real
// identity Directory (no fake profile), and the follow edge decides: refused as strangers and when alice follows bob, sent
// once bob follows alice, and an accepted conversation keeps working after bob restricts DMs.
func TestDMPolicy_SendMessageThroughTheRealDirectory(t *testing.T) {
	ctx := context.Background()
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureDMPolicy = flags.Spec{Name: "dm_policy", Mode: flags.On}
	})
	alice, bob, carol := e.user(t), e.user(t), e.user(t)
	pol := identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY
	if _, err := e.identity.UpdateProfile(ctx, authed(bob.token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("dmp-set"), DmPolicy: &pol})); err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}

	_, err := e.send(alice, bob, contractKey("dmp1"), "hello?")
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	if _, found := e.convDoc(t, alice, bob); found {
		t.Error("a refused send created a conversation")
	}
	e.follow(t, alice, bob) // alice following bob does not help: the policy asks whom bob follows
	_, err = e.send(alice, bob, contractKey("dmp2"), "still me")
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)

	e.follow(t, bob, alice)
	if _, err := e.send(alice, bob, contractKey("dmp3"), "now"); err != nil {
		t.Fatalf("send after bob follows alice: %v", err)
	}
	// Carol is a stranger to bob: still refused, and a block would look the same on the wire.
	_, policyErr := e.send(carol, bob, contractKey("dmp4"), "hi")
	assertReason(t, wireError(t, policyErr, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
}
