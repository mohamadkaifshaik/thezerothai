//go:build integration

package apiserver

// Lane D PR 5 over the real Build chain (Firestore and Auth emulators): a REMOTE removal with device_sign_out on for the
// remover cuts the other sessions AND (removal-server design Q8) gives the sessions after the cut a fresh
// messages_commits_daily counter, so the thief's drain before the cut does not block the owner's commits, AND (Q9) drops
// the account's push registrations, so the lost phone stops receiving notifications.

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"

	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestSessionCutChain_CapsFreshAndPushDropped(t *testing.T) {
	ctx := context.Background()
	skipIfNoEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	uid, email, thief := passwordAccount(t, cfg.ProjectID)
	const daily = 2
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
		c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
		c.RateLimit.MessagesCommitsPerDay = daily
		c.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	})
	e.createProfile(t, thief.idToken)
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	const lostDevice = "caps-cut-device-lost01"
	if _, err := keysClient.RegisterKeyDevice(ctx, authed(thief.idToken, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("caps-cut-reg"), DeviceId: lostDevice, SignaturePublicKey: bytes.Repeat([]byte{9}, 32)})); err != nil {
		t.Fatalf("register the lost device: %v", err)
	}
	commit := func(tok string) error {
		_, err := e.msg.CommitConversation(ctx, authed(tok, &messagingv1.CommitConversationRequest{IdempotencyKey: contractKey("caps-cut-commit")}))
		return err
	}

	// The thief drains the daily commit cap before the cut.
	for i := range daily {
		if err := commit(thief.idToken); connect.CodeOf(err) == connect.CodeResourceExhausted {
			t.Fatalf("thief commit %d capped early: %v", i+1, err)
		}
	}
	wantCapRefusal(t, commit(thief.idToken), messagesCommitsDailyName)

	// Two push registrations of the account (what RegisterPushDevice stores), and one of another account.
	notif := notifications.NewFirestoreRepo(e.fs)
	tokens := []string{fmt.Sprintf("tok-caps-cut-%s-1", uid), fmt.Sprintf("tok-caps-cut-%s-2", uid)}
	for i, tok := range tokens {
		if err := notif.RegisterDevice(ctx, uid, notifications.Device{ID: fmt.Sprintf("push-device-cut-%04d", i), Token: tok, Platform: notifications.PlatformAndroid}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	_, otherUID := mintToken(t, "")
	otherTok := fmt.Sprintf("tok-caps-cut-%s-other", otherUID)
	if err := notif.RegisterDevice(ctx, otherUID, notifications.Device{ID: "push-device-cut-other", Token: otherTok, Platform: notifications.PlatformIOS}, time.Now()); err != nil {
		t.Fatal(err)
	}

	// The owner signs in again: before the removal there is no cut, so the owner shares the thief's spent counter.
	owner := signInAfter(t, email, thief.authTime)
	wantCapRefusal(t, commit(owner.idToken), messagesCommitsDailyName)

	rm, err := keysClient.RemoveKeyDevice(ctx, authed(owner.idToken, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("caps-cut-rm"), DeviceId: lostDevice, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
	if err != nil || !rm.Msg.GetOtherSessionsEnded() {
		t.Fatalf("REMOTE removal = %v, %v; want other_sessions_ended", rm, err)
	}

	// Q9: the account's push registrations are gone; the other account's stay.
	devs, err := notif.Devices(ctx, uid, 10)
	if err != nil || len(devs) != 0 {
		t.Fatalf("devices after the cut = %d, %v; want 0", len(devs), err)
	}
	for _, tok := range tokens {
		if s, err := e.fs.Doc("deviceTokens/" + notifications.TokenKey(tok)).Get(ctx); err == nil && s.Exists() {
			t.Error("a token entry of the account is still there")
		}
	}
	if devs, err := notif.Devices(ctx, otherUID, 10); err != nil || len(devs) != 1 {
		t.Fatalf("other account's devices = %d, %v; want 1", len(devs), err)
	}
	if s, err := e.fs.Doc("deviceTokens/" + notifications.TokenKey(otherTok)).Get(ctx); err != nil || !s.Exists() {
		t.Fatalf("the other account's token entry was deleted: %v", err)
	}

	// Q8: the thief is cut; the owner's session draws on a fresh counter, which caps in turn.
	wantSessionEnded(t, "the thief's commit after the cut", commit(thief.idToken))
	for i := range daily {
		if err := commit(owner.idToken); connect.CodeOf(err) == connect.CodeResourceExhausted || connect.CodeOf(err) == connect.CodeUnauthenticated {
			t.Fatalf("owner commit %d after the cut = %v; want a fresh counter", i+1, err)
		}
	}
	wantCapRefusal(t, commit(owner.idToken), messagesCommitsDailyName)
}
