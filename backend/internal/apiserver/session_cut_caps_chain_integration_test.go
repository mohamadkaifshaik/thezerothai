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

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
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
	mutate := func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
		c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: map[string]struct{}{uid: {}}}
		c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
		c.RateLimit.MessagesCommitsPerDay = daily
		c.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	}
	e := newDMChain(t, mutate)
	e.createProfile(t, thief.idToken)
	// Another instance whose identity cache holds the profile from before the cut (warmed by the thief's GetMe): its cut
	// interceptor serves the stale copy for up to 60 s.
	stale := newDMChain(t, mutate)
	if _, err := stale.identity.GetMe(ctx, authed(thief.idToken, &identityv1.GetMeRequest{})); err != nil {
		t.Fatalf("warm the other instance's cache: %v", err)
	}
	registerPush := func(chain *dmChain, tok, device string) error {
		_, err := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, chain.url).RegisterDevice(ctx, authed(tok, &notificationsv1.RegisterDeviceRequest{
			IdempotencyKey: contractKey("caps-cut-push"), DeviceId: device, FcmToken: fmt.Sprintf("tok-caps-cut-%s-%s", uid, device),
			Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID,
		}))
		return err
	}
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

	// Fix round 1, item 7: on the instance with the stale cache the thief passes the cut interceptor, but RegisterPushDevice
	// reads the cut fresh and refuses, so the registrations the removal dropped stay dropped.
	wantSessionEnded(t, "the thief's RegisterPushDevice on the stale instance", registerPush(stale, thief.idToken, "push-device-thief-01"))
	if devs, err := notif.Devices(ctx, uid, 10); err != nil || len(devs) != 0 {
		t.Fatalf("devices after the thief's attempt = %d, %v; want 0", len(devs), err)
	}
	// The owner's device registers again (its session is from the cut).
	if err := registerPush(e, owner.idToken, "push-device-owner-01"); err != nil {
		t.Fatalf("the owner's RegisterPushDevice: %v", err)
	}
	if devs, err := notif.Devices(ctx, uid, 10); err != nil || len(devs) != 1 {
		t.Fatalf("devices after the owner registers = %d, %v; want 1", len(devs), err)
	}
}

// TestSessionCutChain_CommittedResetAfterCut (fix round 1, code N2): the service caps over Build. Alice spends the reset cap
// with a committed reset, then removes a device of hers REMOTE with device_sign_out on (her own session, whose auth_time is
// the cut, passes it): a committed reset after the cut goes through on fresh reset and per-conversation counters.
func TestSessionCutChain_CommittedResetAfterCut(t *testing.T) {
	ctx := context.Background()
	w := newE2EEWorld(t)
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: w.allow}
		c.FeatureDeviceSignOut = flags.Spec{Name: "device_sign_out", Mode: flags.Allowlist, Allowlist: map[string]struct{}{w.alice.uid: {}}}
		c.RateLimit.MessagesResetsPerDay = 1
		c.RateLimit.MessagesCommitPerUserPerMinute = 1_000_000
	})
	if err := w.commit(e, w.alice, 1, 0, "r1", true); err != nil {
		t.Fatalf("first reset: %v", err)
	}
	wantCapRefusal(t, w.commit(e, w.alice, 2, 0, "r2", true), "messages_resets_daily")

	kc := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	const spare = "reset-cut-spare-device1"
	if _, err := kc.RegisterKeyDevice(ctx, authed(w.alice.token, &keysv1.RegisterKeyDeviceRequest{IdempotencyKey: contractKey("reset-cut-reg"), DeviceId: spare, SignaturePublicKey: bytes.Repeat([]byte{5}, 32)})); err != nil {
		t.Fatalf("register a spare device: %v", err)
	}
	rm, err := kc.RemoveKeyDevice(ctx, authed(w.alice.token, &keysv1.RemoveKeyDeviceRequest{IdempotencyKey: contractKey("reset-cut-rm"), DeviceId: spare, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE}))
	if err != nil || !rm.Msg.GetOtherSessionsEnded() {
		t.Fatalf("REMOTE removal = %v, %v; want other_sessions_ended", rm, err)
	}
	if err := w.commit(e, w.alice, 2, 0, "r-after-cut", true); err != nil {
		t.Fatalf("a committed reset after the cut: %v (the service caps did not start fresh)", err)
	}
	wantCapRefusal(t, w.commit(e, w.alice, 3, 0, "r-again", true), "messages_resets_daily")
}
