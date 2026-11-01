package config

import (
	"slices"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// telemetryFlag names one of the two client-only telemetry flags (ADR-0032 D11) and how to read it from a Config.
type telemetryFlag struct {
	env, wire string
	spec      func(Config) flags.Spec
}

var telemetryFlags = []telemetryFlag{
	{"CRASH_REPORTING", "crash_reporting", func(c Config) flags.Spec { return c.FeatureCrashReporting }},
	{"ANALYTICS", "analytics", func(c Config) flags.Spec { return c.FeatureAnalytics }},
}

// registryOf builds the registry the way apiserver does for these two flags.
func registryOf(cfg Config) *flags.Registry {
	return flags.NewRegistry(cfg.FeatureCrashReporting, cfg.FeatureAnalytics)
}

// TestLoad_TelemetryFlags: both flags (client-only, no RPC guard) default to off, are overridable, and an invalid
// mode or percent fails startup.
func TestLoad_TelemetryFlags(t *testing.T) {
	for _, f := range telemetryFlags {
		t.Run(f.wire, func(t *testing.T) {
			clearEnv(t)
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if s := f.spec(cfg); s.Name != f.wire || s.Mode != flags.Off {
				t.Errorf("spec = %+v, want name %s, mode off", s, f.wire)
			}
			clearEnv(t)
			t.Setenv("FEATURE_"+f.env, "on")
			if cfg, err = Load(); err != nil || f.spec(cfg).Mode != flags.On {
				t.Fatalf("override: %+v err=%v", f.spec(cfg), err)
			}
			for _, bad := range []struct{ key, val string }{{"FEATURE_" + f.env, "bogus"}, {"FEATURE_" + f.env + "_PERCENT", "101"}} {
				clearEnv(t)
				t.Setenv(bad.key, bad.val)
				if _, err = Load(); err == nil {
					t.Errorf("%s=%q must fail startup", bad.key, bad.val)
				}
			}
		})
	}
}

// TestTelemetryFlags_Registry: unset, GetMe.enabled_features never lists them and the startup feature_flags values show
// both off; an allowlist with one uid enables the name for that uid only, and only for its own flag.
func TestTelemetryFlags_Registry(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	reg := registryOf(cfg)
	for _, f := range telemetryFlags {
		if got := reg.StartupLogValues()[f.wire]; got != "off" {
			t.Errorf("startup feature_flags lists %s as %q, want off", f.wire, got)
		}
		if reg.Enabled("uid-a", f.wire) || !reg.GloballyOff(f.wire) {
			t.Errorf("%s must be off for everyone while unset", f.wire)
		}
	}
	if got := reg.EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures while off = %v, want none", got)
	}

	for _, f := range telemetryFlags {
		t.Run(f.wire, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_"+f.env, "allowlist")
			t.Setenv("FEATURE_"+f.env+"_ALLOWLIST", "uid-a")
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			reg := registryOf(cfg)
			if got := reg.EnabledFeatures("uid-a"); !slices.Equal(got, []string{f.wire}) {
				t.Errorf("EnabledFeatures(uid-a) = %v, want [%s]", got, f.wire)
			}
			if got := reg.EnabledFeatures("uid-b"); len(got) != 0 {
				t.Errorf("EnabledFeatures(uid-b) = %v, want none", got)
			}
			if got := reg.StartupLogValues()[f.wire]; got != "allowlist" {
				t.Errorf("startup feature_flags lists %s as %q, want allowlist", f.wire, got)
			}
		})
	}
}
