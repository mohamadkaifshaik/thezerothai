package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestConfig_E2EEDM_DefaultsOff: FEATURE_E2EE_DM (the key directory, later end-to-end-encrypted DMs) is off for
// everyone when unset, and an allowlist turns it on for the listed uid only.
func TestConfig_E2EEDM_DefaultsOff(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureE2EEDM.Name != "e2ee_dm" || cfg.FeatureE2EEDM.Mode != flags.Off {
		t.Errorf("FeatureE2EEDM = %+v, want name e2ee_dm, mode off", cfg.FeatureE2EEDM)
	}
	reg := flags.NewRegistry(cfg.FeatureE2EEDM)
	if reg.Enabled("u1", "e2ee_dm") || !reg.GloballyOff("e2ee_dm") {
		t.Error("unset FEATURE_E2EE_DM must be off for everyone")
	}

	clearEnv(t)
	t.Setenv("FEATURE_E2EE_DM", "allowlist")
	t.Setenv("FEATURE_E2EE_DM_ALLOWLIST", "u1")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load() with allowlist error = %v", err)
	}
	reg = flags.NewRegistry(cfg.FeatureE2EEDM)
	if !reg.Enabled("u1", "e2ee_dm") {
		t.Error("allowlisted u1 should have e2ee_dm on")
	}
	if reg.Enabled("u2", "e2ee_dm") {
		t.Error("u2 is not allowlisted and must stay off")
	}
}
