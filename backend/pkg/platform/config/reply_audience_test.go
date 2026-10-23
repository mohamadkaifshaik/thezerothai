package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ReplyAudienceFlag: FEATURE_REPLY_AUDIENCE (ADR-0021 D2) defaults to off in every environment,
// is overridable like the other server flags, and is listed in enabled_features only when on for the caller.
func TestLoad_ReplyAudienceFlag(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.FeatureReplyAudience.Name != "reply_audience" || cfg.FeatureReplyAudience.Mode != flags.Off {
		t.Errorf("FeatureReplyAudience = %+v, want name reply_audience, mode off", cfg.FeatureReplyAudience)
	}
	if got := flags.NewRegistry(cfg.FeatureReplyAudience).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}

	t.Setenv("FEATURE_REPLY_AUDIENCE", "allowlist")
	t.Setenv("FEATURE_REPLY_AUDIENCE_ALLOWLIST", "uid-a,uid-b")
	cfg, err = Load()
	if err != nil || cfg.FeatureReplyAudience.Mode != flags.Allowlist || len(cfg.FeatureReplyAudience.Allowlist) != 2 {
		t.Fatalf("override: %+v err=%v", cfg.FeatureReplyAudience, err)
	}
	reg := flags.NewRegistry(cfg.FeatureReplyAudience)
	if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "reply_audience" {
		t.Errorf("EnabledFeatures(uid-a) = %v, want [reply_audience]", got)
	}
	if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
		t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
	}

	t.Setenv("FEATURE_REPLY_AUDIENCE", "bogus")
	if _, err := Load(); err == nil {
		t.Error("an invalid FEATURE_REPLY_AUDIENCE must fail startup")
	}
}
