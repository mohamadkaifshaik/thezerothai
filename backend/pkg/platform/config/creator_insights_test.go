package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_CreatorInsights (F2): FEATURE_CREATOR_INSIGHTS defaults off with the wire name creator_insights, and
// RATE_LIMIT_CREATOR_INSIGHTS_PER_MIN defaults to 10, is overridable, and a zero, negative or unparseable value fails
// startup naming the key.
func TestLoad_CreatorInsights(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureCreatorInsights.Mode != flags.Off || cfg.FeatureCreatorInsights.Name != "creator_insights" {
		t.Errorf("FeatureCreatorInsights = %+v, want off with wire name creator_insights", cfg.FeatureCreatorInsights)
	}
	if got := cfg.RateLimit.CreatorInsightsPerUserPerMinute; got != 10 {
		t.Errorf("CreatorInsightsPerUserPerMinute = %d, want 10", got)
	}

	clearEnv(t)
	t.Setenv("FEATURE_CREATOR_INSIGHTS", "on")
	t.Setenv("RATE_LIMIT_CREATOR_INSIGHTS_PER_MIN", "4")
	if cfg, err = Load(); err != nil {
		t.Fatalf("Load() override error = %v", err)
	}
	if cfg.FeatureCreatorInsights.Mode != flags.On || cfg.RateLimit.CreatorInsightsPerUserPerMinute != 4 {
		t.Errorf("override: mode %q limit %d, want on and 4", cfg.FeatureCreatorInsights.Mode, cfg.RateLimit.CreatorInsightsPerUserPerMinute)
	}

	const key = "RATE_LIMIT_CREATOR_INSIGHTS_PER_MIN"
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
