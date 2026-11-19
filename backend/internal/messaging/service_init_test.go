package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Starting encryption (mls_init, Task 4) over the fake repo, which runs sendTx's refusals in sendTx's order and applies an
// init for real (sendInit).

const (
	devAlice1 = "alice-device-00001"
	devAlice2 = "alice-device-00002"
	devBob1   = "bob-device-0000001"
	devBob2   = "bob-device-0000002"
	devCarol1 = "carolUID-device-00001"
	carolUID  = "uid-carolUID"
)

func ikey(n int) string { return fmt.Sprintf("init-key-%08d", n) }

// initReq is an mls_init send of ct at (1, 1) to bob (or by conversation id when convID is set), welcoming ids.
func initSend(key, convID, ct string, ids ...string) *messagingv1.SendMessageRequest {
	r := &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Ciphertext: []byte(ct), ReportCommitment: testCommitment, MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("commit:" + ct), Welcome: []byte("welcome:" + ct), WelcomeDeviceIds: ids},
		Target:  &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: bob},
	}
	if convID != "" {
		r.Target = &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID}
	}
	return r
}

// e2eeRig is a rig with messaging on for everyone, e2ee_dm by e2ee (nil: on for everyone), mutual follows between alice
// and bob, and active devices alice: devAlice1, devAlice2; bob: devBob1, devBob2.
func e2eeRig(t *testing.T, e2ee *flags.Spec, mut func(*rig)) *rig {
	t.Helper()
	spec := flags.Spec{Name: keys.FlagName, Mode: flags.On}
	if e2ee != nil {
		spec = *e2ee
	}
	return newRig(t, func(r *rig) {
		r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, spec)
		r.social.snaps[alice] = graph.Snapshot{Following: map[string]bool{bob: true}}
		r.social.snaps[bob] = graph.Snapshot{Following: map[string]bool{alice: true}}
		r.devices.active[alice] = []string{devAlice1, devAlice2}
		r.devices.active[bob] = []string{devBob1, devBob2}
		if mut != nil {
			mut(r)
		}
	})
}

func allowlist(uids ...string) *flags.Spec {
	m := map[string]struct{}{}
	for _, u := range uids {
		m[u] = struct{}{}
	}
	return &flags.Spec{Name: keys.FlagName, Mode: flags.Allowlist, Allowlist: m}
}

// nothingStored checks the fake stored no init: no commit, no welcome, no message, the conversation as given (absent
// when want is nil).
func (r *rig) nothingStored(t *testing.T, convID string, want *ConvDoc) {
	t.Helper()
	if len(r.repo.commits) != 0 || len(r.repo.welcomes) != 0 {
		t.Errorf("stored commits %d welcomes %d, want none", len(r.repo.commits), len(r.repo.welcomes))
	}
	got, ok := r.repo.convs[convID]
	switch {
	case want == nil && ok:
		t.Errorf("conversation created: %+v", got)
	case want != nil && (!ok || got.Encryption != want.Encryption || got.MlsGen != want.MlsGen || got.MlsEpoch != want.MlsEpoch || got.RequestCount != want.RequestCount):
		t.Errorf("conversation = %+v, want %+v", got, *want)
	}
}

