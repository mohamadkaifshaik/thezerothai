package messaging

import (
	"bytes"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// Encrypted sends into an existing MLS conversation (Task 3): the fake repo runs the same gate as sendTx (encGate),
// after the same refusals, with the same replay rule (replayOrRefuse).

var testCommitment = bytes.Repeat([]byte{0xC0}, CommitmentBytes)

// encTo is an encrypted send of ct at (gen, epoch), addressed by conversation id (byConv) or to bob.
func encTo(key, convID string, byConv bool, gen, epoch uint64, ct string) *messagingv1.SendMessageRequest {
	r := &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Ciphertext: []byte(ct), ReportCommitment: testCommitment, MlsGeneration: gen, MlsEpoch: epoch,
	}
	if byConv {
		r.Target = &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID}
	} else {
		r.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: bob}
	}
	return r
}

// mlsConv is an ACCEPTED alice-bob conversation at the pair (gen, epoch).
func mlsConv(gen, epoch int64) ConvDoc {
	return ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, Encryption: encMLS, MlsGen: gen, MlsEpoch: epoch}
}

func TestEncGate(t *testing.T) {
	plain := ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}
	mls := mlsConv(2, 5)
	enc := func(gen, epoch int64) *encSend {
		return &encSend{Ciphertext: []byte("c"), Commitment: testCommitment, Gen: gen, Epoch: epoch}
	}
	tests := []struct {
		name string
		conv *ConvDoc
		enc  *encSend
		want error // nil = pass; a *staleEpochError compares by pair
	}{
		{"plaintext into a new conversation", nil, nil, nil},
		{"plaintext into a plaintext conversation", &plain, nil, nil},
		{"plaintext into an MLS conversation", &mls, nil, ErrEncryptionRequired},
		{"encrypted into a new conversation", nil, enc(1, 1), errNeedsInit},
		{"encrypted into a plaintext conversation", &plain, enc(1, 1), errNeedsInit},
		{"encrypted at the current pair", &mls, enc(2, 5), nil},
		{"encrypted at an older epoch", &mls, enc(2, 4), &staleEpochError{Gen: 2, Epoch: 5}},
		{"encrypted at a newer epoch", &mls, enc(2, 6), &staleEpochError{Gen: 2, Epoch: 5}},
		{"encrypted at an older generation", &mls, enc(1, 5), &staleEpochError{Gen: 2, Epoch: 5}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := encGate(tt.conv, tt.enc)
			var wantStale, gotStale *staleEpochError
			switch {
			case errors.As(tt.want, &wantStale):
				if !errors.As(got, &gotStale) || *gotStale != *wantStale {
					t.Fatalf("encGate = %v, want stale %+v", got, *wantStale)
				}
			case !errors.Is(got, tt.want) || (tt.want == nil && got != nil):
				t.Fatalf("encGate = %v, want %v", got, tt.want)
			}
		})
	}
}

