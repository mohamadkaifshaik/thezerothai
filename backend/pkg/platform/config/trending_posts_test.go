package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_TrendingPosts: FEATURE_TRENDING_POSTS defaults off with the wire name trending_posts (ExplorePosts, the
// Trending page's newest-posts feed), and every mode the env can set parses, with its allowlist and percent.
func TestLoad_TrendingPosts(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		mode    flags.Mode
		percent int
		allow   []string
	}{
		{"unset is off", nil, flags.Off, 0, nil},
		{"off", map[string]string{"FEATURE_TRENDING_POSTS": "off"}, flags.Off, 0, nil},
		{"allowlist", map[string]string{"FEATURE_TRENDING_POSTS": "allowlist", "FEATURE_TRENDING_POSTS_ALLOWLIST": "uid-a,uid-b"}, flags.Allowlist, 0, []string{"uid-a", "uid-b"}},
		{"percent", map[string]string{"FEATURE_TRENDING_POSTS": "percent", "FEATURE_TRENDING_POSTS_PERCENT": "25"}, flags.Percent, 25, nil},
		{"on", map[string]string{"FEATURE_TRENDING_POSTS": "on"}, flags.On, 0, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			for _, k := range []string{"FEATURE_TRENDING_POSTS", "FEATURE_TRENDING_POSTS_ALLOWLIST", "FEATURE_TRENDING_POSTS_PERCENT"} {
				t.Setenv(k, tt.env[k])
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			got := cfg.FeatureTrendingPosts
			if got.Name != "trending_posts" || got.Mode != tt.mode || got.Percent != tt.percent {
				t.Fatalf("FeatureTrendingPosts = %+v, want name trending_posts mode %q percent %d", got, tt.mode, tt.percent)
			}
			for _, uid := range tt.allow {
				if _, ok := got.Allowlist[uid]; !ok {
					t.Errorf("allowlist misses %s: %+v", uid, got.Allowlist)
				}
			}
			if cfg.FeatureTrendingMedia.Mode != flags.Off {
				t.Errorf("FEATURE_TRENDING_POSTS moved FeatureTrendingMedia to %q", cfg.FeatureTrendingMedia.Mode)
			}
		})
	}
	t.Run("an unknown mode fails startup", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("FEATURE_TRENDING_POSTS", "sometimes")
		if _, err := Load(); err == nil {
			t.Fatal("Load() accepted FEATURE_TRENDING_POSTS=sometimes")
		}
	})
}