// The flag matrix: caller off is FEATURE_DISABLED e2ee_dm before any lookup; recipient off is the CANNOT_MESSAGE of a block,
// byte for byte, before any device lookup; both on starts encryption.
func TestSendInit_FlagMatrix(t *testing.T) {
	convID := ConversationID(alice, bob)
	t.Run("caller off", func(t *testing.T) {
		r := e2eeRig(t, allowlist(bob), nil)
		_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "e2ee_dm"})
		if n := r.repo.gets + len(r.repo.sends) + r.social.calls + r.profs.calls + len(r.devices.calls); n != 0 {
			t.Errorf("a caller with e2ee_dm off cost %d lookups", n)
		}
	})
	t.Run("caller off, by conversation id", func(t *testing.T) {
		r := e2eeRig(t, allowlist(bob), nil)
		_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), convID, "ct", devBob1))
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "e2ee_dm"})
		if r.repo.gets != 0 {
			t.Error("the conversation was read before the e2ee_dm gate")
		}
	})
	t.Run("recipient off", func(t *testing.T) {
		r := e2eeRig(t, allowlist(alice), nil)
		_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
		blocked := e2eeRig(t, nil, func(r *rig) { r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}} })
		_, berr := blocked.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
		if !bytes.Equal(wireBytes(t, err), wireBytes(t, berr)) {
			t.Errorf("recipient off = %q, want the block's bytes %q", wireBytes(t, err), wireBytes(t, berr))
		}
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
		if len(r.devices.calls)+len(r.repo.sends) != 0 {
			t.Errorf("devices %v sends %d after a CANNOT_MESSAGE", r.devices.calls, len(r.repo.sends))
		}
	})
	t.Run("both on", func(t *testing.T) {
		r := e2eeRig(t, allowlist(alice, bob), nil)
		resp, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
		if err != nil {
			t.Fatal(err)
		}
		if c := resp.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 1 || c.GetMlsEpoch() != 1 {
			t.Errorf("conversation = %v (%d, %d), want MLS (1, 1)", c.GetEncryption(), c.GetMlsGeneration(), c.GetMlsEpoch())
		}
		if m := resp.GetMessage(); string(m.GetCiphertext()) != "ct" || m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 1 || m.GetText() != "" {
			t.Errorf("message = %v", m)
		}
	})
}

// What an init stores: the conversation MLS at (1, 1), the commit (1, 0) with the commit bytes and the sender, one
// welcome per device under its owner at (1, 0) with the same welcome bytes and a 30-day expiry, and the message at (1, 1).
// The request hash binds the init content.
func TestSendInit_StoresTheInit(t *testing.T) {
	r := e2eeRig(t, nil, nil)
	convID := ConversationID(alice, bob)
	req := initSend(ikey(1), "", "ct", devBob2, devAlice2, devBob1)
	if _, err := r.svc.Send(verifiedCtx(), alice, req); err != nil {
		t.Fatal(err)
	}
	c := r.repo.convs[convID]
	if c.Encryption != encMLS || c.MlsGen != 1 || c.MlsEpoch != 1 || c.State != stateAccepted {
		t.Errorf("conversation = %+v", c)
	}
	cm, ok := r.repo.commits[convID+"/"+commitDocID(1, 0)]
	if !ok || len(r.repo.commits) != 1 || string(cm.Data) != "commit:ct" || cm.SenderID != alice || cm.Gen != 1 || cm.Epoch != 0 || !cm.ExpireAt.Equal(cm.CreatedAt.Add(CommitRetention)) {
		t.Errorf("commits = %+v", r.repo.commits)
	}
	owners := map[string]string{}
	for _, w := range r.repo.welcomes {
		owners[w.DeviceID] = w.Owner
		if string(w.Data) != "welcome:ct" || w.ConvID != convID || w.Gen != 1 || w.Epoch != 0 || w.ID != welcomeDocID(convID, 1, 0, w.DeviceID) || !w.ExpireAt.Equal(w.CreatedAt.Add(WelcomeRetention)) {
			t.Errorf("welcome = %+v", w)
		}
	}
	if len(r.repo.welcomes) != 3 || owners[devBob1] != bob || owners[devBob2] != bob || owners[devAlice2] != alice {
		t.Errorf("welcome owners = %v", owners)
	}
	p := r.repo.sends[0]
	init := &mlsInit{Commit: []byte("commit:ct"), Welcome: []byte("welcome:ct"), DeviceIDs: []string{devBob2, devAlice2, devBob1}}
	if want := encRequestHash(convID, 1, 1, []byte("ct"), testCommitment, initDigest(init)); p.RequestHash != want {
		t.Errorf("request hash = %q, want the init-bound %q", p.RequestHash, want)
	}
	stored := r.repo.msgs[convID][0]
	if stored.MlsGen != 1 || stored.MlsEpoch != 1 || stored.MlsKey != "1:1" || string(stored.Ciphertext) != "ct" {
		t.Errorf("message = %+v", stored)
	}
	// The instance cache holds the MLS conversation (the next send by conversation id sees it).
	if cached, ok := r.svc.convs.Get(convID); !ok || !cached.encrypted() || cached.MlsEpoch != 1 {
		t.Errorf("cached conversation = %+v, %v", cached, ok)
	}
}

