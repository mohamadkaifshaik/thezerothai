//go:build integration

package apiserver

import (
	"context"
	"net/http"
	"testing"
	"time"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestNotificationBadgeChain_GetMeSkipsHiddenRows proves the wiring: GetMe's unread_notification_count goes through
// notifications.UnreadBadge (Build passes it to identity.WithNotificationBadge), so rows whose actor the caller blocked
// or muted are not counted. The raw count() GetMe used before would answer 3 here.
func TestNotificationBadgeChain_GetMeSkipsHiddenRows(t *testing.T) {
	ctx := context.Background()
	e := newChain(t, func(c *config.Config) {
		c.FeatureGraph = flags.Spec{Name: "graph", Mode: flags.On}
		c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
	})
	gr := graphv1connect.NewGraphServiceClient(http.DefaultClient, e.url)
	mine, me := mintToken(t, "")
	e.createProfile(t, mine)
	blockedTok, blocked := mintToken(t, "")
	e.createProfile(t, blockedTok)
	mutedTok, muted := mintToken(t, "")
	e.createProfile(t, mutedTok)
	friendTok, friend := mintToken(t, "")
	e.createProfile(t, friendTok)

	if _, err := gr.Block(ctx, authed(mine, &graphv1.BlockRequest{IdempotencyKey: contractKey("badge-block"), UserId: blocked})); err != nil {
		t.Fatalf("Block: %v", err)
	}
	if _, err := gr.Mute(ctx, authed(mine, &graphv1.MuteRequest{IdempotencyKey: contractKey("badge-mute"), UserId: muted})); err != nil {
		t.Fatalf("Mute: %v", err)
	}
	// Rows written before the block and mute took effect (the fan-out checks at write time; the badge at read time).
	now := time.Now().UTC()
	for i, actor := range []string{blocked, muted, friend} {
		at := now.Add(time.Duration(i) * time.Millisecond)
		if _, err := e.fs.Collection("users").Doc(me).Collection("notifications").Doc("follow_"+actor).Set(ctx, map[string]any{
			"type": "follow", "actor": map[string]any{"userId": actor, "handle": "h", "displayName": "d", "verified": false},
			"actorIds": []string{actor}, "actorCount": 1, "createdAt": at, "expireAt": at.Add(90 * 24 * time.Hour),
		}); err != nil {
			t.Fatalf("seed row: %v", err)
		}
	}
	got, err := e.identity.GetMe(ctx, authed(mine, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if n := got.Msg.GetUnreadNotificationCount(); n != 1 {
		t.Errorf("unread_notification_count = %d, want 1 (only the friend's row; blocked and muted rows hidden)", n)
	}
	// A user with no graph doc (an empty snapshot, not an error) and no rows still gets GetMe, with a badge of 0: the
	// badge's snapshot read must not break the bootstrap call. The doc is removed here, before anything on this server
	// has read (and cached) friend's snapshot.
	if _, err := e.fs.Collection("graph").Doc(friend).Delete(ctx); err != nil {
		t.Fatalf("delete graph doc: %v", err)
	}
	fresh, err := e.identity.GetMe(ctx, authed(friendTok, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe for a user with no graph doc: %v", err)
	}
	if n := fresh.Msg.GetUnreadNotificationCount(); n != 0 {
		t.Errorf("fresh user's unread_notification_count = %d, want 0", n)
	}
}
