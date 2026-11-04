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

// TestLoad_Notifications: the flag is off in every environment by default, the topic has a default, and inline delivery never leaves ENV=local.
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
			if cfg.NotificationsTopic != "notifications-fanout" {
				t.Errorf("topic %q", cfg.NotificationsTopic)
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
	t.Run("the hardening caps default and must be positive", func(t *testing.T) {
		clearEnv(t)
		cfg, err := Load()
		rl := cfg.RateLimit
		if err != nil || rl.NotificationRecipientsPerActorPerDay != 200 || rl.NotificationRecipientsPerNewActorPerDay != 50 || rl.NotificationPushesPerRecipientPerHour != 10 {
			t.Fatalf("caps = %d/%d/%d, err = %v", rl.NotificationRecipientsPerActorPerDay, rl.NotificationRecipientsPerNewActorPerDay, rl.NotificationPushesPerRecipientPerHour, err)
		}
		for _, name := range []string{"NOTIFICATION_RECIPIENTS_PER_ACTOR_PER_DAY", "NOTIFICATION_RECIPIENTS_PER_NEW_ACTOR_PER_DAY", "NOTIFICATION_PUSHES_PER_RECIPIENT_PER_HOUR"} {
			clearEnv(t)
			t.Setenv(name, "0")
			if _, err := Load(); err == nil {
				t.Errorf("%s=0 must be a startup error", name)
			}
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
