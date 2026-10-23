package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ContentDisclosureFlag: FEATURE_CONTENT_DISCLOSURE (ADR-0021 D3) defaults to off in every environment,
// is overridable like the other server flags, and is listed in enabled_features only when on for the caller.
func TestLoad_ContentDisclosureFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureContentDisclosure.Name != "content_disclosure" || cfg.FeatureContentDisclosure.Mode != flags.Off {
		t.Errorf("FeatureContentDisclosure = %+v, want name content_disclosure, mode off", cfg.FeatureContentDisclosure)
	}
	if got := flags.NewRegistry(cfg.FeatureContentDisclosure).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}

	t.Setenv("FEATURE_CONTENT_DISCLOSURE", "allowlist")
	t.Setenv("FEATURE_CONTENT_DISCLOSURE_ALLOWLIST", "uid-a,uid-b")
	cfg, err = Load()
	if err != nil || cfg.FeatureContentDisclosure.Mode != flags.Allowlist || len(cfg.FeatureContentDisclosure.Allowlist) != 2 {
		t.Fatalf("override: %+v err=%v", cfg.FeatureContentDisclosure, err)
	}
	reg := flags.NewRegistry(cfg.FeatureContentDisclosure)
	if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "content_disclosure" {
		t.Errorf("EnabledFeatures(uid-a) = %v, want [content_disclosure]", got)
	}
	if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
		t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
	}

	t.Setenv("FEATURE_CONTENT_DISCLOSURE", "bogus")
	if _, err := Load(); err == nil {
		t.Error("an invalid FEATURE_CONTENT_DISCLOSURE must fail startup")
	}
}
