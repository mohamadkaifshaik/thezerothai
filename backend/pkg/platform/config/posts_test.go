package config

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestLoad_FeaturePostsDefaults (ADR-0010 D1): off in prod, on in dev and local; the wire name is "posts".
func TestLoad_FeaturePostsDefaults(t *testing.T) {
	tests := []struct {
		name string
		env  string
		want flags.Mode
	}{
		{"local", "local", flags.On},
		{"dev", "dev", flags.On},
		{"prod", "prod", flags.Off},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("ENV", tt.env)
			if tt.env != "local" {
				t.Setenv("FIREBASE_PROJECT_ID", "dzeroth-x")
				t.Setenv("CURSOR_HMAC_KEY", "x-secret")
				t.Setenv("INTERNAL_OIDC_AUDIENCE", "https://api-xyz.a.run.app")
				t.Setenv("INTERNAL_OIDC_ALLOWED_EMAILS", "sa@x.iam.gserviceaccount.com")
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.FeaturePosts.Mode != tt.want {
				t.Errorf("FeaturePosts.Mode = %q, want %q", cfg.FeaturePosts.Mode, tt.want)
			}
			if cfg.FeaturePosts.Name != "posts" {
				t.Errorf("FeaturePosts.Name = %q, want posts", cfg.FeaturePosts.Name)
			}
		})
	}
}

// TestFeaturePosts_ListedInEnabledFeatures: the registry apiserver.Build creates from the loaded config reports
// "posts" for GetMe.enabled_features when the flag is on, and omits it when off.
func TestFeaturePosts_ListedInEnabledFeatures(t *testing.T) {
	for _, tt := range []struct {
		mode string
		want bool
	}{{"on", true}, {"off", false}} {
		t.Run(tt.mode, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("FEATURE_POSTS", tt.mode)
			cfg, err := Load()
			if err != nil {
				t.Fatal(err)
			}
			got := flags.NewRegistry(cfg.FeatureGraph, cfg.FeaturePosts).EnabledFeatures("uid-a")
			has := false
			for _, f := range got {
				has = has || f == "posts"
			}
			if has != tt.want {
				t.Fatalf("EnabledFeatures = %v, posts present = %v, want %v", got, has, tt.want)
			}
		})
	}
}

func TestLoad_FeaturePostsOverridesAndFailFast(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantErr bool
		want    flags.Mode
	}{
		{"allowlist", map[string]string{"FEATURE_POSTS": "allowlist", "FEATURE_POSTS_ALLOWLIST": "uid-a,uid-b"}, false, flags.Allowlist},
		{"percent", map[string]string{"FEATURE_POSTS": "percent", "FEATURE_POSTS_PERCENT": "25"}, false, flags.Percent},
		{"invalid mode fails fast", map[string]string{"FEATURE_POSTS": "maybe"}, true, ""},
		{"invalid percent fails fast", map[string]string{"FEATURE_POSTS": "percent", "FEATURE_POSTS_PERCENT": "150"}, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			for k, v := range tt.env {
				t.Setenv(k, v)
			}
			cfg, err := Load()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Load() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && cfg.FeaturePosts.Mode != tt.want {
				t.Errorf("FeaturePosts.Mode = %q, want %q", cfg.FeaturePosts.Mode, tt.want)
			}
		})
	}
}

// TestLoad_PostsRateLimitDefaultsAndValidation locks the ADR-0010 Handoff numbers and rejects <= 0 (rule 11).
func TestLoad_PostsRateLimitDefaultsAndValidation(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	rl := cfg.RateLimit
	if rl.TimelinePerUserPerMinute != 6 || rl.UserTimelinePerMinute != 30 || rl.PostCreatePerMinute != 10 || rl.PostDeletePerMinute != 20 {
		t.Errorf("defaults home/user/create/delete = %d/%d/%d/%d, want 6/30/10/20",
			rl.TimelinePerUserPerMinute, rl.UserTimelinePerMinute, rl.PostCreatePerMinute, rl.PostDeletePerMinute)
	}

	for _, key := range []string{
		"RATE_LIMIT_TIMELINE_PER_MIN", "RATE_LIMIT_USER_TIMELINE_PER_MIN", "RATE_LIMIT_POST_CREATE_PER_MIN", "RATE_LIMIT_POST_DELETE_PER_MIN",
	} {
		for _, bad := range []string{"0", "-3", "abc"} {
			t.Run(key+"="+bad, func(t *testing.T) {
				clearEnv(t)
				t.Setenv(key, bad)
				if _, err := Load(); err == nil {
					t.Fatalf("Load() with %s=%s must fail", key, bad)
				}
			})
		}
	}

	clearEnv(t)
	t.Setenv("RATE_LIMIT_POST_CREATE_PER_MIN", "3")
	cfg, err = Load()
	if err != nil || cfg.RateLimit.PostCreatePerMinute != 3 {
		t.Fatalf("override: cfg=%d err=%v", cfg.RateLimit.PostCreatePerMinute, err)
	}
}
