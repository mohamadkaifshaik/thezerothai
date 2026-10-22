package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_UIShellFlag: FEATURE_UI_SHELL (client-only, no RPC guard) defaults to off and is overridable.
func TestLoad_UIShellFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureUIShell.Name != "ui_shell" || cfg.FeatureUIShell.Mode != flags.Off {
		t.Errorf("FeatureUIShell = %+v, want name ui_shell, mode off", cfg.FeatureUIShell)
	}
	clearEnv(t)
	t.Setenv("FEATURE_UI_SHELL", "on")
	if cfg, err = Load(); err != nil || cfg.FeatureUIShell.Mode != flags.On {
		t.Fatalf("override: %+v err=%v", cfg.FeatureUIShell, err)
	}
	clearEnv(t)
	t.Setenv("FEATURE_UI_SHELL", "bogus")
	if _, err = Load(); err == nil {
		t.Error("an invalid FEATURE_UI_SHELL must fail startup")
	}
}
