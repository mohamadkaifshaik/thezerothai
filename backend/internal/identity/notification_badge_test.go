package identity

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fakeNotificationBadge answers the filtered count the notifications module computes.
type fakeNotificationBadge struct {
	n     int64
	err   error
	calls int
	since []time.Time
}

func (f *fakeNotificationBadge) UnreadNotifications(_ context.Context, _ string, since time.Time) (int64, error) {
	f.calls++
	f.since = append(f.since, since)
	return f.n, f.err
}

// TestGetMe_UnreadComesFromTheNotificationBadge: with the badge wired, GetMe's unread_notification_count is the
// notifications module's filtered count (rows hidden by block, mute or blocked-by excluded), never identity's raw
// count() of the collection, which also counts the hidden rows. It is cached 30 s like before.
func TestGetMe_UnreadComesFromTheNotificationBadge(t *testing.T) {
	repo := newFakeRepo()
	badge := &fakeNotificationBadge{n: 2}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithNotificationBadge(badge, nil)).(*service)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	seen := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	p := repo.profiles["uid-1"]
	p.NotificationsSeenAt = seen
	repo.profiles["uid-1"] = p
	svc.Forget("uid-1")
	repo.unread["uid-1"] = 5 // the raw count, hidden rows included

	got, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if got.UnreadNotificationCount != 2 {
		t.Fatalf("unread = %d, want the badge's 2 (the raw count is 5)", got.UnreadNotificationCount)
	}
	if badge.calls != 1 || !badge.since[0].Equal(seen) {
		t.Fatalf("badge calls = %d since = %v, want 1 call from notificationsSeenAt %v", badge.calls, badge.since, seen)
	}
	badge.n = 9
	if again, err := svc.GetMe(context.Background(), "uid-1"); err != nil || again.UnreadNotificationCount != 2 || badge.calls != 1 {
		t.Fatalf("second GetMe = %d, %v after %d calls; want the cached 2 and no new call", again.UnreadNotificationCount, err, badge.calls)
	}
}

// M1 (security audit): a failed badge must not fail GetMe, the app's bootstrap call. It answers 0 with a WARN
// unread_notifications_failed carrying only the hashed uid, caches nothing (the next GetMe asks again), and never
// serves the raw count, which would count hidden rows.
func TestGetMe_NotificationBadgeErrorDegradesToZero(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	repo := newFakeRepo()
	badge := &fakeNotificationBadge{err: errors.New("decode users/uid-1/notifications/follow_other-uid")}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithNotificationBadge(badge, log)).(*service)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	repo.unread["uid-1"] = 5 // the raw count: never served in the badge's place
	got, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil || got.UnreadNotificationCount != 0 {
		t.Fatalf("GetMe = %d, %v; want 0 and no error", got.UnreadNotificationCount, err)
	}
	out := buf.String()
	for _, want := range []string{`"msg":"unread_notifications_failed"`, `"level":"WARN"`, `"uid_hash":"` + logger.HashUID("uid-1") + `"`} {
		if !strings.Contains(out, want) {
			t.Errorf("log %q lacks %s", out, want)
		}
	}
	if strings.Contains(out, `"uid-1"`) || strings.Contains(out, "users/uid-1/") {
		t.Errorf("log carries the raw uid: %s", out)
	}
	if _, ok := svc.cache.GetUnreadCount("uid-1"); ok {
		t.Error("a failed badge was cached")
	}
	badge.err, badge.n = nil, 1
	got, err = svc.GetMe(context.Background(), "uid-1")
	if err != nil || got.UnreadNotificationCount != 1 || badge.calls != 2 {
		t.Fatalf("GetMe after recovery = %d, %v (calls %d); want 1 from a fresh call", got.UnreadNotificationCount, err, badge.calls)
	}
}
