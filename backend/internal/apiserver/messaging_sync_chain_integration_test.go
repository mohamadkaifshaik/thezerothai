//go:build integration

package apiserver

// The six encrypted-conversation procedures over the real Build chain on the emulators: the flag class of each (Commit per
// caller; the three sync lists and AckWelcomes not globally off; none needs e2ee_dm), DEGRADED_MODE=readonly (Commit and
// AckWelcomes refused, the lists answer), the shared sync bucket, the commit daily cap and the reset cap as wired by Build,
// and ListWelcomes / AckWelcomes reading the real key directory through the late-bound adapter.

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

// e2eeWorld is an encrypted alice-bob conversation started over the chain: both registered a key device, alice sent an
// mls_init welcoming bob's device.
type e2eeWorld struct {
	alice, bob             dmUser
	aliceDevice, bobDevice string
	conv                   string
	allow                  map[string]struct{}
}

func newE2EEWorld(t *testing.T) e2eeWorld {
	t.Helper()
	skipIfNoEmulators(t)
	mint := func() dmUser { tok, uid := mintToken(t, ""); return dmUser{tok, uid} }
	w := e2eeWorld{alice: mint(), bob: mint(), aliceDevice: "sync-chain-alice-device", bobDevice: "sync-chain-bob-device-1"}
	w.allow = map[string]struct{}{w.alice.uid: {}, w.bob.uid: {}}
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: w.allow}
	})
	e.createProfile(t, w.alice.token)
	e.createProfile(t, w.bob.token)
	e.mutual(t, w.alice, w.bob)
	ctx := context.Background()
	kc := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	for _, d := range []struct {
		u   dmUser
		dev string
	}{{w.alice, w.aliceDevice}, {w.bob, w.bobDevice}} {
		if _, err := kc.RegisterKeyDevice(ctx, authed(d.u.token, &keysv1.RegisterKeyDeviceRequest{
			IdempotencyKey: contractKey("sync-reg"), DeviceId: d.dev, SignaturePublicKey: bytes.Repeat([]byte{7}, 32),
		})); err != nil {
			t.Fatalf("RegisterKeyDevice: %v", err)
		}
	}
	res, err := e.msg.SendMessage(ctx, authed(w.alice.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("sync-init"), Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: w.bob.uid},
		Ciphertext: []byte("ct"), ReportCommitment: bytes.Repeat([]byte{1}, 32), MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("commit"), Welcome: []byte("welcome"), WelcomeDeviceIds: []string{w.bobDevice}},
	}))
	if err != nil {
		t.Fatalf("mls_init: %v", err)
	}
	w.conv = res.Msg.GetConversation().GetId()
	return w
}

// syncCalls are the four sync RPCs as bob over a chain; each returns the error only.
func (w e2eeWorld) syncCalls(e *dmChain) map[string]func() error {
	ctx := context.Background()
	return map[string]func() error{
		"ListConversationCommits": func() error {
			_, err := e.msg.ListConversationCommits(ctx, authed(w.bob.token, &messagingv1.ListConversationCommitsRequest{ConversationId: w.conv}))
			return err
		},
		"ListEpochMessages": func() error {
			_, err := e.msg.ListEpochMessages(ctx, authed(w.bob.token, &messagingv1.ListEpochMessagesRequest{ConversationId: w.conv, MlsGeneration: 1, MlsEpoch: 1}))
			return err
		},
		"ListWelcomes": func() error {
			_, err := e.msg.ListWelcomes(ctx, authed(w.bob.token, &messagingv1.ListWelcomesRequest{DeviceId: w.bobDevice}))
			return err
		},
		"AckWelcomes": func() error {
			_, err := e.msg.AckWelcomes(ctx, authed(w.bob.token, &messagingv1.AckWelcomesRequest{IdempotencyKey: contractKey("ack"), DeviceId: w.bobDevice, Ids: []string{"0123456789abcdef0123456789abcdef"}}))
			return err
		},
	}
}

func (w e2eeWorld) commit(e *dmChain, who dmUser, gen, epoch uint64, tag string, reset bool) error {
	req := &messagingv1.CommitConversationRequest{IdempotencyKey: contractKey("commit"), ConversationId: w.conv, MlsGeneration: gen, MlsEpoch: epoch, Commit: []byte("commit " + tag), Reset_: reset}
	if reset {
		req.Welcome, req.WelcomeDeviceIds = []byte("welcome "+tag), []string{w.bobDevice}
	}
	_, err := e.msg.CommitConversation(context.Background(), authed(who.token, req))
	return err
}

