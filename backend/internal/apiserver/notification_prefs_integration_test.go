//go:build integration

package apiserver

// F6 over the real Build chain: GetNotificationPrefs and UpdateNotificationPrefs need FEATURE_NOTIFICATIONS and
// FEATURE_NOTIFICATION_PREFS, round-trip the preferences through users/{uid}/settings/notifications, and the account
// eraser removes the document (the lifecycle table row "settings" pins the collection).

import (
	"context"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestNotificationPrefs_FlagOffAnswersFeatureDisabled(t *testing.T) {
	ctx := context.Background()
	e := newChain(t, func(c *config.Config) {
		c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
	})
	nc := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, e.url)
	u := newPrefsUser(t, e)

	_, err := nc.GetNotificationPrefs(ctx, authed(u.token, &notificationsv1.GetNotificationPrefsRequest{}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if d.GetMetadata()["feature"] != "notification_prefs" {
		t.Errorf("metadata = %v, want feature=notification_prefs", d.GetMetadata())
	}
	_, err = nc.UpdateNotificationPrefs(ctx, authed(u.token, &notificationsv1.UpdateNotificationPrefsRequest{
		IdempotencyKey: "np-update-key-0000001", Prefs: &notificationsv1.NotificationPrefs{},
	}))
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	if docExistsAt(t, e, "users/"+u.uid+"/settings/notifications") {
		t.Error("a flag-off call wrote the settings document")
	}
}

func TestNotificationPrefs_RoundTripAndMultiUser(t *testing.T) {
	ctx := context.Background()
	e := newChain(t, func(c *config.Config) {
		c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
		c.FeatureNotificationPrefs = flags.Spec{Name: "notification_prefs", Mode: flags.On}
	})
	nc := notificationsv1connect.NewNotificationServiceClient(http.DefaultClient, e.url)
	a, b := newPrefsUser(t, e), newPrefsUser(t, e)

	got, err := nc.GetNotificationPrefs(ctx, authed(a.token, &notificationsv1.GetNotificationPrefsRequest{}))
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if p := got.Msg.GetPrefs(); !p.GetPlansPush() || !p.GetMentionsRepliesPush() || !p.GetLikesRepostsPush() || !p.GetFollowersPush() || !p.GetMessagesPush() {
		t.Fatalf("default prefs = %v, want everything on", p)
	}
	want := &notificationsv1.NotificationPrefs{PlansPush: true, MentionsRepliesPush: true, FollowersPush: true}
	if _, err := nc.UpdateNotificationPrefs(ctx, authed(a.token, &notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: "np-update-key-0000002", Prefs: want})); err != nil {
		t.Fatalf("Update: %v", err)
	}
	// A repeat (same key and value) succeeds and returns the same value.
	rep, err := nc.UpdateNotificationPrefs(ctx, authed(a.token, &notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: "np-update-key-0000002", Prefs: want}))
	if err != nil || rep.Msg.GetPrefs().GetLikesRepostsPush() || rep.Msg.GetPrefs().GetMessagesPush() {
		t.Fatalf("repeat = %v, %v", rep, err)
	}
	got, err = nc.GetNotificationPrefs(ctx, authed(a.token, &notificationsv1.GetNotificationPrefsRequest{}))
	if err != nil || got.Msg.GetPrefs().GetLikesRepostsPush() || !got.Msg.GetPrefs().GetPlansPush() {
		t.Fatalf("get after update = %v, %v", got, err)
	}
	// Another user still has the defaults.
	other, err := nc.GetNotificationPrefs(ctx, authed(b.token, &notificationsv1.GetNotificationPrefsRequest{}))
	if err != nil || !other.Msg.GetPrefs().GetLikesRepostsPush() {
		t.Fatalf("other user = %v, %v", other, err)
	}
	// Validation.
	_, err = nc.UpdateNotificationPrefs(ctx, authed(a.token, &notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: "np-update-key-0000003"}))
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	_, err = nc.UpdateNotificationPrefs(ctx, authed(a.token, &notificationsv1.UpdateNotificationPrefsRequest{IdempotencyKey: "bad", Prefs: want}))
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if !docExistsAt(t, e, "users/"+a.uid+"/settings/notifications") || docExistsAt(t, e, "users/"+b.uid+"/settings/notifications") {
		t.Error("settings documents are not where the module says they are")
	}
}

type prefsUser struct{ token, uid string }

func newPrefsUser(t *testing.T, e *chainEnv) prefsUser {
	t.Helper()
	token, uid := mintToken(t, "")
	e.createProfile(t, token)
	return prefsUser{token: token, uid: uid}
}

func docExistsAt(t *testing.T, e *chainEnv, path string) bool {
	t.Helper()
	snap, err := e.fs.Doc(path).Get(context.Background())
	return err == nil && snap.Exists()
}