// An encrypted send at the current pair reaches the transaction as ciphertext only, with the encrypted request hash; the
// answer carries the ciphertext fields, the conversation's encryption and pair, and an empty encrypted preview. It pushes
// like a plaintext message (the push carries the conversation id only).
func TestSendEnc_StoredAndAnswered(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, byConv := range []bool{true, false} {
		r := newRig(t, func(r *rig) { r.repo.convs[convID] = mlsConv(1, 3) })
		resp, err := r.svc.Send(verifiedCtx(), alice, encTo(key1, convID, byConv, 1, 3, "sealed"))
		if err != nil {
			t.Fatalf("byConv=%v: %v", byConv, err)
		}
		p := r.repo.sends[0]
		if p.Enc == nil || string(p.Enc.Ciphertext) != "sealed" || !bytes.Equal(p.Enc.Commitment, testCommitment) || p.Enc.Gen != 1 || p.Enc.Epoch != 3 || p.Enc.Init != nil {
			t.Fatalf("SendParams.Enc = %+v", p.Enc)
		}
		if p.Text != "" || p.SharedPostID != "" {
			t.Errorf("an encrypted send carried text %q / post %q", p.Text, p.SharedPostID)
		}
		if want := encRequestHash(convID, 1, 3, []byte("sealed"), testCommitment); p.RequestHash != want {
			t.Errorf("RequestHash = %q, want the encrypted hash %q", p.RequestHash, want)
		}
		m := resp.GetMessage()
		if string(m.GetCiphertext()) != "sealed" || !bytes.Equal(m.GetReportCommitment(), testCommitment) || m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 3 || m.GetCiphertextRemoved() || m.GetText() != "" || m.GetSharedPost() != nil {
			t.Errorf("message = %v", m)
		}
		c := resp.GetConversation()
		if c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 1 || c.GetMlsEpoch() != 3 {
			t.Errorf("conversation encryption = %v (%d, %d)", c.GetEncryption(), c.GetMlsGeneration(), c.GetMlsEpoch())
		}
		if lm := c.GetLastMessage(); lm.GetSnippet() != "" || !lm.GetEncrypted() || lm.GetSharedPost() {
			t.Errorf("preview = %v, want empty encrypted", lm)
		}
		if len(r.events.got) != 1 || r.events.got[0].ConversationID != convID {
			t.Errorf("events = %+v, want one push for the conversation", r.events.got)
		}
	}
}

// A plaintext answer states encryption NONE and no pair; its message has no ciphertext fields and the preview is not
// encrypted.
func TestSendEnc_PlaintextAnswerIsNone(t *testing.T) {
	r := newRig(t, nil)
	resp, err := r.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
	if err != nil {
		t.Fatal(err)
	}
	if r.repo.sends[0].Enc != nil {
		t.Error("a plaintext send carried Enc")
	}
	c, m := resp.GetConversation(), resp.GetMessage()
	if c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_NONE || c.GetMlsGeneration() != 0 || c.GetMlsEpoch() != 0 {
		t.Errorf("conversation encryption = %v (%d, %d)", c.GetEncryption(), c.GetMlsGeneration(), c.GetMlsEpoch())
	}
	if len(m.GetCiphertext())+len(m.GetReportCommitment()) != 0 || m.GetMlsGeneration() != 0 || m.GetCiphertextRemoved() || c.GetLastMessage().GetEncrypted() {
		t.Errorf("plaintext message carries encrypted fields: %v", m)
	}
}

// The two new refusals: ENCRYPTION_REQUIRED and STALE_EPOCH (current pair). A send addressed by recipient_user_id also
// gets metadata["conversation_id"]; one addressed by conversation id does not. Neither pushes, evicts a badge or writes.
func TestSendEnc_Refusals(t *testing.T) {
	convID := ConversationID(alice, bob)
	tests := []struct {
		name   string
		req    *messagingv1.SendMessageRequest
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"plaintext by conversation id", toConv(key1, convID, "hi"), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{}},
		{"plaintext by recipient", toUser(key1, bob, "hi"), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID}},
		{"stale epoch by conversation id", encTo(key1, convID, true, 2, 6, "ct"), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "2", "epoch": "7"}},
		{"stale generation by recipient", encTo(key1, convID, false, 1, 7, "ct"), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "2", "epoch": "7", "conversation_id": convID}},
		{"future epoch", encTo(key1, convID, true, 2, 8, "ct"), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "2", "epoch": "7"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) { r.repo.convs[convID] = mlsConv(2, 7) })
			_, err := r.svc.Send(verifiedCtx(), alice, tt.req)
			wantAPI(t, err, tt.code, tt.reason, tt.meta)
			_, _, meta := reasonOf(t, err)
			if len(meta) != len(tt.meta) {
				t.Errorf("metadata = %v, want exactly %v", meta, tt.meta)
			}
			if len(r.events.got)+len(r.badge.got) != 0 {
				t.Errorf("a refused send pushed %d events / evicted %d badges", len(r.events.got), len(r.badge.got))
			}
			if !r.repo.lastRes.Msg.CreatedAt.IsZero() {
				t.Error("the fake transaction reached the write")
			}
		})
	}
}

