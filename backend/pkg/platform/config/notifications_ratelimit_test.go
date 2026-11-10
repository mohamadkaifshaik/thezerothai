package config

import (
	"strings"
	"testing"
)

// TestLoad_NotificationsListRateLimit pins RATE_LIMIT_NOTIFICATIONS_LIST_PER_MIN: default 30, overridable, and a zero,
// negative or unparseable value fails startup naming the key.
func TestLoad_NotificationsListRateLimit(t *testing.T) {
	const key = "RATE_LIMIT_NOTIFICATIONS_LIST_PER_MIN"
	t.Run("default", func(t *testing.T) {
		clearEnv(t)
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if got := cfg.RateLimit.NotificationsListPerUserPerMinute; got != 30 {
			t.Errorf("NotificationsListPerUserPerMinute = %d, want 30", got)
		}
	})
	t.Run("override", func(t *testing.T) {
		clearEnv(t)
		t.Setenv(key, "12")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if got := cfg.RateLimit.NotificationsListPerUserPerMinute; got != 12 {
			t.Errorf("NotificationsListPerUserPerMinute = %d, want 12", got)
		}
	})
	for _, val := range []string{"0", "-1", "many"} {
		t.Run(key+"="+val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(key, val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), key) {
				t.Errorf("Load() error = %v, want one naming %s", err, key)
			}
		})
	}
}
