package apiserver

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
)

// TestNotificationsListBucket_IsItsOwn: ListNotifications draws on its own per-user bucket
// (RATE_LIMIT_NOTIFICATIONS_LIST_PER_MIN), not the 60/min default it used to fall back to and not any other procedure's,
// and it has no daily call cap (a read).
func TestNotificationsListBucket_IsItsOwn(t *testing.T) {
	proc := notificationsv1connect.NotificationServiceListNotificationsProcedure
	rl := RateLimitConfig(defaultRateLimitCfg())
	lim := rl.PerProcedure[proc]
	if lim == nil {
		t.Fatalf("%s has no per-procedure limiter (falls back to the default bucket)", proc)
	}
	if lim == rl.Default {
		t.Fatalf("%s must not share the default bucket", proc)
	}
	for p, other := range rl.PerProcedure {
		if p != proc && other == lim {
			t.Errorf("%s shares its bucket with %s", proc, p)
		}
	}
	if _, ok := rl.DailyCaps[proc]; ok {
		t.Errorf("%s must not have a daily call cap", proc)
	}
}

// TestNotificationsListBucket_UsesTheConfiguredRate: the bucket holds the configured burst (n calls) and refuses the next.
func TestNotificationsListBucket_UsesTheConfiguredRate(t *testing.T) {
	proc := notificationsv1connect.NotificationServiceListNotificationsProcedure
	for _, n := range []int{30, 4} {
		cfg := defaultRateLimitCfg()
		cfg.RateLimit.NotificationsListPerUserPerMinute = n
		lim := RateLimitConfig(cfg).PerProcedure[proc]
		if lim == nil {
			t.Fatalf("%s has no per-procedure limiter", proc)
		}
		for i := 0; i < n; i++ {
			if ok, _ := lim.Allow("uid-1"); !ok {
				t.Fatalf("rate %d: call %d refused, want %d allowed", n, i+1, n)
			}
		}
		if ok, _ := lim.Allow("uid-1"); ok {
			t.Errorf("rate %d: call %d allowed, want the bucket empty", n, n+1)
		}
		if ok, _ := lim.Allow("uid-2"); !ok {
			t.Errorf("rate %d: another uid was refused: the bucket must be per user", n)
		}
	}
}
