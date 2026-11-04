package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_CommunitiesDefaults pins every default and the flag (off, wire name communities).
func TestLoad_CommunitiesDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.CommunitiesWritePerUserPerMinute != 20 || rl.CommunitiesReadPerUserPerMinute != 30 || rl.CommunityTimelinePerUserPerMinute != 12 {
		t.Errorf("community buckets = %d/%d/%d, want 20/30/12", rl.CommunitiesWritePerUserPerMinute, rl.CommunitiesReadPerUserPerMinute, rl.CommunityTimelinePerUserPerMinute)
	}
	if rl := cfg.RateLimit; rl.CommunityModActionsPerDay != 200 || rl.CommunityPostsPerCommunityPerDay != 20 {
		t.Errorf("community daily caps = %d/%d, want 200/20", rl.CommunityModActionsPerDay, rl.CommunityPostsPerCommunityPerDay)
	}
	c := cfg.Communities
	if c.MaxOwned != 2 || c.MaxJoined != 50 || c.MaxModerators != 10 || c.MaxRules != 10 || c.RecentRemovalsMax != 50 || c.ModlogMax != 100 {
		t.Errorf("community caps = %+v, want 2/50/10/10/50/100", c)
	}
	if c.CacheEntries != 200 || c.FeedCacheEntries != 100 || c.MembersCacheEntries != 5000 {
		t.Errorf("community caches = %d/%d/%d, want 200/100/5000", c.CacheEntries, c.FeedCacheEntries, c.MembersCacheEntries)
	}
	if len(c.Creators) != 0 {
		t.Errorf("Creators = %d, want none by default", len(c.Creators))
	}
	if cfg.FeatureCommunities.Name != "communities" || cfg.FeatureCommunities.Mode != flags.Off {
		t.Errorf("FeatureCommunities = %+v, want name communities, mode off", cfg.FeatureCommunities)
	}
}

// TestLoad_CommunitiesOverridesAndValidation: every key is overridable, a zero, negative or unparseable value fails startup
// naming the key, and a bad flag value fails startup naming the flag key.
func TestLoad_CommunitiesOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		for k, v := range map[string]string{
			"RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN": "7", "RATE_LIMIT_COMMUNITIES_READ_PER_MIN": "8", "RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN": "9",
			"COMMUNITY_MOD_ACTIONS_PER_DAY": "12", "COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY": "13",
			"COMMUNITIES_MAX_OWNED": "3", "COMMUNITIES_MAX_JOINED": "12", "COMMUNITY_MAX_MODERATORS": "4", "COMMUNITY_MAX_RULES": "5",
			"COMMUNITY_RECENT_REMOVALS_MAX": "21", "COMMUNITY_MODLOG_MAX": "22",
			"CACHE_COMMUNITIES_ENTRIES": "10", "CACHE_COMMUNITY_FEED_ENTRIES": "11", "CACHE_COMMUNITY_MEMBERS_ENTRIES": "12",
			"FEATURE_COMMUNITIES": "allowlist", "FEATURE_COMMUNITIES_ALLOWLIST": "uid-a,uid-b", "COMMUNITY_CREATORS": " uid-a , uid-b,uid-a",
		} {
			t.Setenv(k, v)
		}
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if rl := cfg.RateLimit; rl.CommunitiesWritePerUserPerMinute != 7 || rl.CommunitiesReadPerUserPerMinute != 8 || rl.CommunityTimelinePerUserPerMinute != 9 ||
			rl.CommunityModActionsPerDay != 12 || rl.CommunityPostsPerCommunityPerDay != 13 {
			t.Errorf("rate limit override = %+v", rl)
		}
		c := cfg.Communities
		if c.MaxOwned != 3 || c.MaxJoined != 12 || c.MaxModerators != 4 || c.MaxRules != 5 || c.RecentRemovalsMax != 21 || c.ModlogMax != 22 ||
			c.CacheEntries != 10 || c.FeedCacheEntries != 11 || c.MembersCacheEntries != 12 {
			t.Errorf("communities override = %+v", c)
		}
		if len(c.Creators) != 2 || c.Creators[0] != "uid-a" || c.Creators[1] != "uid-b" {
			t.Errorf("Creators = %v, want [uid-a uid-b] (trimmed, duplicate dropped)", c.Creators)
		}
		reg := flags.NewRegistry(cfg.FeatureCommunities)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "communities" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [communities]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	for _, key := range []string{
		"RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN", "RATE_LIMIT_COMMUNITIES_READ_PER_MIN", "RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN",
		"COMMUNITY_MOD_ACTIONS_PER_DAY", "COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY",
		"COMMUNITIES_MAX_OWNED", "COMMUNITIES_MAX_JOINED", "COMMUNITY_MAX_MODERATORS", "COMMUNITY_MAX_RULES",
		"COMMUNITY_RECENT_REMOVALS_MAX", "COMMUNITY_MODLOG_MAX",
		"CACHE_COMMUNITIES_ENTRIES", "CACHE_COMMUNITY_FEED_ENTRIES", "CACHE_COMMUNITY_MEMBERS_ENTRIES",
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
	for _, tt := range []struct{ key, val string }{{"FEATURE_COMMUNITIES", "bogus"}, {"FEATURE_COMMUNITIES_PERCENT", "101"}} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.key) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.key)
			}
		})
	}
}

