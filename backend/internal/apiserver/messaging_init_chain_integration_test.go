//go:build integration

package apiserver

// mls_init over the real Build chain: the welcome-device check reads the key directory through the late-bound
// lateKeyDevices adapter (keys is built after messaging), so a registered device of the recipient is accepted and an
// unregistered id is VALIDATION welcome_device_ids; e2ee_dm off for the recipient is the CANNOT_MESSAGE of messaging.

import (
	"bytes"
	"context"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestMessagingChain_InitChecksTheKeyDirectory(t *testing.T) {
	ctx := context.Background()
	skipIfNoEmulators(t)
	mint := func() dmUser { tok, uid := mintToken(t, ""); return dmUser{tok, uid} }
	alice, bob, flagOff := mint(), mint(), mint()
	allow := map[string]struct{}{alice.uid: {}, bob.uid: {}}
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allow}
	})
	for _, u := range []dmUser{alice, bob, flagOff} {
		e.createProfile(t, u.token)
	}
	e.mutual(t, alice, bob)
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	const bobDevice = "init-chain-bob-device-01"
	if _, err := keysClient.RegisterKeyDevice(ctx, authed(bob.token, &keysv1.RegisterKeyDeviceRequest{
		IdempotencyKey: contractKey("init-reg"), DeviceId: bobDevice, SignaturePublicKey: bytes.Repeat([]byte{7}, 32),
	})); err != nil {
		t.Fatalf("RegisterKeyDevice: %v", err)
	}
	initTo := func(to, device string) *messagingv1.SendMessageRequest {
		return &messagingv1.SendMessageRequest{
			IdempotencyKey: contractKey("init-send"), Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: to},
			Ciphertext: []byte("ct"), ReportCommitment: bytes.Repeat([]byte{1}, 32), MlsGeneration: 1, MlsEpoch: 1,
			MlsInit: &messagingv1.MlsInit{Commit: []byte("commit"), Welcome: []byte("welcome"), WelcomeDeviceIds: []string{device}},
		}
	}

	_, err := e.msg.SendMessage(ctx, authed(alice.token, initTo(bob.uid, "init-chain-not-registered")))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "welcome_device_ids")

	_, err = e.msg.SendMessage(ctx, authed(alice.token, initTo(flagOff.uid, bobDevice)))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, "", "")

	_, err = e.msg.SendMessage(ctx, authed(flagOff.token, initTo(alice.uid, bobDevice)))
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")

	res, err := e.msg.SendMessage(ctx, authed(alice.token, initTo(bob.uid, bobDevice)))
	if err != nil {
		t.Fatalf("init to a registered device: %v", err)
	}
	if c := res.Msg.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 1 || c.GetMlsEpoch() != 1 {
		t.Fatalf("conversation = %v", c)
	}
}
