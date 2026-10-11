package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func deployedEnv(t *testing.T, env string) {
	t.Helper()
	clearEnv(t)
	t.Setenv("ENV", env)
	t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-x")
	t.Setenv("CURSOR_HMAC_KEY", "x-secret")
	t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
	t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
}

// TestLoad_Notifications (ADR-0017 D7, D9): the flag is off in every environment by default, the topic and the
// per-uid device cap have defaults, and inline delivery never leaves ENV=local.
func TestLoad_Notifications(t *testing.T) {
	for _, env := range []string{"local", "dev", "prod"} {
		t.Run("defaults "+env, func(t *testing.T) {
			if env == "local" {
				clearEnv(t)
			} else {
				deployedEnv(t, env)
			}
			cfg, err := Load()
			if err != nil {
				t.Fatal(err)
			}
			if cfg.FeatureNotifications.Mode != flags.Off || cfg.FeatureNotifications.Name != "notifications" {
				t.Errorf("flag = %+v, want notifications off", cfg.FeatureNotifications)
			}
			if cfg.NotificationsTopic != "notifications-fanout" || cfg.RateLimit.NotificationDevicesCallsPerDay != 50 {
				t.Errorf("topic %q cap %d", cfg.NotificationsTopic, cfg.RateLimit.NotificationDevicesCallsPerDay)
			}
			want := "pubsub"
			if env == "local" {
				want = "inline"
			}
			if cfg.NotificationsDelivery != want {
				t.Errorf("delivery = %q, want %q", cfg.NotificationsDelivery, want)
			}
		})
	}

	t.Run("inline delivery is refused outside local", func(t *testing.T) {
		deployedEnv(t, "prod")
		t.Setenv("NOTIFICATIONS_DELIVERY", "inline")
		if _, err := Load(); err == nil {
			t.Fatal("inline delivery in prod must fail startup (it runs after the response)")
		}
	})
	t.Run("unknown delivery mode", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("NOTIFICATIONS_DELIVERY", "carrier-pigeon")
		if _, err := Load(); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("pubsub is allowed locally", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("NOTIFICATIONS_DELIVERY", "pubsub")
		cfg, err := Load()
		if err != nil || cfg.NotificationsDelivery != "pubsub" {
			t.Fatalf("cfg = %q, err = %v", cfg.NotificationsDelivery, err)
		}
	})
	t.Run("the device cap must be positive", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("NOTIFICATION_DEVICES_CALLS_PER_DAY", "0")
		if _, err := Load(); err == nil {
			t.Fatal("a zero cap must be a startup error")
		}
	})
	t.Run("rollout modes parse", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("FEATURE_NOTIFICATIONS", "percent")
		t.Setenv("FEATURE_NOTIFICATIONS_PERCENT", "25")
		cfg, err := Load()
		if err != nil || cfg.FeatureNotifications.Mode != flags.Percent || cfg.FeatureNotifications.Percent != 25 {
			t.Fatalf("flag = %+v, err = %v", cfg.FeatureNotifications, err)
		}
	})
}
