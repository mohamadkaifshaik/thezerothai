package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_BeaconsDefaults pins every beacon default and the flag (off, wire name beacons).
func TestLoad_BeaconsDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.BeaconsWritePerUserPerMinute != 10 || rl.BeaconsActionPerUserPerMinute != 20 || rl.BeaconsReadPerUserPerMinute != 30 {
		t.Errorf("beacon buckets = %d/%d/%d, want 10/20/30", rl.BeaconsWritePerUserPerMinute, rl.BeaconsActionPerUserPerMinute, rl.BeaconsReadPerUserPerMinute)
	}
	if cfg.RateLimit.BeaconsCreatedPerDay != 10 {
		t.Errorf("BeaconsCreatedPerDay = %d, want 10", cfg.RateLimit.BeaconsCreatedPerDay)
	}
	if b := cfg.Beacons; b.MaxOpenPerUser != 5 || b.MaxPendingRequests != 10 || b.MaxOpenSpots != 20 {
		t.Errorf("beacons config = %+v, want 5/10/20", b)
	}
	if cfg.FeatureBeacons.Name != "beacons" || cfg.FeatureBeacons.Mode != flags.Off {
		t.Errorf("FeatureBeacons = %+v, want name beacons, mode off", cfg.FeatureBeacons)
	}
}

// TestLoad_BeaconsOverridesAndValidation: every key is overridable, a zero, negative or unparseable value fails startup
// naming the key, BEACONS_MAX_OPEN_SPOTS is bounded above, and a bad flag value fails startup naming the flag key.
func TestLoad_BeaconsOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		for k, v := range map[string]string{
			"RATE_LIMIT_BEACONS_WRITE_PER_MIN": "7", "RATE_LIMIT_BEACONS_ACTION_PER_MIN": "8", "RATE_LIMIT_BEACONS_READ_PER_MIN": "9",
			"BEACONS_CREATED_PER_DAY":   "11",
			"BEACONS_MAX_OPEN_PER_USER": "3", "BEACONS_MAX_PENDING_REQUESTS": "4", "BEACONS_MAX_OPEN_SPOTS": "12",
			"FEATURE_BEACONS": "allowlist", "FEATURE_BEACONS_ALLOWLIST": "uid-a,uid-b",
		} {
			t.Setenv(k, v)
		}
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if rl := cfg.RateLimit; rl.BeaconsWritePerUserPerMinute != 7 || rl.BeaconsActionPerUserPerMinute != 8 || rl.BeaconsReadPerUserPerMinute != 9 {
			t.Errorf("rate limit override = %d/%d/%d", rl.BeaconsWritePerUserPerMinute, rl.BeaconsActionPerUserPerMinute, rl.BeaconsReadPerUserPerMinute)
		}
		if cfg.RateLimit.BeaconsCreatedPerDay != 11 {
			t.Errorf("BeaconsCreatedPerDay override = %d, want 11", cfg.RateLimit.BeaconsCreatedPerDay)
		}
		if b := cfg.Beacons; b.MaxOpenPerUser != 3 || b.MaxPendingRequests != 4 || b.MaxOpenSpots != 12 {
			t.Errorf("beacons override = %+v, want 3/4/12", b)
		}
		reg := flags.NewRegistry(cfg.FeatureBeacons)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "beacons" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [beacons]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	for _, key := range []string{
		"RATE_LIMIT_BEACONS_WRITE_PER_MIN", "RATE_LIMIT_BEACONS_ACTION_PER_MIN", "RATE_LIMIT_BEACONS_READ_PER_MIN",
		"BEACONS_CREATED_PER_DAY", "BEACONS_MAX_OPEN_PER_USER", "BEACONS_MAX_PENDING_REQUESTS", "BEACONS_MAX_OPEN_SPOTS",
	} {
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
	// BEACONS_MAX_OPEN_SPOTS is bounded above (50 is accepted, 51 fails startup naming the key and the ceiling).
	t.Run("BEACONS_MAX_OPEN_SPOTS at the ceiling", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("BEACONS_MAX_OPEN_SPOTS", "50")
		cfg, err := Load()
		if err != nil || cfg.Beacons.MaxOpenSpots != 50 {
			t.Errorf("Load() = %d, %v, want 50, nil", cfg.Beacons.MaxOpenSpots, err)
		}
	})
	for _, val := range []string{"51", "1000"} {
		t.Run("BEACONS_MAX_OPEN_SPOTS="+val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("BEACONS_MAX_OPEN_SPOTS", val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), "BEACONS_MAX_OPEN_SPOTS") || !strings.Contains(err.Error(), "50") {
				t.Errorf("Load() error = %v, want one naming BEACONS_MAX_OPEN_SPOTS and 50", err)
			}
		})
	}
	for _, tt := range []struct{ key, val string }{{"FEATURE_BEACONS", "bogus"}, {"FEATURE_BEACONS_PERCENT", "101"}} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
}

// TestLoad_BeaconsFlagModes: off, allowlist, percent and on as the registry decides them for a caller.
func TestLoad_BeaconsFlagModes(t *testing.T) {
	tests := []struct {
		name      string
		mode      string
		allowlist string
		percent   string
		wantIn    bool // uid-a
		wantOut   bool // uid-z
	}{
		{"off", "off", "uid-a", "100", false, false},
		{"allowlist", "allowlist", "uid-a", "", true, false},
		{"percent 0", "percent", "", "0", false, false},
		{"percent 100", "percent", "", "100", true, true},
		{"on", "on", "", "", true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_BEACONS", tt.mode)
			if tt.allowlist != "" {
				t.Setenv("FEATURE_BEACONS_ALLOWLIST", tt.allowlist)
			}
			if tt.percent != "" {
				t.Setenv("FEATURE_BEACONS_PERCENT", tt.percent)
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			reg := flags.NewRegistry(cfg.FeatureBeacons)
			if got := len(reg.EnabledFeatures("uid-a")) == 1; got != tt.wantIn {
				t.Errorf("uid-a enabled = %v, want %v", got, tt.wantIn)
			}
			if got := len(reg.EnabledFeatures("uid-z")) == 1; got != tt.wantOut {
				t.Errorf("uid-z enabled = %v, want %v", got, tt.wantOut)
			}
		})
	}
}
