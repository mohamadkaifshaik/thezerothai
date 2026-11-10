package identity

import (
	"context"
	"errors"
	"testing"
	"time"
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
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithNotificationBadge(badge)).(*service)
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

// A failed badge fails GetMe, as a failed count did before; nothing is cached, so the next GetMe asks again, and the
// raw count is never served in its place.
func TestGetMe_NotificationBadgeErrorIsNotCached(t *testing.T) {
	repo := newFakeRepo()
	boom := errors.New("graph down")
	badge := &fakeNotificationBadge{err: boom}
	svc := New(repo, NewCache(time.Minute), 7*24*time.Hour, WithNotificationBadge(badge)).(*service)
	if _, err := svc.CreateProfile(context.Background(), "uid-1", validKey, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	repo.unread["uid-1"] = 5
	if _, err := svc.GetMe(context.Background(), "uid-1"); !errors.Is(err, boom) {
		t.Fatalf("GetMe err = %v, want the badge error", err)
	}
	badge.err, badge.n = nil, 1
	got, err := svc.GetMe(context.Background(), "uid-1")
	if err != nil || got.UnreadNotificationCount != 1 || badge.calls != 2 {
		t.Fatalf("GetMe after recovery = %d, %v (calls %d); want 1 from a fresh call", got.UnreadNotificationCount, err, badge.calls)
	}
}