// The device rules (proto MlsInit): every id an ACTIVE device of the caller or the recipient, at least one the
// recipient's; the sending device needs no welcome. Every failure is the same VALIDATION welcome_device_ids, naming no id,
// and stores nothing.
func TestSendInit_DeviceRules(t *testing.T) {
	ok := [][]string{
		{devBob1},
		{devBob1, devBob2},
		{devBob1, devAlice2},
		{devAlice1, devAlice2, devBob2},
	}
	bad := map[string][]string{
		"caller's only":           {devAlice1},
		"caller's two":            {devAlice1, devAlice2},
		"a third user's device":   {devBob1, devCarol1},
		"an unknown id":           {devBob1, "never-registered-01"},
		"recipient's inactive":    {"bob-device-retired"},
		"recipient's + inactive":  {devBob1, "bob-device-retired"},
		"caller's inactive":       {devBob1, "alice-device-retired"},
		"a third user's only":     {devCarol1},
		"recipient's id as owner": {devAlice1, "bob-device-retired"},
	}
	for i, ids := range ok {
		t.Run(fmt.Sprintf("ok %v", ids), func(t *testing.T) {
			r := e2eeRig(t, nil, nil)
			if _, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(i), "", "ct", ids...)); err != nil {
				t.Fatal(err)
			}
			if len(r.repo.welcomes) != len(ids) {
				t.Errorf("welcomes = %d, want %d", len(r.repo.welcomes), len(ids))
			}
		})
	}
	var first []byte
	for name, ids := range bad {
		t.Run(name, func(t *testing.T) {
			r := e2eeRig(t, nil, func(r *rig) { r.devices.active[carolUID] = []string{devCarol1} })
			_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", ids...))
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "welcome_device_ids"})
			got := wireBytes(t, err)
			for _, id := range ids {
				if bytes.Contains(got, []byte(id)) {
					t.Errorf("the answer names %q", id)
				}
			}
			if first == nil {
				first = got
			} else if !bytes.Equal(first, got) {
				t.Errorf("answers differ by cause: %q vs %q", got, first)
			}
			r.nothingStored(t, ConversationID(alice, bob), nil)
			if len(r.devices.calls) != 2 {
				t.Errorf("device lookups = %v, want caller and recipient once each", r.devices.calls)
			}
		})
	}
}

// A refused caller learns nothing about device ids: with bad devices, every existing refusal answers with exactly the
// bytes it has with good devices (a block either way, DM policy, the request cap, a gone peer, dm_new_daily, a
// non-participant).
func TestSendInit_RefusalsComeBeforeTheDeviceCheck(t *testing.T) {
	convID := ConversationID(alice, bob)
	request := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob, RequestCount: 3}
	gone := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, Gone: []string{bob}}
	cases := map[string]struct {
		mut    func(*rig)
		convID string
		reason commonv1.ErrorReason
		code   connect.Code
	}{
		"caller blocks": {func(r *rig) { r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}} }, "", commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, connect.CodeFailedPrecondition},
		"recipient blocks": {func(r *rig) {
			r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}}
		}, "", commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, connect.CodeFailedPrecondition},
		"dm policy": {func(r *rig) {
			p := r.profs.profiles[bob]
			p.DMPolicy = identity.DMPolicyFollowingOnly
			r.profs.profiles[bob] = p
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: keys.FlagName, Mode: flags.On}, flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On})
			r.social.snaps[bob] = graph.Snapshot{}
		}, "", commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, connect.CodeFailedPrecondition},
		"request cap": {func(r *rig) {
			r.repo.convs[convID] = request
			r.social.snaps[bob] = graph.Snapshot{}
		}, "", commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, connect.CodeFailedPrecondition},
		"gone peer":    {func(r *rig) { r.repo.convs[convID] = gone }, convID, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, connect.CodeFailedPrecondition},
		"dm_new_daily": {func(r *rig) { r.limits.DMNewPerDay = 0 }, "", commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, connect.CodeFailedPrecondition},
		"non-participant": {func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(carolUID, bob), State: stateAccepted}
		}, convID, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, connect.CodeNotFound},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			var answers [2][]byte
			for i, ids := range [][]string{{devBob1}, {devCarol1}} {
				r := e2eeRig(t, nil, tc.mut)
				_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), tc.convID, "ct", ids...))
				if code, reason, _ := reasonOf(t, err); code != tc.code || reason != tc.reason {
					t.Fatalf("devices %v: %v %v (%v), want %v %v", ids, code, reason, err, tc.code, tc.reason)
				}
				answers[i] = wireBytes(t, err)
				if len(r.repo.commits)+len(r.repo.welcomes) != 0 {
					t.Error("a refused init stored a commit or a welcome")
				}
			}
			if !bytes.Equal(answers[0], answers[1]) {
				t.Errorf("the refusal depends on the devices: %q vs %q", answers[0], answers[1])
			}
		})
	}
}

