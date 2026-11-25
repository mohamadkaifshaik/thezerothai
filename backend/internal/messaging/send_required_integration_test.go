//go:build integration

package messaging

// FEATURE_E2EE_REQUIRED (E2EE Plan 6 Task 1.A) on the emulator: the send transaction refuses every plaintext send while
// the policy applies to the sender or the recipient, into a NONE conversation and for a first message, writing nothing;
// a plaintext retry of a message stored before the flag applied still replays; ciphertext into an MLS conversation still
// passes. The registry is coupled as the composition root couples it (e2ee_dm needs messaging, e2ee_required needs the
// effective e2ee_dm).

import (
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// requireFor switches the env's registry to e2ee_required for the given uids (allowlist; none = off) and rebuilds the
// service over the same storage.
func (e *itEnv) requireFor(uids ...string) {
	e.t.Helper()
	req := flags.Spec{Name: E2EERequiredFlag, Mode: flags.Allowlist, Allowlist: map[string]struct{}{}}
	for _, u := range uids {
		req.Allowlist[u] = struct{}{}
	}
	e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: keys.FlagName, Mode: flags.On}, req).
		Require(keys.FlagName, FlagName).Require(E2EERequiredFlag, FlagName)
	e.svc = e.newService()
}

// The order of answers for a plaintext first message under the policy (code review m1): the policy answers before the
// new conversation's dm_new_daily quota and before its in-transaction recipient status re-read, so the caller gets
// ENCRYPTION_REQUIRED, not LIMIT_REACHED or CANNOT_MESSAGE, and nothing is written or reserved. Each case first proves,
// with the policy off, that its setup really refuses with the other answer.
func TestSendRequired_AnswersBeforeQuotaAndRecipientReread(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, tc := range []struct {
		name    string
		setup   func(e *itEnv)
		without commonv1.ErrorReason // the answer with the policy off
		quota   int64                // alice's dm_new_daily after both attempts
	}{
		{"dm_new_daily at the limit", func(e *itEnv) {
			// alice opens one conversation (with carol) under a limit of 1: the quota is now at the limit.
			e.limits.DMNewPerDay = 1
			e.svc = e.newService()
			e.addUser(carolUID, "carol", false)
			e.must(alice, toUser(skey(50), carolUID, "the one of today"))
			e.tick(time.Second)
		}, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, 1},
		{"recipient suspended since the directory read", func(e *itEnv) {
			// The directory (cached) still says ACTIVE; the users document the transaction re-reads says SUSPENDED.
			e.writeUserDoc(bob, "bob", time.Now().Add(-30*24*time.Hour), "SUSPENDED")
		}, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.mutual(alice, bob)
			tc.setup(e)

			e.requireFor()
			_, err := e.send(alice, toUser(skey(1), bob, "hello"))
			wantAPI(t, err, connect.CodeFailedPrecondition, tc.without, nil)

			e.requireFor(bob)
			_, err = e.send(alice, toUser(skey(2), bob, "hello"))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID})

			if _, ok := e.conv(convID); ok {
				t.Error("a refused first message created the conversation")
			}
			for _, uid := range []string{alice, bob} {
				for _, folder := range []string{dmInboxCollection, dmRequestsCollection} {
					if _, ok := e.entry(uid, folder, convID); ok {
						t.Errorf("a refused first message wrote %s/%s", uid, folder)
					}
				}
			}
			if n := e.dmNew(alice); n != tc.quota {
				t.Errorf("dm_new_daily = %d, want %d (nothing reserved)", n, tc.quota)
			}
		})
	}
}

