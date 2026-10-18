package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_EngagementDefaults locks the ADR-0018 numbers: FEATURE_ENGAGEMENT off, 30 engagement calls/min, 500
// likes/day (100 for new accounts), and that the env vars override them.
func TestLoad_EngagementDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureEngagement.Name != "engagement" || cfg.FeatureEngagement.Mode != flags.Off {
		t.Errorf("FeatureEngagement = %+v, want name engagement, mode off", cfg.FeatureEngagement)
	}
	if cfg.RateLimit.LikesPerUserPerMinute != 30 || cfg.Quota.LikesPerDay != 500 || cfg.Quota.NewAccountLikesPerDay != 100 {
		t.Errorf("engagement limits = %d/min %d/day %d/day-new, want 30/500/100",
			cfg.RateLimit.LikesPerUserPerMinute, cfg.Quota.LikesPerDay, cfg.Quota.NewAccountLikesPerDay)
	}

	clearEnv(t)
	t.Setenv("FEATURE_ENGAGEMENT", "on")
	t.Setenv("QUOTA_LIKES_PER_DAY", "7")
	cfg, err = Load()
	if err != nil || cfg.FeatureEngagement.Mode != flags.On || cfg.Quota.LikesPerDay != 7 {
		t.Fatalf("override: %+v %d err=%v", cfg.FeatureEngagement, cfg.Quota.LikesPerDay, err)
	}
}

// TestLoad_QuotesFlag: FEATURE_QUOTES (quote creation, ADR-0018 amendment 2026-10-18) defaults off, is
// independent of FEATURE_ENGAGEMENT, takes the allowlist and percent like the other flags, and rejects bad values.
func TestLoad_QuotesFlag(t *testing.T) {
	clearEnv(t)
	t.Setenv("FEATURE_ENGAGEMENT", "on")
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureQuotes.Name != "quotes" || cfg.FeatureQuotes.Mode != flags.Off {
		t.Errorf("FeatureQuotes = %+v, want name quotes, mode off even with engagement on", cfg.FeatureQuotes)
	}

	clearEnv(t)
	t.Setenv("FEATURE_ENGAGEMENT", "off")
	t.Setenv("FEATURE_QUOTES", "percent")
	t.Setenv("FEATURE_QUOTES_PERCENT", "25")
	t.Setenv("FEATURE_QUOTES_ALLOWLIST", "u1,u2")
	cfg, err = Load()
	if err != nil || cfg.FeatureQuotes.Mode != flags.Percent || cfg.FeatureQuotes.Percent != 25 || len(cfg.FeatureQuotes.Allowlist) != 2 {
		t.Fatalf("override: %+v err=%v", cfg.FeatureQuotes, err)
	}
	if cfg.FeatureEngagement.Mode != flags.Off {
		t.Errorf("FEATURE_QUOTES must not change FeatureEngagement: %+v", cfg.FeatureEngagement)
	}

	for name, env := range map[string][2]string{
		"bad mode":    {"FEATURE_QUOTES", "bogus"},
		"bad percent": {"FEATURE_QUOTES_PERCENT", "101"},
	} {
		clearEnv(t)
		t.Setenv(env[0], env[1])
		if _, err := Load(); err == nil {
			t.Errorf("%s: %s=%s must fail startup", name, env[0], env[1])
		}
	}
}
