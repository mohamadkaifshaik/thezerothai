package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ShellsFlag: FEATURE_SHELLS (client-only, no RPC guard) defaults to off and is overridable.
func TestLoad_ShellsFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureShells.Name != "shells" || cfg.FeatureShells.Mode != flags.Off {
		t.Errorf("FeatureShells = %+v, want name shells, mode off", cfg.FeatureShells)
	}
	clearEnv(t)
	t.Setenv("FEATURE_SHELLS", "on")
	if cfg, err = Load(); err != nil || cfg.FeatureShells.Mode != flags.On {
		t.Fatalf("override: %+v err=%v", cfg.FeatureShells, err)
	}
	clearEnv(t)
	t.Setenv("FEATURE_SHELLS", "bogus")
	if _, err = Load(); err == nil {
		t.Error("an invalid FEATURE_SHELLS must fail startup")
	}
}