// An upgrade by a non-participant (by conversation id) is the one NOT_FOUND, byte-identical to an unknown id, without a
// device lookup.
func TestSendInit_UpgradeByNonParticipantIsNotFound(t *testing.T) {
	convID := ConversationID(alice, carolUID)
	r := e2eeRig(t, nil, func(r *rig) {
		r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, carolUID), State: stateAccepted}
	})
	_, err := r.svc.Send(verifiedCtx(), bob, initSend(ikey(1), convID, "ct", devAlice1))
	_, unknown := r.svc.Send(verifiedCtx(), bob, initSend(ikey(2), ConversationID(bob, "uid-nobody"), "ct", devAlice1))
	wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	if !bytes.Equal(wireBytes(t, err), wireBytes(t, unknown)) {
		t.Errorf("non-participant %q differs from unknown %q", wireBytes(t, err), wireBytes(t, unknown))
	}
	if len(r.devices.calls)+len(r.repo.sends) != 0 {
		t.Errorf("devices %v sends %d", r.devices.calls, len(r.repo.sends))
	}
	if c := r.repo.convs[convID]; c.encrypted() {
		t.Error("the conversation became MLS")
	}
}

// Upgrading a NONE conversation: the conversation keeps its state and counters and becomes MLS at (1, 1); a REQUEST
// conversation counts the init like any message (request_unanswered applies), and the reply that accepts may be the init.
func TestSendInit_Upgrade(t *testing.T) {
	convID := ConversationID(alice, bob)
	t.Run("accepted", func(t *testing.T) {
		r := e2eeRig(t, nil, func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, UpdatedAt: r.now.Add(-time.Microsecond)} // Firestore's resolution: commitStamp answers r.now
		})
		resp, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), convID, "ct", devBob1))
		if err != nil {
			t.Fatal(err)
		}
		if c := r.repo.convs[convID]; !c.encrypted() || c.MlsGen != 1 || c.MlsEpoch != 1 || c.State != stateAccepted || !c.UpdatedAt.Equal(r.now) {
			t.Errorf("conversation = %+v", c)
		}
		if resp.GetConversation().GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS {
			t.Error("answer is not MLS")
		}
	})
	t.Run("request, by the requester", func(t *testing.T) {
		r := e2eeRig(t, nil, func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob, RequestCount: 2}
			r.social.snaps[bob] = graph.Snapshot{}
		})
		resp, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), convID, "ct", devBob1))
		if err != nil {
			t.Fatal(err)
		}
		if c := r.repo.convs[convID]; !c.encrypted() || c.State != stateRequest || c.RequestCount != 3 {
			t.Errorf("conversation = %+v, want MLS REQUEST with requestCount 3", c)
		}
		if resp.GetConversation().GetState() != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || len(r.events.got) != 0 {
			t.Errorf("state %v, events %d: a request init must not push", resp.GetConversation().GetState(), len(r.events.got))
		}
	})
	t.Run("request, the reply that accepts", func(t *testing.T) {
		r := e2eeRig(t, nil, func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: bob, RequestTo: alice, RequestCount: 1}
		})
		if _, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), convID, "ct", devBob1)); err != nil {
			t.Fatal(err)
		}
		if c := r.repo.convs[convID]; !c.encrypted() || c.State != stateAccepted {
			t.Errorf("conversation = %+v, want MLS ACCEPTED", c)
		}
	})
}

