package apiserver

import (
	"context"
	"testing"
	"time"

	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

type recordingEmitter struct{ events []notifications.Event }

func (r *recordingEmitter) Emit(_ context.Context, e notifications.Event) error {
	r.events = append(r.events, e)
	return nil
}

func TestFollowNotifier(t *testing.T) {
	at := time.Date(2026, 10, 10, 1, 2, 3, 0, time.UTC)
	em := &recordingEmitter{}
	slot := &emitterSlot{em: em}
	followNotifier{slot: slot}.Followed(context.Background(), "alice", "bob", at)
	if len(em.events) != 1 {
		t.Fatalf("events = %+v", em.events)
	}
	got := em.events[0]
	if got.Type != notifications.TypeFollow || got.ActorID != "alice" || len(got.RecipientIDs) != 1 || got.RecipientIDs[0] != "bob" || !got.At.Equal(at) {
		t.Errorf("event = %+v", got)
	}
	// An unbound slot (producers run before Build binds it) must drop, not panic.
	followNotifier{slot: &emitterSlot{}}.Followed(context.Background(), "alice", "bob", at)
}

func TestPostNotifier(t *testing.T) {
	at := time.Date(2026, 10, 10, 1, 2, 3, 0, time.UTC)
	tests := []struct {
		name string
		post *posts.Post
		want []string // nil = no event
	}{
		{"no mentions", &posts.Post{ID: "1000000000000000001", AuthorID: "alice"}, nil},
		{"nil post", nil, nil},
		{"two mentions", &posts.Post{ID: "1000000000000000001", AuthorID: "alice", CreatedAt: at,
			Mentions: []posts.Mention{{UserID: "bob", Handle: "bob"}, {UserID: "carol", Handle: "carol"}}}, []string{"bob", "carol"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			em := &recordingEmitter{}
			n := postNotifier{slot: &emitterSlot{em: em}}
			n.Created(context.Background(), tt.post)
			n.Deleted(context.Background(), "1", "alice") // never emits
			if tt.want == nil {
				if len(em.events) != 0 {
					t.Fatalf("events = %+v", em.events)
				}
				return
			}
			if len(em.events) != 1 {
				t.Fatalf("events = %+v", em.events)
			}
			e := em.events[0]
			if e.Type != notifications.TypeMention || e.ActorID != "alice" || e.PostID != tt.post.ID || len(e.RecipientIDs) != len(tt.want) || !e.At.Equal(at) {
				t.Errorf("event = %+v", e)
			}
		})
	}
}

// TestNotificationDeviceCallsAreCapped (ADR-0017 D9): Register and Unregister share one per-uid daily cap.
func TestNotificationDeviceCallsAreCapped(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	reg := rl.DailyCaps[notificationsv1connect.NotificationServiceRegisterDeviceProcedure]
	unreg := rl.DailyCaps[notificationsv1connect.NotificationServiceUnregisterDeviceProcedure]
	if reg.Cap == nil || reg.Name != "notification_devices_daily" || unreg.Name != reg.Name || unreg.Cap != reg.Cap {
		t.Fatalf("daily caps = %+v / %+v, want one shared cap named notification_devices_daily", reg, unreg)
	}
}

// TestNotificationsFlagNameMatchesModule: a drift between the config spec and the name the module checks would
// silently leave the feature off (or on) for everyone.
func TestNotificationsFlagNameMatchesModule(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FeatureNotifications.Name != notifications.FlagName {
		t.Fatalf("config flag name %q != notifications.FlagName %q", cfg.FeatureNotifications.Name, notifications.FlagName)
	}
	if cfg.FeatureNotifications.Mode != "off" {
		t.Errorf("FEATURE_NOTIFICATIONS default = %q, want off", cfg.FeatureNotifications.Mode)
	}
}
