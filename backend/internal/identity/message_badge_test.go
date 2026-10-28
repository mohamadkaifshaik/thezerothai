package identity

import (
	"context"
	"errors"
	"testing"
	"time"
)

// fakeBadge is a MessageBadge fake (ADR-0027 D10, W7-11).
type fakeBadge struct {
	n     int64
	err   error
	calls int
}

func (f *fakeBadge) UnreadConversations(context.Context, string) (int64, error) {
	f.calls++
	return f.n, f.err
}

func badgeSvc(t *testing.T, enabled []string, b MessageBadge) (*service, *Cache) {
	t.Helper()
	repo := newFakeRepo()
	repo.profiles["u"] = Profile{UserID: "u", Handle: "u", HandleLower: "u", Status: AccountStatusActive}
	c := NewCache(time.Minute)
	opts := []Option{WithFeatureFlags(&fakeFeatureFlags{enabled: enabled})}
	if b != nil {
		opts = append(opts, WithMessageBadge(b, nil))
	}
	return New(repo, c, time.Hour, opts...).(*service), c
}

// W7-11 acceptance: 3 unread -> 3, flag off -> 0 with 0 badge calls, no badge wired -> 0, a failure -> 0 and not cached.
func TestGetMe_UnreadConversationCount(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		enabled   []string
		badge     *fakeBadge
		wired     bool
		want      int64
		wantCalls int
	}{
		{name: "three unread", enabled: []string{"graph", MessagingFlag}, badge: &fakeBadge{n: 3}, wired: true, want: 3, wantCalls: 1},
		{name: "the cap passes through", enabled: []string{MessagingFlag}, badge: &fakeBadge{n: 100}, wired: true, want: 100, wantCalls: 1},
		{name: "messaging off for the caller", enabled: []string{"graph"}, badge: &fakeBadge{n: 3}, wired: true, want: 0, wantCalls: 0},
		{name: "no flags at all", enabled: nil, badge: &fakeBadge{n: 3}, wired: true, want: 0, wantCalls: 0},
		{name: "no badge wired", enabled: []string{MessagingFlag}, badge: &fakeBadge{n: 3}, wired: false, want: 0, wantCalls: 0},
		{name: "count failure leaves the badge at 0", enabled: []string{MessagingFlag}, badge: &fakeBadge{err: errors.New("down")}, wired: true, want: 0, wantCalls: 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var b MessageBadge
			if tt.wired {
				b = tt.badge
			}
			svc, _ := badgeSvc(t, tt.enabled, b)
			got, err := svc.GetMe(context.Background(), "u")
			if err != nil {
				t.Fatalf("GetMe: %v", err)
			}
			if got.UnreadConversationCount != tt.want {
				t.Errorf("count = %d, want %d", got.UnreadConversationCount, tt.want)
			}
			if tt.badge.calls != tt.wantCalls {
				t.Errorf("badge calls = %d, want %d", tt.badge.calls, tt.wantCalls)
			}
		})
	}
}

// Cached 30 s; MessageBadgeCache.Forget (a send or a mark-read on this instance) makes the next GetMe recount and leaves the
// notification count cached; a failure is retried, never cached.
func TestGetMe_UnreadConversationCache(t *testing.T) {
	t.Parallel()
	b := &fakeBadge{n: 3}
	svc, c := badgeSvc(t, []string{MessagingFlag}, b)
	ctx := context.Background()
	get := func() int64 {
		t.Helper()
		r, err := svc.GetMe(ctx, "u")
		if err != nil {
			t.Fatal(err)
		}
		return r.UnreadConversationCount
	}
	first, second := get(), get()
	if first != 3 || second != 3 || b.calls != 1 {
		t.Fatalf("second GetMe inside 30 s must hit the cache: calls = %d", b.calls)
	}
	b.n = 4
	NewMessageBadgeCache(c).Forget("someone-else")
	if get() != 3 || b.calls != 1 {
		t.Fatalf("Forget of another uid must not evict: calls = %d", b.calls)
	}
	NewMessageBadgeCache(c).Forget("u", "peer")
	if got := get(); got != 4 || b.calls != 2 {
		t.Fatalf("after Forget: count = %d calls = %d, want 4 and 2", got, b.calls)
	}
	// A failure is retried on the next call.
	NewMessageBadgeCache(c).Forget("u")
	b.err = errors.New("down")
	if get() != 0 || b.calls != 3 {
		t.Fatalf("failure: calls = %d", b.calls)
	}
	b.err = nil
	if got := get(); got != 4 || b.calls != 4 {
		t.Fatalf("retry after failure: count = %d calls = %d", got, b.calls)
	}
}

// Forget/ForgetUnread of the notification side do not touch the conversation badge's own eviction path in reverse: the
// Directory's Forget evicts the profile and notification count, MessageBadgeCache only the conversation count.
func TestMessageBadgeCache_EvictsOnlyTheConversationCount(t *testing.T) {
	t.Parallel()
	c := NewCache(time.Minute)
	c.SetUnreadCount("u", 7)
	c.SetConversationBadge("u", 2)
	NewMessageBadgeCache(c).Forget("u")
	if _, ok := c.GetConversationBadge("u"); ok {
		t.Error("conversation badge still cached")
	}
	if n, ok := c.GetUnreadCount("u"); !ok || n != 7 {
		t.Errorf("notification count = %d, %v; want it untouched", n, ok)
	}
}