// A new conversation opened by an init to a user who does not follow back is a request, like a plaintext first message.
func TestSendInit_NewRequestConversation(t *testing.T) {
	r := e2eeRig(t, nil, func(r *rig) { r.social.snaps[bob] = graph.Snapshot{} })
	resp, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
	if err != nil {
		t.Fatal(err)
	}
	c := r.repo.convs[ConversationID(alice, bob)]
	if c.State != stateRequest || c.RequestFrom != alice || c.RequestCount != 1 || !c.encrypted() {
		t.Errorf("conversation = %+v", c)
	}
	if !r.repo.lastRes.RecipientInRequests || len(r.events.got) != 0 || resp.GetConversation().GetState() != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST {
		t.Errorf("in requests %v, events %d", r.repo.lastRes.RecipientInRequests, len(r.events.got))
	}
}

// An init that finds the conversation already MLS (another device started first) is STALE_EPOCH with the current pair,
// even at exactly (1, 1), storing nothing; addressed by recipient it names the conversation. With bad devices the device
// check answers first (proto: "the device check answers first").
func TestSendInit_AlreadyMLS(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, pair := range [][2]int64{{1, 1}, {1, 4}, {3, 2}} {
		t.Run(fmt.Sprint(pair), func(t *testing.T) {
			r := e2eeRig(t, nil, func(r *rig) { r.repo.convs[convID] = mlsConv(pair[0], pair[1]) })
			want := mlsConv(pair[0], pair[1])
			_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{
				"generation": fmt.Sprint(pair[0]), "epoch": fmt.Sprint(pair[1]), "conversation_id": convID,
			})
			_, err = r.svc.Send(verifiedCtx(), alice, initSend(ikey(2), convID, "ct", devBob1))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, nil)
			if _, _, meta := reasonOf(t, err); meta["conversation_id"] != "" {
				t.Error("a send by conversation id got metadata conversation_id")
			}
			_, err = r.svc.Send(verifiedCtx(), alice, initSend(ikey(3), "", "ct", devCarol1))
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "welcome_device_ids"})
			if len(r.repo.commits)+len(r.repo.welcomes)+len(r.repo.msgs[convID]) != 0 {
				t.Error("a refused init stored something")
			}
			r.nothingStored(t, convID, &want)
		})
	}
}