// The real chain end to end: bob lists his welcome through the real key directory (DeviceIDs), alice commits, bob catches
// up, bob acknowledges; a device of the other user is refused.
func TestMessagingSyncChain_EndToEnd(t *testing.T) {
	w := newE2EEWorld(t)
	e := newDMChain(t, nil)
	ctx := context.Background()
	wl, err := e.msg.ListWelcomes(ctx, authed(w.bob.token, &messagingv1.ListWelcomesRequest{DeviceId: w.bobDevice}))
	if err != nil || len(wl.Msg.GetWelcomes()) != 1 || wl.Msg.GetWelcomes()[0].GetConversationId() != w.conv || string(wl.Msg.GetWelcomes()[0].GetWelcome()) != "welcome" {
		t.Fatalf("bob's welcomes = %v, %v", wl, err)
	}
	_, err = e.msg.ListWelcomes(ctx, authed(w.alice.token, &messagingv1.ListWelcomesRequest{DeviceId: w.bobDevice}))
	wantReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "field", "device_id")
	if err := w.commit(e, w.alice, 1, 1, "c11", false); err != nil {
		t.Fatalf("commit: %v", err)
	}
	cs, err := e.msg.ListConversationCommits(ctx, authed(w.bob.token, &messagingv1.ListConversationCommitsRequest{ConversationId: w.conv, AfterGeneration: 1, AfterEpoch: 0}))
	if err != nil || len(cs.Msg.GetCommits()) != 1 || cs.Msg.GetCommits()[0].GetFromSelf() || cs.Msg.GetMlsEpoch() != 2 {
		t.Fatalf("bob's catch-up = %v, %v", cs, err)
	}
	em, err := e.msg.ListEpochMessages(ctx, authed(w.bob.token, &messagingv1.ListEpochMessagesRequest{ConversationId: w.conv, MlsGeneration: 1, MlsEpoch: 1}))
	if err != nil || len(em.Msg.GetMessages()) != 1 || string(em.Msg.GetMessages()[0].GetCiphertext()) != "ct" {
		t.Fatalf("epoch (1, 1) = %v, %v", em, err)
	}
	if _, err := e.msg.AckWelcomes(ctx, authed(w.bob.token, &messagingv1.AckWelcomesRequest{IdempotencyKey: contractKey("ack"), DeviceId: w.bobDevice, Ids: []string{wl.Msg.GetWelcomes()[0].GetId()}})); err != nil {
		t.Fatal(err)
	}
	wl, _ = e.msg.ListWelcomes(ctx, authed(w.bob.token, &messagingv1.ListWelcomesRequest{DeviceId: w.bobDevice}))
	if len(wl.Msg.GetWelcomes()) != 0 {
		t.Errorf("after the ack = %v", wl.Msg.GetWelcomes())
	}
	// A non-participant gets the one NOT_FOUND on every conversation-scoped RPC.
	carol := e.user(t)
	_, lmErr := e.msg.ListMessages(ctx, authed(carol.token, &messagingv1.ListMessagesRequest{ConversationId: w.conv}))
	_, csErr := e.msg.ListConversationCommits(ctx, authed(carol.token, &messagingv1.ListConversationCommitsRequest{ConversationId: w.conv}))
	_, emErr := e.msg.ListEpochMessages(ctx, authed(carol.token, &messagingv1.ListEpochMessagesRequest{ConversationId: w.conv, MlsGeneration: 1, MlsEpoch: 1}))
	cmErr := w.commit(e, carol, 1, 2, "x", false)
	for name, err := range map[string]error{"ListConversationCommits": csErr, "ListEpochMessages": emErr, "CommitConversation": cmErr} {
		if wireBytes(t, err) != wireBytes(t, lmErr) {
			t.Errorf("%s for a stranger = %v, want ListMessages' NOT_FOUND bytes", name, err)
		}
	}
}