// TestLoad_CommunityCreators: at most 10 uids, each ids.ValidUID; an invalid uid or an eleventh uid fails startup, and the error
// never echoes a uid (it could be a real account id).
func TestLoad_CommunityCreators(t *testing.T) {
	ten := "u1,u2,u3,u4,u5,u6,u7,u8,u9,u10"
	tests := []struct {
		name    string
		val     string
		want    int
		wantErr string
	}{
		{"empty", "", 0, ""},
		{"one", "uid-1", 1, ""},
		{"ten", ten, 10, ""},
		{"ten plus a duplicate", ten + ",u1", 10, ""},
		{"eleven", ten + ",u11", 0, "at most 10"},
		{"underscore", "uid_secret", 0, "invalid uid"},
		{"too long", strings.Repeat("a", 129), 0, "invalid uid"},
		{"slash", "uid-1,a/b", 0, "invalid uid"},
		{"space inside", "uid 1", 0, "invalid uid"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("COMMUNITY_CREATORS", tt.val)
			cfg, err := Load()
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), "COMMUNITY_CREATORS") || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("Load() error = %v, want one naming COMMUNITY_CREATORS and %q", err, tt.wantErr)
				}
				if strings.Contains(err.Error(), "uid_secret") || strings.Contains(err.Error(), "a/b") {
					t.Errorf("error %q echoes a uid", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if got := len(cfg.Communities.Creators); got != tt.want {
				t.Errorf("creators = %d, want %d", got, tt.want)
			}
		})
	}
}

// TestLoad_CommunitiesFlagModes: off, allowlist, percent and on as the registry decides them for a caller.
func TestLoad_CommunitiesFlagModes(t *testing.T) {
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
			t.Setenv("FEATURE_COMMUNITIES", tt.mode)
			if tt.allowlist != "" {
				t.Setenv("FEATURE_COMMUNITIES_ALLOWLIST", tt.allowlist)
			}
			if tt.percent != "" {
				t.Setenv("FEATURE_COMMUNITIES_PERCENT", tt.percent)
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			reg := flags.NewRegistry(cfg.FeatureCommunities)
			if got := len(reg.EnabledFeatures("uid-a")) == 1; got != tt.wantIn {
				t.Errorf("uid-a enabled = %v, want %v", got, tt.wantIn)
			}
			if got := len(reg.EnabledFeatures("uid-z")) == 1; got != tt.wantOut {
				t.Errorf("uid-z enabled = %v, want %v", got, tt.wantOut)
			}
		})
	}
}
