package config

import (
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_PrivacyDefaults pins every ADR-0025 default: the toggle quota, the cap, the stale window, the Respond bucket
// and the flag (off).
func TestLoad_PrivacyDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Quota.PrivacyTogglesPerDay != 4 {
		t.Errorf("PrivacyTogglesPerDay = %d, want 4", cfg.Quota.PrivacyTogglesPerDay)
	}
	if cfg.Privacy.ProtectedAuthorsMax != 20000 || cfg.Privacy.ProtectedSetMaxStale != 10*time.Minute {
		t.Errorf("Privacy = %+v, want 20000 and 10m", cfg.Privacy)
	}
	if cfg.RateLimit.FollowRequestsRespondPerUserPerMinute != 60 {
		t.Errorf("respond bucket = %d, want 60", cfg.RateLimit.FollowRequestsRespondPerUserPerMinute)
	}
	if cfg.FeaturePrivateAccounts.Name != "private_accounts" || cfg.FeaturePrivateAccounts.Mode != flags.Off {
		t.Errorf("FeaturePrivateAccounts = %+v, want name private_accounts, mode off", cfg.FeaturePrivateAccounts)
	}
	if got := flags.NewRegistry(cfg.FeaturePrivateAccounts).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}
}

// TestLoad_PrivacyOverridesAndValidation: every key is overridable, an out-of-range or unparseable value fails startup
// naming the key, and the flag appears in enabled_features only for allowlisted uids.
func TestLoad_PrivacyOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("QUOTA_PRIVACY_TOGGLES_PER_DAY", "2")
		t.Setenv("PROTECTED_AUTHORS_MAX", "2")
		t.Setenv("PROTECTED_SET_MAX_STALE", "90s")
		t.Setenv("RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", "7")
		t.Setenv("FEATURE_PRIVATE_ACCOUNTS", "allowlist")
		t.Setenv("FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST", "uid-a")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if cfg.Quota.PrivacyTogglesPerDay != 2 || cfg.Privacy.ProtectedAuthorsMax != 2 ||
			cfg.Privacy.ProtectedSetMaxStale != 90*time.Second || cfg.RateLimit.FollowRequestsRespondPerUserPerMinute != 7 {
			t.Errorf("overrides not applied: %+v %+v", cfg.Quota.PrivacyTogglesPerDay, cfg.Privacy)
		}
		reg := flags.NewRegistry(cfg.FeaturePrivateAccounts)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "private_accounts" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [private_accounts]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})
	bad := []struct{ key, val string }{
		{"QUOTA_PRIVACY_TOGGLES_PER_DAY", "0"},
		{"QUOTA_PRIVACY_TOGGLES_PER_DAY", "-1"},
		{"QUOTA_PRIVACY_TOGGLES_PER_DAY", "x"},
		{"PROTECTED_AUTHORS_MAX", "0"},
		{"PROTECTED_AUTHORS_MAX", "20001"},
		{"PROTECTED_AUTHORS_MAX", "x"},
		{"PROTECTED_SET_MAX_STALE", "0s"},
		{"PROTECTED_SET_MAX_STALE", "61m"},
		{"PROTECTED_SET_MAX_STALE", "soon"},
		{"RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", "0"},
		{"RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", "x"},
		{"FEATURE_PRIVATE_ACCOUNTS", "maybe"},
		{"FEATURE_PRIVATE_ACCOUNTS_PERCENT", "101"},
	}
	for _, b := range bad {
		t.Run(b.key+"="+b.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(b.key, b.val)
			_, err := Load()
			if err == nil {
				t.Fatalf("Load() with %s=%s succeeded, want a startup error", b.key, b.val)
			}
			if !strings.Contains(err.Error(), strings.TrimSuffix(b.key, "_PERCENT")) {
				t.Errorf("error %q does not name %s", err, b.key)
			}
		})
	}
}