// A retried init whose message exists with the same key and request is a replay: it wins over STALE_EPOCH (the init
// itself made the conversation MLS) and over the device check (a device went inactive since), even after the epoch moved.
// The same ids in another order are the same request; another commit, welcome, device set or ciphertext under the key is
// VALIDATION idempotency_key.
func TestSendInit_Replay(t *testing.T) {
	convID := ConversationID(alice, bob)
	r := e2eeRig(t, nil, nil)
	first, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1, devAlice2))
	if err != nil {
		t.Fatal(err)
	}
	same := func() *messagingv1.SendMessageRequest { return initSend(ikey(1), "", "ct", devAlice2, devBob1) }
	check := func(name string) {
		t.Helper()
		again, err := r.svc.Send(verifiedCtx(), alice, same())
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if again.GetMessage().GetId() != first.GetMessage().GetId() || !again.GetMessage().GetCreatedAt().AsTime().Equal(first.GetMessage().GetCreatedAt().AsTime()) {
			t.Errorf("%s: answered %v, want the stored message", name, again.GetMessage())
		}
		if len(r.repo.commits) != 1 || len(r.repo.welcomes) != 2 || len(r.repo.msgs[convID]) != 1 {
			t.Errorf("%s: a replay stored more: commits %d welcomes %d msgs %d", name, len(r.repo.commits), len(r.repo.welcomes), len(r.repo.msgs[convID]))
		}
	}
	check("immediate retry, ids reordered")
	r.devices.active[bob] = nil // bob's device went inactive: the device check would refuse
	check("devices changed")
	c := r.repo.convs[convID]
	c.MlsEpoch = 4
	r.repo.convs[convID] = c
	check("epoch moved")
	r.devices.active[bob] = []string{devBob1, devBob2}
	for name, req := range map[string]*messagingv1.SendMessageRequest{
		"other ids":        initSend(ikey(1), "", "ct", devBob1),
		"other ciphertext": initSend(ikey(1), "", "ct2", devBob1, devAlice2),
		"other commit": func() *messagingv1.SendMessageRequest {
			q := same()
			q.MlsInit.Commit = []byte("another commit")
			return q
		}(),
		"other welcome": func() *messagingv1.SendMessageRequest {
			q := same()
			q.MlsInit.Welcome = []byte("another welcome")
			return q
		}(),
	} {
		_, err := r.svc.Send(verifiedCtx(), alice, req)
		if code, reason, meta := reasonOf(t, err); code != connect.CodeInvalidArgument || reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || meta["field"] != "idempotency_key" {
			t.Errorf("%s: %v %v %v, want VALIDATION idempotency_key", name, code, reason, meta)
		}
	}
}

// A device lookup failure is an internal error, never a refusal, and sends nothing; without a directory an init fails
// the same way while a plaintext send is unaffected.
func TestSendInit_DeviceLookupFailure(t *testing.T) {
	r := e2eeRig(t, nil, func(r *rig) { r.devices.err = errors.New("boom " + bob) })
	_, err := r.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1))
	if code, _, _ := reasonOf(t, err); code != connect.CodeInternal {
		t.Fatalf("err = %v, want internal", err)
	}
	if strings.Contains(err.Error(), bob) {
		t.Errorf("the error carries the uid: %v", err)
	}
	if len(r.repo.sends) != 0 {
		t.Error("sent after a failed device lookup")
	}
	r2 := e2eeRig(t, nil, nil)
	r2.svc.d.Devices = nil
	if _, err := r2.svc.Send(verifiedCtx(), alice, initSend(ikey(1), "", "ct", devBob1)); err == nil {
		t.Error("an init without a device directory succeeded")
	}
	if _, err := r2.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "plain")); err != nil {
		t.Errorf("a plaintext send needs no device directory: %v", err)
	}
}

// The request line of an init carries mls_init = true and nothing of the bytes or the device ids.
func TestSendInit_RequestLineHasNoSecrets(t *testing.T) {
	for name, ids := range map[string][]string{"stored": {devBob1, devAlice2}, "refused": {devCarol1}} {
		t.Run(name, func(t *testing.T) {
			r := e2eeRig(t, nil, nil)
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, _ = r.svc.Send(ctx, alice, initSend(ikey(1), "", "secret-ct", ids...))
			if v, ok := info.Get(fieldMlsInit); !ok || v != true {
				t.Errorf("mls_init field = %v, %v", v, ok)
			}
			for _, a := range info.Fields() {
				for _, sec := range append([]string{"secret-ct", "commit:", "welcome:", alice, bob}, ids...) {
					if strings.Contains(a.Value.String(), sec) || strings.Contains(a.Key, sec) {
						t.Errorf("request field %s=%q contains %q", a.Key, a.Value.String(), sec)
					}
				}
			}
		})
	}
}

// Plaintext sends are untouched by the init path: a plaintext first message never looks up devices.
func TestSendInit_PlaintextNeverLooksUpDevices(t *testing.T) {
	r := e2eeRig(t, nil, nil)
	if _, err := r.svc.Send(context.WithoutCancel(verifiedCtx()), alice, toUser(key1, bob, "plain")); err != nil {
		t.Fatal(err)
	}
	if len(r.devices.calls) != 0 {
		t.Errorf("device lookups %v for a plaintext send", r.devices.calls)
	}
}
