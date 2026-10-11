//go:build integration

package e2e

// P6 (docs/plans/notifications.md T8): through apiserver.Build, the real interceptor chain, the real flag registry
// and the in-process (inline) delivery that ENV=local selects. Two accounts; B follows A; A's list shows the follow,
// the unread badge counts it and MarkNotificationsSeen clears it; the device RPCs register and unregister.

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func notifKey(op string) string { return fmt.Sprintf("e2e-notif-%s-%d", op, rand.Int63()) }

func TestE2E_Notifications_FlagOffIsFeatureDisabled(t *testing.T) {
	skipIfNoEmulators(t)
	token, _ := newAnonymousIDToken(t)
	id, url := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.Off}
	})
	if _, err := id.CreateProfile(context.Background(), authedRequest(token, &identityv1.CreateProfileRequest{
		IdempotencyKey: notifKey("profile"), Handle: uniqueHandle("nf"), DisplayName: "Flag Off",
	})); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	client := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, url)
	_, err := client.ListNotifications(context.Background(), authedRequest(token, &notificationsv1.ListNotificationsRequest{}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	_, err = client.RegisterDevice(context.Background(), authedRequest(token, &notificationsv1.RegisterDeviceRequest{
		IdempotencyKey: notifKey("reg"), DeviceId: "device-0123456789ab", FcmToken: "tok", Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID,
	}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
}

func TestE2E_Notifications_FollowFlow(t *testing.T) {
	skipIfNoEmulators(t)
	ctx := context.Background()
	id, url := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
		cfg.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
	})
	create := func(label string) (token, uid, handle string) {
		token, uid = newAnonymousIDToken(t)
		handle = uniqueHandle("nf" + label)
		if _, err := id.CreateProfile(ctx, authedRequest(token, &identityv1.CreateProfileRequest{
			IdempotencyKey: notifKey("profile-" + label), Handle: handle, DisplayName: "Notif " + label,
		})); err != nil {
			t.Fatalf("CreateProfile(%s): %v", label, err)
		}
		return token, uid, handle
	}
	tokenA, uidA, _ := create("a")
	tokenB, uidB, handleB := create("b")
	graph := graphv1connect.NewGraphServiceClient(http.DefaultClient, url)
	notifs := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, url)

	// Empty inbox first: 0 rows, a since token for the next refresh.
	first, err := notifs.ListNotifications(ctx, authedRequest(tokenA, &notificationsv1.ListNotificationsRequest{}))
	if err != nil {
		t.Fatalf("ListNotifications(empty): %v", err)
	}
	if len(first.Msg.GetNotifications()) != 0 || first.Msg.GetSinceToken() == "" {
		t.Fatalf("empty inbox = %+v", first.Msg)
	}

	// B follows A -> A gets a follow notification (delivered in-process in ENV=local).
	if _, err := graph.Follow(ctx, authedRequest(tokenB, &graphv1.FollowRequest{IdempotencyKey: notifKey("follow"), UserId: uidA})); err != nil {
		t.Fatalf("Follow(B->A): %v", err)
	}
	var got *notificationsv1.Notification
	deadline := time.Now().Add(5 * time.Second)
	for got == nil {
		res, err := notifs.ListNotifications(ctx, authedRequest(tokenA, &notificationsv1.ListNotificationsRequest{SinceToken: first.Msg.GetSinceToken()}))
		if err != nil {
			t.Fatalf("ListNotifications(since): %v", err)
		}
		if len(res.Msg.GetNotifications()) > 0 {
			got = res.Msg.GetNotifications()[0]
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no follow notification within 5 s")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if got.GetType() != notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW || got.GetActor().GetUserId() != uidB ||
		got.GetActor().GetHandle() != handleB || got.GetActorCount() != 1 || got.GetId() != "follow_"+uidB {
		t.Fatalf("notification = %+v", got)
	}

	// The badge (GetMe) counts it; MarkNotificationsSeen clears it and the next GetMe reads the new watermark.
	me, err := id.GetMe(ctx, authedRequest(tokenA, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	if n := me.Msg.GetUnreadNotificationCount(); n != 1 {
		t.Errorf("unread = %d, want 1", n)
	}
	seen, err := notifs.MarkNotificationsSeen(ctx, authedRequest(tokenA, &notificationsv1.MarkNotificationsSeenRequest{IdempotencyKey: notifKey("seen")}))
	if err != nil || seen.Msg.GetSeenAt() == nil {
		t.Fatalf("MarkNotificationsSeen: %v %+v", err, seen)
	}
	me, err = id.GetMe(ctx, authedRequest(tokenA, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatal(err)
	}
	if n := me.Msg.GetUnreadNotificationCount(); n != 0 {
		t.Errorf("unread after mark seen = %d, want 0", n)
	}
	page, err := notifs.ListNotifications(ctx, authedRequest(tokenA, &notificationsv1.ListNotificationsRequest{}))
	if err != nil || page.Msg.GetSeenAt() == nil || len(page.Msg.GetNotifications()) != 1 {
		t.Fatalf("list after seen: %v %+v", err, page)
	}

	// A foreign cursor is INVALID_ARGUMENT.
	_, err = notifs.ListNotifications(ctx, authedRequest(tokenB, &notificationsv1.ListNotificationsRequest{SinceToken: first.Msg.GetSinceToken()}))
	assertCode(t, err, connect.CodeInvalidArgument)

	// Devices: register is idempotent, platform web is rejected, unregister is idempotent.
	reg := &notificationsv1.RegisterDeviceRequest{
		IdempotencyKey: notifKey("reg"), DeviceId: "device-0123456789ab", FcmToken: "fcm-token-for-e2e", Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_IOS,
	}
	for i := 0; i < 2; i++ {
		if _, err := notifs.RegisterDevice(ctx, authedRequest(tokenA, reg)); err != nil {
			t.Fatalf("RegisterDevice #%d: %v", i, err)
		}
	}
	_, err = notifs.RegisterDevice(ctx, authedRequest(tokenA, &notificationsv1.RegisterDeviceRequest{
		IdempotencyKey: notifKey("reg2"), DeviceId: "device-0123456789ac", FcmToken: "x", Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_UNSPECIFIED,
	}))
	assertCode(t, err, connect.CodeInvalidArgument)
	for i := 0; i < 2; i++ {
		if _, err := notifs.UnregisterDevice(ctx, authedRequest(tokenA, &notificationsv1.UnregisterDeviceRequest{
			IdempotencyKey: notifKey("unreg"), DeviceId: "device-0123456789ab",
		})); err != nil {
			t.Fatalf("UnregisterDevice #%d: %v", i, err)
		}
	}
}
