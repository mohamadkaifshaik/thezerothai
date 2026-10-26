package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_BookmarksDefaults pins every ADR-0023 D4/D5 default: the quotas, the cap, the two rate limits and the flag.
func TestLoad_BookmarksDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if q := cfg.Quota; q.BookmarksPerDay != 200 || q.NewAccountBookmarksPerDay != 50 || q.BookmarksMaxPerUser != 1000 {
		t.Errorf("bookmark quota/cap = %d/%d/%d, want 200/50/1000", q.BookmarksPerDay, q.NewAccountBookmarksPerDay, q.BookmarksMaxPerUser)
	}
	if rl := cfg.RateLimit; rl.BookmarksPerUserPerMinute != 30 || rl.BookmarksListPerUserPerMinute != 10 {
		t.Errorf("bookmark rate limits = %d/%d, want 30/10", rl.BookmarksPerUserPerMinute, rl.BookmarksListPerUserPerMinute)
	}
	if cfg.FeatureBookmarks.Name != "bookmarks" || cfg.FeatureBookmarks.Mode != flags.Off {
		t.Errorf("FeatureBookmarks = %+v, want name bookmarks, mode off", cfg.FeatureBookmarks)
	}
	if got := flags.NewRegistry(cfg.FeatureBookmarks).EnabledFeatures("uid-a"); len(got) != 0 {
		t.Errorf("EnabledFeatures with the flag off = %v, want none", got)
	}
}

// TestLoad_BookmarksOverridesAndValidation: every key is overridable, a non-positive or unparseable value fails
// startup naming the key, and the flag is listed in enabled_features only for allowlisted uids.
func TestLoad_BookmarksOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("QUOTA_BOOKMARKS_PER_DAY", "7")
		t.Setenv("QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY", "2")
		t.Setenv("BOOKMARKS_MAX_PER_USER", "9")
		t.Setenv("RATE_LIMIT_BOOKMARKS_PER_MIN", "11")
		t.Setenv("RATE_LIMIT_BOOKMARKS_LIST_PER_MIN", "4")
		t.Setenv("FEATURE_BOOKMARKS", "allowlist")
		t.Setenv("FEATURE_BOOKMARKS_ALLOWLIST", "uid-a,uid-b")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if q := cfg.Quota; q.BookmarksPerDay != 7 || q.NewAccountBookmarksPerDay != 2 || q.BookmarksMaxPerUser != 9 {
			t.Errorf("quota override = %d/%d/%d", q.BookmarksPerDay, q.NewAccountBookmarksPerDay, q.BookmarksMaxPerUser)
		}
		if rl := cfg.RateLimit; rl.BookmarksPerUserPerMinute != 11 || rl.BookmarksListPerUserPerMinute != 4 {
			t.Errorf("rate limit override = %d/%d", rl.BookmarksPerUserPerMinute, rl.BookmarksListPerUserPerMinute)
		}
		if cfg.FeatureBookmarks.Mode != flags.Allowlist || len(cfg.FeatureBookmarks.Allowlist) != 2 {
			t.Fatalf("flag override = %+v", cfg.FeatureBookmarks)
		}
		reg := flags.NewRegistry(cfg.FeatureBookmarks)
		if got := reg.EnabledFeatures("uid-a"); len(got) != 1 || got[0] != "bookmarks" {
			t.Errorf("EnabledFeatures(uid-a) = %v, want [bookmarks]", got)
		}
		if got := reg.EnabledFeatures("uid-z"); len(got) != 0 {
			t.Errorf("EnabledFeatures(uid-z) = %v, want none", got)
		}
	})

	for _, tt := range []struct{ key, val, want string }{
		{"QUOTA_BOOKMARKS_PER_DAY", "0", "QUOTA_BOOKMARKS_PER_DAY"},
		{"QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY", "-1", "QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY"},
		{"BOOKMARKS_MAX_PER_USER", "0", "BOOKMARKS_MAX_PER_USER"},
		{"RATE_LIMIT_BOOKMARKS_PER_MIN", "0", "RATE_LIMIT_BOOKMARKS_PER_MIN"},
		{"RATE_LIMIT_BOOKMARKS_LIST_PER_MIN", "-3", "RATE_LIMIT_BOOKMARKS_LIST_PER_MIN"},
		{"BOOKMARKS_MAX_PER_USER", "many", "BOOKMARKS_MAX_PER_USER"},
		{"FEATURE_BOOKMARKS", "bogus", "FEATURE_BOOKMARKS"},
		{"FEATURE_BOOKMARKS_PERCENT", "101", "FEATURE_BOOKMARKS_PERCENT"},
	} {
		t.Run(tt.key+"="+tt.val, func(t *testing.T) {
			clearEnv(t)
			t.Setenv(tt.key, tt.val)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("Load() error = %v, want one naming %s", err, tt.want)
			}
		})
	}
}
