package apiserver

import (
	"context"
	"strings"
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
		{"stored visibility is ignored (ADR-0025 D2)", &posts.Post{ID: "1000000000000000001", AuthorID: "alice", Visibility: posts.VisibilityFollowers, CreatedAt: at,
			Mentions: []posts.Mention{{UserID: "bob", Handle: "bob"}}}, []string{"bob"}},
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

// TestPostNotifierReplies (ADR-0017 T10): a reply notifies the parent author; replying to yourself emits nothing; a
// mention of the parent author is folded into the reply row (precedence: reply beats mention) while other mentions
// still get their own event; a non-public reply and a post without a known parent author emit nothing for the reply.
func TestPostNotifierReplies(t *testing.T) {
	at := time.Date(2026, 10, 18, 1, 2, 3, 0, time.UTC)
	reply := func(mut func(*posts.Post)) *posts.Post {
		p := &posts.Post{ID: "1000000000000000002", AuthorID: "alice", Kind: posts.KindReply, IsReply: true,
			ReplyToID: "1000000000000000001", ReplyToAuthorID: "bob", CreatedAt: at}
		if mut != nil {
			mut(p)
		}
		return p
	}
	type ev struct {
		typ  notifications.Type
		recv []string
	}
	tests := []struct {
		name string
		post *posts.Post
		want []ev
	}{
		{"reply notifies the parent author", reply(nil), []ev{{notifications.TypeReply, []string{"bob"}}}},
		{"reply to own post emits nothing", reply(func(p *posts.Post) { p.ReplyToAuthorID = "alice" }), nil},
		{"unknown parent author emits nothing", reply(func(p *posts.Post) { p.ReplyToAuthorID = "" }), nil},
		{"stored visibility is ignored", reply(func(p *posts.Post) { p.Visibility = posts.VisibilityFollowers }), []ev{{notifications.TypeReply, []string{"bob"}}}},
		{"mention of the parent author collapses into the reply", reply(func(p *posts.Post) {
			p.Mentions = []posts.Mention{{UserID: "bob", Handle: "bob"}}
		}), []ev{{notifications.TypeReply, []string{"bob"}}}},
		{"other mentions still notify", reply(func(p *posts.Post) {
			p.Mentions = []posts.Mention{{UserID: "bob", Handle: "bob"}, {UserID: "carol", Handle: "carol"}}
		}), []ev{{notifications.TypeReply, []string{"bob"}}, {notifications.TypeMention, []string{"carol"}}}},
		{"self-reply still mentions others", reply(func(p *posts.Post) {
			p.ReplyToAuthorID = "alice"
			p.Mentions = []posts.Mention{{UserID: "carol", Handle: "carol"}}
		}), []ev{{notifications.TypeMention, []string{"carol"}}}},
		{"a plain post is not a reply", &posts.Post{ID: "1000000000000000003", AuthorID: "alice", ReplyToAuthorID: "bob"}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			em := &recordingEmitter{}
			postNotifier{slot: &emitterSlot{em: em}}.Created(context.Background(), tt.post)
			if len(em.events) != len(tt.want) {
				t.Fatalf("events = %+v, want %d", em.events, len(tt.want))
			}
			for i, w := range tt.want {
				g := em.events[i]
				if g.Type != w.typ || g.ActorID != "alice" || g.PostID != tt.post.ID || !g.At.Equal(at) || strings.Join(g.RecipientIDs, ",") != strings.Join(w.recv, ",") {
					t.Errorf("event %d = %+v, want %v", i, g, w)
				}
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

// TestNotificationSeenHasItsOwnDailyCap: MarkNotificationsSeen is called on every tab focus; it must not share
// (and exhaust) the 50/day device-registration cap.
func TestNotificationSeenHasItsOwnDailyCap(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	seen := rl.DailyCaps[notificationsv1connect.NotificationServiceMarkNotificationsSeenProcedure]
	reg := rl.DailyCaps[notificationsv1connect.NotificationServiceRegisterDeviceProcedure]
	if seen.Cap == nil || seen.Name != "notification_seen_daily" || seen.Cap == reg.Cap {
		t.Fatalf("daily caps = %+v / %+v, want a separate cap named notification_seen_daily", seen, reg)
	}
}

func TestAccountAges(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	a := newAccountAges(24 * time.Hour)
	a.now = func() time.Time { return now }
	a.Record("young", now.Add(-time.Hour))
	a.Record("old", now.Add(-48*time.Hour))
	a.Record("zero", time.Time{})
	tests := []struct {
		uid               string
		wantNew, wantSeen bool
	}{
		{"young", true, true},
		{"old", false, true},
		{"zero", false, false},
		{"stranger", false, false},
	}
	for _, tt := range tests {
		if gotNew, gotKnown := a.IsNew(tt.uid); gotNew != tt.wantNew || gotKnown != tt.wantSeen {
			t.Errorf("IsNew(%q) = %v, %v; want %v, %v", tt.uid, gotNew, gotKnown, tt.wantNew, tt.wantSeen)
		}
	}
	now = now.Add(24 * time.Hour) // the young account ages out of the tier on time
	if gotNew, _ := a.IsNew("young"); gotNew {
		t.Error("young account must age out")
	}
}

// TestFollowNotifierRequestTypes (ADR-0025 D10): a request notifies the target with the requester as actor; an accept
// notifies the requester with the target as actor.
func TestFollowNotifierRequestTypes(t *testing.T) {
	at := time.Date(2026, 10, 28, 1, 2, 3, 0, time.UTC)
	em := &recordingEmitter{}
	n := followNotifier{slot: &emitterSlot{em: em}}
	n.FollowRequested(context.Background(), "alice", "pat", at)
	n.FollowRequestAccepted(context.Background(), "pat", "alice", at)
	if len(em.events) != 2 {
		t.Fatalf("events = %+v", em.events)
	}
	req, acc := em.events[0], em.events[1]
	if req.Type != notifications.TypeFollowRequest || req.ActorID != "alice" || len(req.RecipientIDs) != 1 || req.RecipientIDs[0] != "pat" || !req.At.Equal(at) || req.PostID != "" {
		t.Errorf("request event = %+v", req)
	}
	if acc.Type != notifications.TypeFollowAccepted || acc.ActorID != "pat" || len(acc.RecipientIDs) != 1 || acc.RecipientIDs[0] != "alice" || !acc.At.Equal(at) {
		t.Errorf("accept event = %+v", acc)
	}
	n2 := followNotifier{slot: &emitterSlot{}} // an unbound slot drops, never panics
	n2.FollowRequested(context.Background(), "alice", "pat", at)
	n2.FollowRequestAccepted(context.Background(), "pat", "alice", at)
}
