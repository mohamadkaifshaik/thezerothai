package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_MessagingDefaults pins every ADR-0027 D13 default and the flag (off, wire name messaging).
func TestLoad_MessagingDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.MessagesSendPerUserPerMinute != 20 || rl.MessagesReadPerUserPerMinute != 30 || rl.MessagesSendsPerDay != 300 {
		t.Errorf("message rate limits = %d/%d/%d, want 20/30/300", rl.MessagesSendPerUserPerMinute, rl.MessagesReadPerUserPerMinute, rl.MessagesSendsPerDay)
	}
	if rl := cfg.RateLimit; rl.MessagesMarkReadPerDay != 500 || rl.MessagesMutationsPerDay != 500 {
		t.Errorf("message daily caps (mark read, accept + delete) = %d/%d, want 500/500", rl.MessagesMarkReadPerDay, rl.MessagesMutationsPerDay)
	}
	if q := cfg.Quota; q.DMNewConversationsPerDay != 20 || q.NewAccountDMNewConversationsPerDay != 5 {
		t.Errorf("dm new quota = %d/%d, want 20/5", q.DMNewConversationsPerDay, q.NewAccountDMNewConversationsPerDay)
	}
	if m := cfg.Messaging; m.NewAccountSendsPerDay != 50 || m.RequestMaxUnanswered != 3 || m.PushesPerRecipientPerHour != 20 || m.ConversationCacheEntries != 5000 {
		t.Errorf("messaging config = %+v, want 50/3/20/5000", m)
	}
	if cfg.FeatureMessaging.Name != "messaging" || cfg.FeatureMessaging.Mode != flags.Off {
		t.Errorf("FeatureMessaging = %+v, want name messaging, mode off", cfg.FeatureMessaging)
	}
}

// TestLoad_MessagingOverridesAndValidation: every key is overridable, a zero, negative or unparseable value fails startup
// naming the key, and the flag is listed in enabled_features only for allowlisted uids.
func TestLoad_MessagingOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("RATE_LIMIT_MESSAGES_SEND_PER_MIN", "7")
		t.Setenv("RATE_LIMIT_MESSAGES_READ_PER_MIN", "8")
		t.Setenv("MESSAGES_SENDS_PER_DAY", "9")
		t.Setenv("MESSAGES_MARK_READ_PER_DAY", "11")
		t.Setenv("MESSAGES_MUTATIONS_PER_DAY", "12")
		t.Setenv("MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY", "2")
		t.Setenv("QUOTA_DM_NEW_CONVERSATIONS_PER_DAY", "6")
		t.Setenv("QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY", "1")
		t.Setenv("MESSAGES_REQUEST_MAX_UNANSWERED", "4")
		t.Setenv("MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR", "5")
		t.Setenv("CACHE_MESSAGING_CONVERSATION_ENTRIES", "10")
		t.Setenv("FEATURE_MESSAGING", "allowlist")
		t.Setenv("FEATURE_MESSAGING_ALLOWLIST", "uid-a,uid-b")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if rl := cfg.RateLimit; rl.MessagesSendPerUserPerMinute != 7 || rl.MessagesReadPerUserPerMinute != 8 || rl.MessagesSendsPerDay != 9 {
			t.Errorf("rate limit override = %d/%d/%d", rl.MessagesSendPerUserPerMinute, rl.MessagesReadPerUserPerMinute, rl.MessagesSendsPerDay)
		}
		if rl := cfg.RateLimit; rl.MessagesMarkReadPerDay != 11 || rl.MessagesMutationsPerDay != 12 {
			t.Errorf("daily cap override = %d/%d, want 11/12", rl.MessagesMarkReadPerDay, rl.MessagesMutationsPerDay)
		}
		if q := cfg.Quota; q.DMNewConversationsPerDay != 6 || q.NewAccountDMNewConversationsPerDay != 1 {
			t.Errorf("quota override = %d/%d", q.DMNewConversationsPerDay, q.NewAccountDMNewConversationsPerDay)
		}
		if m := cfg.Messaging; m.NewAccountSendsPerDay != 2 || m.RequestMaxUnanswered != 4 || m.PushesPerRecipientPerHour != 5 || m.ConversationCacheEntries != 10 {
			t.Errorf("messaging override = %+v", m)
		}
		reg := flags.NewRegistry(cfg.FeatureMessaging)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "messaging" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [messaging]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	keys := []string{
		"RATE_LIMIT_MESSAGES_SEND_PER_MIN", "RATE_LIMIT_MESSAGES_READ_PER_MIN", "MESSAGES_SENDS_PER_DAY", "MESSAGES_MARK_READ_PER_DAY", "MESSAGES_MUTATIONS_PER_DAY",
		"MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY", "QUOTA_DM_NEW_CONVERSATIONS_PER_DAY",
		"QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY", "MESSAGES_REQUEST_MAX_UNANSWERED",
		"MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR", "CACHE_MESSAGING_CONVERSATION_ENTRIES",
	}
	for _, key := range keys {
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
	for _, tt := range []struct{ key, val string }{
		{"FEATURE_MESSAGING", "bogus"},
		{"FEATURE_MESSAGING_PERCENT", "101"},
	} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
}