// The flag class of each procedure (proto): Commit needs messaging on for the caller; the sync lists and AckWelcomes only
// not globally off; none needs e2ee_dm (here off for everyone).
func TestMessagingSyncChain_FlagClasses(t *testing.T) {
	w := newE2EEWorld(t)
	for _, tt := range []struct {
		name      string
		spec      flags.Spec
		globalOff bool
		commitOK  bool
	}{
		{"off (the default)", flags.Spec{Name: "messaging", Mode: flags.Off}, true, false},
		{"allowlist without the caller", flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}, false, false},
		{"percent 0", flags.Spec{Name: "messaging", Mode: flags.Percent}, false, false},
		{"on", flags.Spec{Name: "messaging", Mode: flags.On}, false, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newDMChain(t, func(c *config.Config) {
				c.FeatureMessaging = tt.spec
				c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Off}
			})
			for name, call := range w.syncCalls(e) {
				err := call()
				if tt.globalOff {
					featureDisabled(t, err)
					continue
				}
				if err != nil {
					t.Errorf("%s with messaging merely off for the caller: %v", name, err)
				}
			}
			// A commit on a stale pair: STALE_EPOCH once past the gate (nothing is written), else FEATURE_DISABLED.
			err := w.commit(e, w.bob, 1, 99, "stale", false)
			if tt.commitOK {
				wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, "", "")
			} else {
				featureDisabled(t, err)
			}
		})
	}
}

// DEGRADED_MODE=readonly: CommitConversation and AckWelcomes are refused by the interceptor; the three lists answer.
func TestMessagingSyncChain_Readonly(t *testing.T) {
	w := newE2EEWorld(t)
	e := newDMChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })
	for name, call := range w.syncCalls(e) {
		err := call()
		if name == "AckWelcomes" {
			wantReason(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE, "", "")
			continue
		}
		if err != nil {
			t.Errorf("%s under readonly: %v", name, err)
		}
	}
	wantReason(t, w.commit(e, w.alice, 1, 1, "ro", false), connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE, "", "")
}

// The four sync RPCs share one bucket (RATE_LIMIT_MESSAGES_SYNC_PER_MIN, here 4): the fifth call of any of them is
// RATE_LIMITED; ListMessages (another bucket) still answers.
func TestMessagingSyncChain_SharedSyncBucket(t *testing.T) {
	w := newE2EEWorld(t)
	e := newDMChain(t, func(c *config.Config) { c.RateLimit.MessagesSyncPerUserPerMinute = 4 })
	calls := w.syncCalls(e)
	for _, name := range []string{"ListConversationCommits", "ListEpochMessages", "ListWelcomes", "AckWelcomes"} {
		if err := calls[name](); err != nil {
			t.Fatalf("%s within the budget: %v", name, err)
		}
	}
	for _, name := range []string{"ListConversationCommits", "ListWelcomes"} {
		wantReason(t, calls[name](), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "", "")
	}
	if _, err := e.msg.ListMessages(context.Background(), authed(w.bob.token, &messagingv1.ListMessagesRequest{ConversationId: w.conv})); err != nil {
		t.Errorf("ListMessages after the sync budget: %v", err)
	}
}

// ListMessageTombstones and ListEpochMessages with order = CREATED_AT over the real chain: both need e2ee_dm not globally
// off (an allowlist without the caller is enough), both answer under DEGRADED_MODE=readonly, and ListMessageTombstones
// draws on the shared sync bucket.
func TestMessagingSyncChain_TombstonesAndOrderedEpoch(t *testing.T) {
	w := newE2EEWorld(t)
	ctx := context.Background()
	tomb := func(e *dmChain) error {
		_, err := e.msg.ListMessageTombstones(ctx, authed(w.bob.token, &messagingv1.ListMessageTombstonesRequest{ConversationId: w.conv}))
		return err
	}
	ordered := func(e *dmChain) (*connect.Response[messagingv1.ListEpochMessagesResponse], error) {
		return e.msg.ListEpochMessages(ctx, authed(w.bob.token, &messagingv1.ListEpochMessagesRequest{ConversationId: w.conv, MlsGeneration: 1, MlsEpoch: 1,
			Order: messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_CREATED_AT}))
	}
	notListed := flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}
	for _, tt := range []struct {
		name string
		spec flags.Spec
		off  bool
	}{
		{"e2ee_dm off", flags.Spec{Name: "e2ee_dm", Mode: flags.Off}, true},
		{"e2ee_dm allowlist without the caller", notListed, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newDMChain(t, func(c *config.Config) { c.FeatureE2EEDM = tt.spec })
			terr := tomb(e)
			resp, oerr := ordered(e)
			if tt.off {
				wantReason(t, terr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")
				wantReason(t, oerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "e2ee_dm")
				return
			}
			if terr != nil {
				t.Errorf("ListMessageTombstones: %v", terr)
			}
			if oerr != nil || resp.Msg.GetOrder() != messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_CREATED_AT || len(resp.Msg.GetMessages()) != 1 {
				t.Errorf("ordered epoch (1, 1) = %v, %v", resp, oerr)
			}
		})
	}
	t.Run("readonly answers", func(t *testing.T) {
		e := newDMChain(t, func(c *config.Config) { c.Degraded, c.FeatureE2EEDM = config.DegradedReadonly, notListed })
		if err := tomb(e); err != nil {
			t.Errorf("ListMessageTombstones under readonly: %v", err)
		}
	})
	t.Run("the shared sync bucket", func(t *testing.T) {
		e := newDMChain(t, func(c *config.Config) { c.RateLimit.MessagesSyncPerUserPerMinute, c.FeatureE2EEDM = 2, notListed })
		if _, err := ordered(e); err != nil {
			t.Fatalf("ListEpochMessages within the budget: %v", err)
		}
		if err := tomb(e); err != nil {
			t.Fatalf("ListMessageTombstones within the budget: %v", err)
		}
		wantReason(t, tomb(e), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "", "")
	})
}

