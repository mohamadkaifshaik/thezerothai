package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_ListsDefaults pins every default and the flag (off, wire name lists).
func TestLoad_ListsDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.ListsWritePerUserPerMinute != 30 || rl.ListsReadPerUserPerMinute != 30 || rl.ListTimelinePerUserPerMinute != 12 {
		t.Errorf("list buckets = %d/%d/%d, want 30/30/12", rl.ListsWritePerUserPerMinute, rl.ListsReadPerUserPerMinute, rl.ListTimelinePerUserPerMinute)
	}
	if l := cfg.Lists; l.MaxPerUser != 20 || l.MaxMembers != 150 || l.HomeTabsMaxPinned != 5 || l.CacheEntries != 2000 {
		t.Errorf("lists config = %+v, want 20/150/5/2000", l)
	}
	if cfg.FeatureLists.Name != "lists" || cfg.FeatureLists.Mode != flags.Off {
		t.Errorf("FeatureLists = %+v, want name lists, mode off", cfg.FeatureLists)
	}
}

// TestLoad_ListsOverridesAndValidation: every key is overridable, a zero, negative or unparseable value fails startup naming
// the key, and a bad flag value fails startup naming the flag key.
func TestLoad_ListsOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		for k, v := range map[string]string{
			"RATE_LIMIT_LISTS_WRITE_PER_MIN": "7", "RATE_LIMIT_LISTS_READ_PER_MIN": "8", "RATE_LIMIT_LIST_TIMELINE_PER_MIN": "9",
			"LISTS_MAX_PER_USER": "3",
			"LIST_MAX_MEMBERS":   "12", "HOME_TABS_MAX_PINNED": "2", "CACHE_LISTS_ENTRIES": "10",
			"FEATURE_LISTS": "allowlist", "FEATURE_LISTS_ALLOWLIST": "uid-a,uid-b",
		} {
			t.Setenv(k, v)
		}
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if rl := cfg.RateLimit; rl.ListsWritePerUserPerMinute != 7 || rl.ListsReadPerUserPerMinute != 8 || rl.ListTimelinePerUserPerMinute != 9 {
			t.Errorf("rate limit override = %d/%d/%d", rl.ListsWritePerUserPerMinute, rl.ListsReadPerUserPerMinute, rl.ListTimelinePerUserPerMinute)
		}
		if l := cfg.Lists; l.MaxPerUser != 3 || l.MaxMembers != 12 || l.HomeTabsMaxPinned != 2 || l.CacheEntries != 10 {
			t.Errorf("lists override = %+v", l)
		}
		reg := flags.NewRegistry(cfg.FeatureLists)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "lists" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [lists]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	for _, key := range []string{
		"RATE_LIMIT_LISTS_WRITE_PER_MIN", "RATE_LIMIT_LISTS_READ_PER_MIN", "RATE_LIMIT_LIST_TIMELINE_PER_MIN",
		"LISTS_MAX_PER_USER", "LIST_MAX_MEMBERS", "HOME_TABS_MAX_PINNED", "CACHE_LISTS_ENTRIES",
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
	// LIST_MAX_MEMBERS is bounded above (500 is accepted, 501 fails startup naming the key).
	t.Run("LIST_MAX_MEMBERS at the ceiling", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("LIST_MAX_MEMBERS", "500")
		cfg, err := Load()
		if err != nil || cfg.Lists.MaxMembers != 500 {
			t.Errorf("Load() = %d, %v, want 500, nil", cfg.Lists.MaxMembers, err)
		}
	})
	for _, val := range []string{"501", "4890", "100000"} {
		t.Run("LIST_MAX_MEMBERS="+val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("LIST_MAX_MEMBERS", val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), "LIST_MAX_MEMBERS") || !strings.Contains(err.Error(), "500") {
				t.Errorf("Load() error = %v, want one naming LIST_MAX_MEMBERS and 500", err)
			}
		})
	}
	for _, tt := range []struct{ key, val string }{{"FEATURE_LISTS", "bogus"}, {"FEATURE_LISTS_PERCENT", "101"}} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
}

// TestLoad_ListsFlagModes: off, allowlist, percent and on as the registry decides them for a caller.
func TestLoad_ListsFlagModes(t *testing.T) {
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
			t.Setenv("FEATURE_LISTS", tt.mode)
			if tt.allowlist != "" {
				t.Setenv("FEATURE_LISTS_ALLOWLIST", tt.allowlist)
			}
			if tt.percent != "" {
				t.Setenv("FEATURE_LISTS_PERCENT", tt.percent)
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			reg := flags.NewRegistry(cfg.FeatureLists)
			if got := len(reg.EnabledFeatures("uid-a")) == 1; got != tt.wantIn {
				t.Errorf("uid-a enabled = %v, want %v", got, tt.wantIn)
			}
			if got := len(reg.EnabledFeatures("uid-z")) == 1; got != tt.wantOut {
				t.Errorf("uid-z enabled = %v, want %v", got, tt.wantOut)
			}
		})
	}
}
