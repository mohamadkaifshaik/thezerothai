package config

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_SearchDefaults pins every ADR-0028 D9 default and the two flags (off, wire names search and trends).
func TestLoad_SearchDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.SearchPeoplePerUserPerMinute != 30 || rl.SearchPostsPerUserPerMinute != 20 || rl.SearchCallsPerDay != 300 || rl.TrendsCallsPerDay != 400 {
		t.Errorf("search limits = %d/%d/%d/%d, want 30/20/300/400", rl.SearchPeoplePerUserPerMinute, rl.SearchPostsPerUserPerMinute, rl.SearchCallsPerDay, rl.TrendsCallsPerDay)
	}
	s := cfg.Search
	if s.PrefixCacheEntries != 2000 || s.TagCacheEntries != 500 || s.TrendsMinAuthors != 3 || s.TrendsMaxPostsPerRun != 2000 || s.TrendsMinInterval != 12*time.Hour ||
		s.TrendsMinAccountAge != 72*time.Hour || s.TrendsMaxAuthorChecks != 500 || len(s.TrendsDenylist) != 0 {
		t.Errorf("search config = %+v, want 2000/500/3/2000/12h/72h/500/none", s)
	}
	for _, f := range []struct {
		spec flags.Spec
		name string
	}{{cfg.FeatureSearch, "search"}, {cfg.FeatureTrends, "trends"}} {
		if f.spec.Name != f.name || f.spec.Mode != flags.Off {
			t.Errorf("flag = %+v, want name %s, mode off", f.spec, f.name)
		}
	}
	if got := flags.NewRegistry(cfg.FeatureSearch, cfg.FeatureTrends).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures = %v, want none", got)
	}
}

// TestLoad_SearchOverridesAndValidation: every key is overridable, a zero, negative or unparseable value fails startup
// naming the key, and each flag appears in enabled_features only for its own allowlisted uids.
func TestLoad_SearchOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("RATE_LIMIT_SEARCH_PEOPLE_PER_MIN", "7")
		t.Setenv("RATE_LIMIT_SEARCH_POSTS_PER_MIN", "8")
		t.Setenv("SEARCH_CALLS_PER_DAY", "9")
		t.Setenv("TRENDS_CALLS_PER_DAY", "13")
		t.Setenv("CACHE_SEARCH_PREFIX_ENTRIES", "10")
		t.Setenv("CACHE_SEARCH_TAG_ENTRIES", "11")
		t.Setenv("TRENDS_MIN_AUTHORS", "4")
		t.Setenv("TRENDS_MAX_POSTS_PER_RUN", "12")
		t.Setenv("TRENDS_MIN_INTERVAL", "50m")
		t.Setenv("TRENDS_MIN_ACCOUNT_AGE", "96h")
		t.Setenv("TRENDS_MAX_AUTHOR_CHECKS", "77")
		t.Setenv("TRENDS_DENYLIST", " #Spam, ,bad ")
		t.Setenv("FEATURE_SEARCH", "allowlist")
		t.Setenv("FEATURE_SEARCH_ALLOWLIST", "uid-a,uid-b")
		t.Setenv("FEATURE_TRENDS", "allowlist")
		t.Setenv("FEATURE_TRENDS_ALLOWLIST", "uid-b")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if rl := cfg.RateLimit; rl.SearchPeoplePerUserPerMinute != 7 || rl.SearchPostsPerUserPerMinute != 8 || rl.SearchCallsPerDay != 9 || rl.TrendsCallsPerDay != 13 {
			t.Errorf("rate limit override = %d/%d/%d", rl.SearchPeoplePerUserPerMinute, rl.SearchPostsPerUserPerMinute, rl.SearchCallsPerDay)
		}
		s := cfg.Search
		if s.PrefixCacheEntries != 10 || s.TagCacheEntries != 11 || s.TrendsMinAuthors != 4 || s.TrendsMaxPostsPerRun != 12 || s.TrendsMinInterval != 50*time.Minute ||
			s.TrendsMinAccountAge != 96*time.Hour || s.TrendsMaxAuthorChecks != 77 {
			t.Errorf("search override = %+v", s)
		}
		if want := []string{"spam", "bad"}; !reflect.DeepEqual(s.TrendsDenylist, want) {
			t.Errorf("TrendsDenylist = %v, want %v", s.TrendsDenylist, want)
		}
		reg := flags.NewRegistry(cfg.FeatureSearch, cfg.FeatureTrends)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "search" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [search]", got)
		}
		if got := reg.EnabledFeatures("uid-b"); len(got) != 2 {
			t.Errorf("EnabledFeatures(uid-b) = %v, want search and trends", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	for _, key := range []string{
		"RATE_LIMIT_SEARCH_PEOPLE_PER_MIN", "RATE_LIMIT_SEARCH_POSTS_PER_MIN", "SEARCH_CALLS_PER_DAY", "TRENDS_CALLS_PER_DAY", "CACHE_SEARCH_PREFIX_ENTRIES",
		"CACHE_SEARCH_TAG_ENTRIES", "TRENDS_MIN_AUTHORS", "TRENDS_MAX_POSTS_PER_RUN", "TRENDS_MAX_AUTHOR_CHECKS",
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
	for _, key := range []string{"TRENDS_MIN_INTERVAL", "TRENDS_MIN_ACCOUNT_AGE"} {
		for _, val := range []string{"0", "-1h", "soon"} {
			t.Run(key+"="+val, func(t *testing.T) {
				clearEnv(t)
				t.Setenv(key, val)
				if _, err := Load(); err == nil || !strings.Contains(err.Error(), key) {
					t.Errorf("Load() error = %v, want one naming %s", err, key)
				}
			})
		}
	}
	for _, tt := range []struct{ key, val string }{
		{"FEATURE_SEARCH", "bogus"}, {"FEATURE_SEARCH_PERCENT", "101"},
		{"FEATURE_TRENDS", "bogus"}, {"FEATURE_TRENDS_PERCENT", "101"},
	} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
}
