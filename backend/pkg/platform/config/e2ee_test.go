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

// TestConfig_E2EERequired_DefaultsOff: FEATURE_E2EE_REQUIRED (E2EE Plan 6 §1.1, the plaintext refusal) is globally off when
// unset, an allowlist turns it on for the listed uid only, and an invalid mode fails startup.
func TestConfig_E2EERequired_DefaultsOff(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureE2EERequired.Name != "e2ee_required" || cfg.FeatureE2EERequired.Mode != flags.Off {
		t.Errorf("FeatureE2EERequired = %+v, want name e2ee_required, mode off", cfg.FeatureE2EERequired)
	}
	reg := flags.NewRegistry(cfg.FeatureE2EERequired)
	if reg.Enabled("u1", "e2ee_required") || !reg.GloballyOff("e2ee_required") {
		t.Error("unset FEATURE_E2EE_REQUIRED must be globally off")
	}

	clearEnv(t)
	t.Setenv("FEATURE_E2EE_REQUIRED", "allowlist")
	t.Setenv("FEATURE_E2EE_REQUIRED_ALLOWLIST", "u1")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load() with allowlist error = %v", err)
	}
	reg = flags.NewRegistry(cfg.FeatureE2EERequired)
	if !reg.Enabled("u1", "e2ee_required") || reg.Enabled("u2", "e2ee_required") {
		t.Error("allowlist: want on for u1 only")
	}

	clearEnv(t)
	t.Setenv("FEATURE_E2EE_REQUIRED", "always")
	if _, err := Load(); err == nil {
		t.Error("an invalid FEATURE_E2EE_REQUIRED mode must fail startup")
	}
}

// TestConfig_E2EEClaim_DefaultsOff: FEATURE_E2EE_CLAIM (E2EE Plan 6 §4.7, the "We cannot read your messages." switch) is
// globally off when unset, reports the wire name claim_live, an allowlist turns it on for the listed uid only, and an
// invalid mode fails startup.
func TestConfig_E2EEClaim_DefaultsOff(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureE2EEClaim.Name != "claim_live" || cfg.FeatureE2EEClaim.Mode != flags.Off {
		t.Errorf("FeatureE2EEClaim = %+v, want name claim_live, mode off", cfg.FeatureE2EEClaim)
	}
	reg := flags.NewRegistry(cfg.FeatureE2EEClaim)
	if reg.Enabled("u1", "claim_live") || !reg.GloballyOff("claim_live") {
		t.Error("unset FEATURE_E2EE_CLAIM must be globally off")
	}

	clearEnv(t)
	t.Setenv("FEATURE_E2EE_CLAIM", "allowlist")
	t.Setenv("FEATURE_E2EE_CLAIM_ALLOWLIST", "u1")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load() with allowlist error = %v", err)
	}
	reg = flags.NewRegistry(cfg.FeatureE2EEClaim)
	if !reg.Enabled("u1", "claim_live") || reg.Enabled("u2", "claim_live") {
		t.Error("allowlist: want on for u1 only")
	}

	clearEnv(t)
	t.Setenv("FEATURE_E2EE_CLAIM", "always")
	if _, err := Load(); err == nil {
		t.Error("an invalid FEATURE_E2EE_CLAIM mode must fail startup")
	}
}

// TestConfig_DeviceSignOut_DefaultsOff: FEATURE_DEVICE_SIGN_OUT (the session cut, security audit H2) is globally off when
// unset (the cut check reads nothing), and an allowlist turns it on for the listed uid only while making it not globally
// off for everyone (the check then enforces a stored cut for every account).
func TestConfig_DeviceSignOut_DefaultsOff(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureDeviceSignOut.Name != "device_sign_out" || cfg.FeatureDeviceSignOut.Mode != flags.Off {
		t.Errorf("FeatureDeviceSignOut = %+v, want name device_sign_out, mode off", cfg.FeatureDeviceSignOut)
	}
	reg := flags.NewRegistry(cfg.FeatureDeviceSignOut)
	if reg.Enabled("u1", "device_sign_out") || !reg.GloballyOff("device_sign_out") {
		t.Error("unset FEATURE_DEVICE_SIGN_OUT must be globally off")
	}

	clearEnv(t)
	t.Setenv("FEATURE_DEVICE_SIGN_OUT", "allowlist")
	t.Setenv("FEATURE_DEVICE_SIGN_OUT_ALLOWLIST", "u1")
	cfg, err = Load()
	if err != nil {
		t.Fatalf("Load() with allowlist error = %v", err)
	}
	reg = flags.NewRegistry(cfg.FeatureDeviceSignOut)
	if !reg.Enabled("u1", "device_sign_out") || reg.Enabled("u2", "device_sign_out") || reg.GloballyOff("device_sign_out") {
		t.Error("allowlist: want on for u1 only, and not globally off")
	}
}