// Encrypted into a plaintext conversation, or opening a new one, without mls_init: VALIDATION ciphertext, from the
// transaction (after the recipient checks).
func TestSendEnc_IntoPlaintextIsValidationCiphertext(t *testing.T) {
	convID := ConversationID(alice, bob)
	for name, seed := range map[string]bool{"existing plaintext conversation": true, "no conversation yet": false} {
		t.Run(name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				if seed {
					r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted}
				}
			})
			_, err := r.svc.Send(verifiedCtx(), alice, encTo(key1, convID, false, 1, 1, "ct"))
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "ciphertext"})
			if len(r.repo.sends) != 1 || len(r.events.got) != 0 {
				t.Errorf("sends = %d events = %d, want the transaction to refuse it", len(r.repo.sends), len(r.events.got))
			}
		})
	}
}

// Every existing refusal comes first and keeps its bytes: a block, the DM policy and a gone peer answer CANNOT_MESSAGE
// for a plaintext send into an MLS conversation and for a stale encrypted one alike.
func TestSendEnc_ExistingRefusalsComeFirst(t *testing.T) {
	convID := ConversationID(alice, bob)
	ref := cannotMessage()
	for _, req := range []*messagingv1.SendMessageRequest{toConv(key1, convID, "hi"), encTo(key1, convID, true, 1, 1, "ct")} {
		t.Run("blocked by the recipient", func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.repo.convs[convID] = mlsConv(3, 3)
				r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}}
			})
			_, err := r.svc.Send(verifiedCtx(), alice, req)
			if !bytes.Equal(wireBytes(t, err), wireBytes(t, ref)) {
				t.Errorf("got %v, want the CANNOT_MESSAGE bytes", err)
			}
		})
		t.Run("peer gone", func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				c := mlsConv(3, 3)
				c.Gone = []string{bob}
				r.repo.convs[convID] = c
			})
			_, err := r.svc.Send(verifiedCtx(), alice, req)
			if !bytes.Equal(wireBytes(t, err), wireBytes(t, ref)) {
				t.Errorf("got %v, want the CANNOT_MESSAGE bytes", err)
			}
		})
		t.Run("caller blocked the recipient", func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.repo.convs[convID] = mlsConv(3, 3)
				r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}}
			})
			_, err := r.svc.Send(verifiedCtx(), alice, req)
			if !bytes.Equal(wireBytes(t, err), wireBytes(t, ref)) {
				t.Errorf("got %v, want the CANNOT_MESSAGE bytes", err)
			}
		})
	}
}

// A replay wins over STALE_EPOCH and ENCRYPTION_REQUIRED: the stored message of this key with the same request hash is
// returned (no push), even after the epoch moved on or the conversation became encrypted. The same key with another
// request is VALIDATION idempotency_key (today's reused-key answer).
func TestSendEnc_ReplayWins(t *testing.T) {
	convID := ConversationID(alice, bob)
	msgID := MessageID(alice, key1)
	encStored := MsgDoc{
		SenderID: alice, State: msgVisible, RequestHash: encRequestHash(convID, 1, 3, []byte("sealed"), testCommitment),
		Ciphertext: []byte("sealed"), Commitment: testCommitment, MlsGen: 1, MlsEpoch: 3, MlsKey: mlsKey(1, 3),
	}
	plainStored := MsgDoc{SenderID: alice, Text: "hi", State: msgVisible, RequestHash: requestHash(convID, "hi", "")}
	tests := []struct {
		name   string
		stored MsgDoc
		req    *messagingv1.SendMessageRequest
		reused bool
	}{
		{"encrypted retry after the epoch advanced", encStored, encTo(key1, convID, true, 1, 3, "sealed"), false},
		{"encrypted retry by recipient after the epoch advanced", encStored, encTo(key1, convID, false, 1, 3, "sealed"), false},
		{"plaintext retry after the conversation became encrypted", plainStored, toConv(key1, convID, "hi"), false},
		{"same key, other ciphertext", encStored, encTo(key1, convID, true, 1, 3, "other"), true},
		{"same key, other pair", encStored, encTo(key1, convID, true, 1, 4, "sealed"), true},
		{"same key, other commitment", encStored, func() *messagingv1.SendMessageRequest {
			r := encTo(key1, convID, true, 1, 3, "sealed")
			r.ReportCommitment = bytes.Repeat([]byte{1}, CommitmentBytes)
			return r
		}(), true},
		{"same key, plaintext after an encrypted message", encStored, toConv(key1, convID, "hi"), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.repo.convs[convID] = mlsConv(1, 5)
				r.repo.msgs = map[string][]MessageRow{convID: {{ID: msgID, MsgDoc: tt.stored}}}
			})
			resp, err := r.svc.Send(verifiedCtx(), alice, tt.req)
			if tt.reused {
				wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if resp.GetMessage().GetId() != msgID || string(resp.GetMessage().GetCiphertext()) != string(tt.stored.Ciphertext) || resp.GetMessage().GetText() != tt.stored.Text {
				t.Errorf("replay answered %v", resp.GetMessage())
			}
			if len(r.events.got) != 0 {
				t.Errorf("a replay pushed %d events", len(r.events.got))
			}
		})
	}
}

