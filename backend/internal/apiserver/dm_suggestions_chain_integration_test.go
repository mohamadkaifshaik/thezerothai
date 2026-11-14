//go:build integration

package apiserver

// ListMessageSuggestions (F30) over the real Build chain: the flag gates, and the block and DM-policy exclusions decided by the
// real graph (snapshot and follow edges) and identity Directory.

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func (e *dmChain) suggestions(t *testing.T, who dmUser) []*messagingv1.MessageSuggestion {
	t.Helper()
	r, err := e.msg.ListMessageSuggestions(context.Background(), authed(who.token, &messagingv1.ListMessageSuggestionsRequest{Limit: 20}))
	if err != nil {
		t.Fatalf("ListMessageSuggestions: %v", err)
	}
	return r.Msg.GetSuggestions()
}

func TestDMSuggestionsChain_FlagOff(t *testing.T) {
	e := newDMChain(t, nil) // FEATURE_DM_SUGGESTIONS unset: off
	u := e.user(t)
	_, err := e.msg.ListMessageSuggestions(context.Background(), authed(u.token, &messagingv1.ListMessageSuggestionsRequest{}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "dm_suggestions" {
		t.Fatalf("metadata = %v", d.GetMetadata())
	}
}

// TestDMSuggestionsChain_BlockAndPolicyMatrix: a recent conversation and a mutual follow are suggested; a peer the caller blocked,
// a peer who blocked the caller, and a mutual-pool followee whose FOLLOWING_ONLY policy (with dm_policy on) refuses a new message
// are not; once that followee follows back they are.
func TestDMSuggestionsChain_BlockAndPolicyMatrix(t *testing.T) {
	ctx := context.Background()
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureDMSuggestions = flags.Spec{Name: "dm_suggestions", Mode: flags.On}
		c.FeatureDMPolicy = flags.Spec{Name: "dm_policy", Mode: flags.On}
	})
	me, chat, mutual, blockedPeer, blocker, strict := e.user(t), e.user(t), e.user(t), e.user(t), e.user(t), e.user(t)
	e.mutual(t, me, chat)
	e.mustSend(t, me, chat, "hi")
	e.mutual(t, me, blockedPeer)
	e.mustSend(t, me, blockedPeer, "hi")
	e.mutual(t, me, blocker)
	e.mustSend(t, me, blocker, "hi")
	e.mutual(t, me, mutual)
	pol := identityv1.DmPolicy_DM_POLICY_FOLLOWING_ONLY
	if _, err := e.identity.UpdateProfile(ctx, authed(strict.token, &identityv1.UpdateProfileRequest{IdempotencyKey: contractKey("sg-pol"), DmPolicy: &pol})); err != nil {
		t.Fatal(err)
	}
	e.follow(t, me, strict) // me follows strict; strict does not follow me: not mutual, and the policy refuses
	if _, err := e.graph.Block(ctx, authed(me.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("sg-blk"), UserId: blockedPeer.uid})); err != nil {
		t.Fatal(err)
	}
	if _, err := e.graph.Block(ctx, authed(blocker.token, &graphv1.BlockRequest{IdempotencyKey: contractKey("sg-blk"), UserId: me.uid})); err != nil {
		t.Fatal(err)
	}

	got := map[string]messagingv1.MessageSuggestionReason{}
	for _, s := range e.suggestions(t, me) {
		got[s.GetUser().GetUserId()] = s.GetReason()
	}
	if got[chat.uid] != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_RECENT_CONVERSATION {
		t.Errorf("chat peer: %v (all %v)", got[chat.uid], got)
	}
	if got[mutual.uid] != messagingv1.MessageSuggestionReason_MESSAGE_SUGGESTION_REASON_MUTUAL_FOLLOW {
		t.Errorf("mutual: %v (all %v)", got[mutual.uid], got)
	}
	for name, uid := range map[string]string{"blocked": blockedPeer.uid, "blocker": blocker.uid, "strict": strict.uid} {
		if _, ok := got[uid]; ok {
			t.Errorf("%s was suggested (all %v)", name, got)
		}
	}
	// strict follows back: now a mutual follow, and the FOLLOWING_ONLY policy lets the caller through (the Follow drops the edge
	// cache entry on this instance, so the batched lookup reads the new edge).
	e.follow(t, strict, me)
	found := false
	for _, s := range e.suggestions(t, me) {
		found = found || s.GetUser().GetUserId() == strict.uid
	}
	if !found {
		t.Error("strict is not suggested after following back")
	}
}
