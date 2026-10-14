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