// A replayed message whose ciphertext was removed (by the retention sweep or a takedown) answers ciphertext_removed with
// no ciphertext or commitment, keeping the pair.
func TestSendEnc_ReplayOfRemovedCiphertext(t *testing.T) {
	convID := ConversationID(alice, bob)
	for name, stored := range map[string]MsgDoc{
		"swept":      {SenderID: alice, State: msgVisible, RequestHash: encRequestHash(convID, 1, 3, []byte("sealed"), testCommitment), MlsGen: 1, MlsEpoch: 3, CtRemoved: true},
		"taken down": {SenderID: alice, State: msgRemoved, MlsGen: 1, MlsEpoch: 3, Ciphertext: []byte("sealed"), Commitment: testCommitment},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.repo.convs[convID] = mlsConv(1, 5)
				r.repo.msgs = map[string][]MessageRow{convID: {{ID: MessageID(alice, key1), MsgDoc: stored}}}
			})
			resp, err := r.svc.Send(verifiedCtx(), alice, encTo(key1, convID, true, 1, 3, "sealed"))
			if err != nil {
				t.Fatal(err)
			}
			m := resp.GetMessage()
			if !m.GetCiphertextRemoved() || len(m.GetCiphertext())+len(m.GetReportCommitment()) != 0 || m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 3 {
				t.Errorf("message = %v", m)
			}
		})
	}
}

// The encrypted shape is validated before any read, mls_init's format included (before its e2ee_dm gate: the rig has
// e2ee_dm off), writing nothing.
func TestSendEnc_ValidationAndInitCostNoReads(t *testing.T) {
	convID := ConversationID(alice, bob)
	withText := encTo(key1, convID, true, 1, 1, "ct")
	withText.Text = "hi"
	noCommit := encTo(key1, convID, true, 1, 1, "ct")
	noCommit.ReportCommitment = nil
	withInit := encTo(key1, convID, false, 1, 1, "ct")
	withInit.MlsInit = &messagingv1.MlsInit{Commit: []byte("c"), Welcome: []byte("w"), WelcomeDeviceIds: []string{devA, devA}}
	badKey := encTo("short", convID, true, 1, 1, "ct")
	for name, tt := range map[string]struct {
		req   *messagingv1.SendMessageRequest
		field string
	}{
		"text with ciphertext": {withText, "text"},
		"no commitment":        {noCommit, "report_commitment"},
		"bad key first":        {badKey, "idempotency_key"},
		"mls_init format":      {withInit, "welcome_device_ids"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newRig(t, func(r *rig) { r.repo.convs[convID] = mlsConv(1, 1) })
			_, err := r.svc.Send(verifiedCtx(), alice, tt.req)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			if r.repo.gets+len(r.repo.sends)+r.social.calls+r.profs.calls+len(r.devices.calls) != 0 {
				t.Errorf("a rejected request read or wrote: gets %d sends %d graph %d profiles %d", r.repo.gets, len(r.repo.sends), r.social.calls, r.profs.calls)
			}
		})
	}
}
