package messaging

import (
	"context"
	"errors"
	"strings"
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// W7-34 L-2: the placeholder can never be a real account's uid (ADR-0008 A3), and nothing treats it as one.
func TestDeletedUID_IsNotAValidUID(t *testing.T) {
	t.Parallel()
	if ids.ValidUID(DeletedUID) {
		t.Fatalf("DeletedUID %q passes ids.ValidUID: an account could take the value", DeletedUID)
	}
	if !ids.ValidUID(legacyDeletedUID) {
		t.Fatalf("the legacy value %q was a valid uid shape; that is what L-2 fixes", legacyDeletedUID)
	}
	if legacyDeletedUID == DeletedUID {
		t.Fatal("the migration would be a no-op")
	}
}

// W7-34 L-7: redactErr never leaves the plain SHA-256 hash of a conversation id (guessable from a uid pair) in an error line.
func TestRedactErr_KeysConversationIDsAndHashesUIDs(t *testing.T) {
	t.Parallel()
	msgID := strings.Repeat("e", 32)
	err := redactErr(errors.New("rpc error: documents/conversations/"+aliceBobConv+"/messages/"+msgID+" for "+alice), alice, aliceBobConv, msgID)
	got := err.Error()
	for _, raw := range []string{alice, aliceBobConv, msgID} {
		if strings.Contains(got, raw) {
			t.Errorf("%q still holds %q", got, raw)
		}
	}
	for _, plain := range []string{logger.HashUID(aliceBobConv), logger.HashUID(msgID)} {
		if strings.Contains(got, plain) {
			t.Errorf("%q holds the plain hash %q of a conversation or message id", got, plain)
		}
	}
	if !strings.Contains(got, logger.HashConversation(aliceBobConv)) || !strings.Contains(got, logger.HashUID(alice)) {
		t.Errorf("%q lacks the keyed conversation hash or the uid hash", got)
	}
}

// W7-34 L-7: a ListMessages failure after the conversation loaded (peer profile, graph) names the peer in neither form.
func TestListMessages_ErrorRedactsThePeerUID(t *testing.T) {
	t.Parallel()
	rg := newRig(t, nil)
	rg.putThread(1, nil)
	rg.profs.err = errors.New("lookup projects/p/databases/(default)/documents/users/" + bob + " failed for " + aliceBobConv)
	_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if err == nil {
		t.Fatal("want an error")
	}
	got := logger.CauseChain(err)
	for _, bad := range []string{bob, alice, aliceBobConv, logger.HashUID(aliceBobConv)} {
		if strings.Contains(got, bad) {
			t.Errorf("error %q holds %q", got, bad)
		}
	}
	if !strings.Contains(got, logger.HashUID(bob)) || !strings.Contains(got, logger.HashConversation(aliceBobConv)) {
		t.Errorf("error %q should carry the peer's uid_hash and the keyed conversation hash", got)
	}
}