// Plaintext into a NONE conversation is refused when the policy applies to the sender, and when it applies to the
// recipient only; neither writes the conversation, an entry, a message or an unread count, nor pushes. Addressed by
// recipient the answer names the conversation.
func TestSendRequired_PlaintextIntoNoneRefusedForSenderOrRecipient(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	first := e.must(alice, toUser(skey(1), bob, "before the policy"))
	convID := first.GetConversation().GetId()
	e.tick(time.Second)

	e.requireFor(alice)
	before := e.snapshotState(convID)
	events := len(e.events.got)

	// The policy applies to alice: she is refused as the sender...
	_, err := e.send(alice, toUser(skey(2), bob, "from the required sender"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID})
	// ...and bob, outside the cohort, is refused as her sender: the recipient is in it.
	_, err = e.send(bob, toConv(skey(3), convID, "to the required recipient"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, nil)
	if _, _, meta := reasonOf(t, err); meta["conversation_id"] != "" {
		t.Error("a send by conversation id got metadata conversation_id")
	}

	before.check(t)
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 1 {
		t.Errorf("bob unread = %d, want 1 (unchanged)", ent.UnreadCount)
	}
	if ent, _ := e.entry(alice, dmInboxCollection, convID); ent.UnreadCount != 0 {
		t.Errorf("alice unread = %d, want 0 (unchanged)", ent.UnreadCount)
	}
	if len(e.events.got) != events {
		t.Error("a refused send pushed")
	}
	if c, _ := e.conv(convID); c.encrypted() {
		t.Error("the policy changed the conversation's encryption")
	}

	// Switching the flag off is the rollback lever: the same plaintext send goes through again.
	e.requireFor()
	e.tick(time.Second)
	if _, err := e.send(alice, toUser(skey(4), bob, "after rollback")); err != nil {
		t.Fatalf("plaintext after the flag went off: %v", err)
	}
}

// A first message (no conversation yet) and a message request are refused before the conversation exists: no
// conversation document, no entry on either side, and the new-conversation quota untouched.
func TestSendRequired_FirstMessageWritesNothing(t *testing.T) {
	for name, mutual := range map[string]bool{"first message between mutuals": true, "message request": false} {
		t.Run(name, func(t *testing.T) {
			e := newIT(t, nil)
			if mutual {
				e.mutual(alice, bob)
			}
			e.requireFor(bob)
			convID := ConversationID(alice, bob)

			_, err := e.send(alice, toUser(skey(1), bob, "hello"))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID})
			if _, ok := e.conv(convID); ok {
				t.Error("a refused first message created the conversation")
			}
			for _, uid := range []string{alice, bob} {
				for _, folder := range []string{dmInboxCollection, dmRequestsCollection} {
					if _, ok := e.entry(uid, folder, convID); ok {
						t.Errorf("a refused first message wrote %s/%s", uid, folder)
					}
				}
			}
			if n := e.dmNew(alice); n != 0 {
				t.Errorf("dm_new_daily = %d, want 0 (nothing reserved)", n)
			}
			if len(e.events.got) != 0 {
				t.Error("a refused first message pushed")
			}
		})
	}
}

// A plaintext message stored before the policy applied replays under its key (the same request, nothing written); the
// same key with other text is the reused-key answer.
func TestSendRequired_ReplayOfEarlierPlaintext(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	first := e.must(alice, toUser(skey(1), bob, "stored before"))
	convID := first.GetConversation().GetId()
	e.tick(time.Second)
	e.requireFor(alice, bob)
	before := e.snapshotState(convID)

	resp, err := e.send(alice, toUser(skey(1), bob, "stored before"))
	if err != nil {
		t.Fatalf("replay refused: %v", err)
	}
	if resp.GetMessage().GetId() != first.GetMessage().GetId() || resp.GetMessage().GetText() != "stored before" {
		t.Errorf("replay = %v, want the stored message", resp.GetMessage())
	}
	before.check(t)

	_, err = e.send(alice, toUser(skey(1), bob, "other text"))
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
}

// Ciphertext into an MLS conversation still passes under the policy, and a plaintext send there keeps the conversation
// rule's answer (unchanged behaviour of send_enc_integration_test.go).
func TestSendRequired_CiphertextStillPasses(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 1)
	e.requireFor(alice, bob)

	if _, err := e.send(alice, encByConv(skey(20), convID, 1, 1, "sealed")); err != nil {
		t.Fatalf("an encrypted send under the policy: %v", err)
	}
	_, err := e.send(bob, toConv(skey(21), convID, "plaintext"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, nil)
}