// Build wires both caps: messages_commits_daily on every CommitConversation call (a retry and a refusal included) and
// messages_resets_daily on the resets, a reset counting against both.
func TestMessagingSyncChain_CommitAndResetCaps(t *testing.T) {
	w := newE2EEWorld(t)
	e := newDMChain(t, func(c *config.Config) {
		c.RateLimit.MessagesCommitsPerDay = 3
		c.RateLimit.MessagesResetsPerDay = 1
	})
	// Reset 1: accepted ((1, 1) -> (2, 1)); reset 2: the reset cap; both drew on the commits cap (2 of 3).
	if err := w.commit(e, w.alice, 1, 0, "r1", true); err != nil {
		t.Fatalf("first reset: %v", err)
	}
	wantReason(t, w.commit(e, w.alice, 2, 0, "r2", true), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", "messages_resets_daily")
	// Commit 3 (a stale one, refused: still counted), then the commits cap.
	wantReason(t, w.commit(e, w.alice, 2, 9, "stale", false), connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, "", "")
	wantReason(t, w.commit(e, w.alice, 2, 1, "c21", false), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", "messages_commits_daily")
	// Bob has his own counters.
	if err := w.commit(e, w.bob, 2, 1, "b21", false); err != nil {
		t.Errorf("bob's commit: %v", err)
	}
}

// Build wires the per-(caller, conversation) cap messages_commits_per_conversation_daily (here 2): alice's third call on
// the conversation is refused while bob still commits on it; a stranger draws only on their own counter (NOT_FOUND until
// it runs out, then the same RATE_LIMITED for the real and an unknown conversation id; byte identity, retry_after
// included, is pinned on a frozen clock by the unit test TestCommit_PerConversationCap).
func TestMessagingSyncChain_PerConversationCommitCap(t *testing.T) {
	w := newE2EEWorld(t)
	e := newDMChain(t, func(c *config.Config) { c.RateLimit.MessagesCommitsPerConversationPerDay = 2 })
	if err := w.commit(e, w.alice, 1, 1, "c11", false); err != nil {
		t.Fatalf("first commit: %v", err)
	}
	if err := w.commit(e, w.alice, 1, 2, "c12", false); err != nil {
		t.Fatalf("second commit: %v", err)
	}
	wantReason(t, w.commit(e, w.alice, 1, 3, "c13", false), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", "messages_commits_per_conversation_daily")
	if err := w.commit(e, w.bob, 1, 3, "b13", false); err != nil {
		t.Errorf("bob's commit on the same conversation: %v", err)
	}
	carol := e.user(t)
	for _, id := range []string{w.conv, "0123456789abcdef0123456789abcdef"} {
		stranger := w
		stranger.conv = id
		for i := range 2 {
			if err := stranger.commit(e, carol, 1, 4, "x", false); connect.CodeOf(err) != connect.CodeNotFound {
				t.Fatalf("stranger's commit %d on %s = %v, want NOT_FOUND", i+1, id[:8], err)
			}
		}
		wantReason(t, stranger.commit(e, carol, 1, 4, "x", false), connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", "messages_commits_per_conversation_daily")
	}
}
