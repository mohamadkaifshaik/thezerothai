package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_UITabletFlag: FEATURE_UI_TABLET (client-only, no RPC guard) defaults to off and is overridable.
func TestLoad_UITabletFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureUITablet.Name != "ui_tablet" || cfg.FeatureUITablet.Mode != flags.Off {
		t.Errorf("FeatureUITablet = %+v, want name ui_tablet, mode off", cfg.FeatureUITablet)
	}
	clearEnv(t)
	t.Setenv("FEATURE_UI_TABLET", "on")
	if cfg, err = Load(); err != nil || cfg.FeatureUITablet.Mode != flags.On {
		t.Fatalf("override: %+v err=%v", cfg.FeatureUITablet, err)
	}
	clearEnv(t)
	t.Setenv("FEATURE_UI_TABLET", "bogus")
	if _, err = Load(); err == nil {
		t.Error("an invalid FEATURE_UI_TABLET must fail startup")
	}
}
