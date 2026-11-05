package config

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func mediaEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	clearEnv(t)
	for _, k := range []string{
		"FEATURE_MEDIA", "FEATURE_MEDIA_ALLOWLIST", "FEATURE_MEDIA_PERCENT",
		"VISION_SCREEN_THUMB", "MEDIA_BUCKET", "MEDIA_UPLOAD_BUCKET", "MEDIA_PUBLIC_BASE_URL",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("ENV", "local")
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

// TestLoad_MediaDefaults: the flag is off in every environment and the thumbnail is screened by default.
func TestLoad_MediaDefaults(t *testing.T) {
	mediaEnv(t, nil)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FeatureMedia.Mode != flags.Off || cfg.FeatureMedia.Name != "media" {
		t.Errorf("FeatureMedia = %+v, want off / media", cfg.FeatureMedia)
	}
	if !cfg.VisionScreenThumb {
		t.Errorf("thumbnail screening should default on")
	}
	if !strings.HasSuffix(cfg.MediaBucket, "-media") || !strings.HasSuffix(cfg.MediaUploadBucket, "-media-upload") {
		t.Errorf("buckets = %q / %q", cfg.MediaBucket, cfg.MediaUploadBucket)
	}
	if cfg.MediaPublicBaseURL != "https://storage.googleapis.com/"+cfg.MediaBucket {
		t.Errorf("public base = %q", cfg.MediaPublicBaseURL)
	}
}

func TestLoad_MediaOverrides(t *testing.T) {
	mediaEnv(t, map[string]string{
		"FEATURE_MEDIA":       "on",
		"VISION_SCREEN_THUMB": "false", "MEDIA_PUBLIC_BASE_URL": "https://cdn.example.com/m/",
	})
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FeatureMedia.Mode != flags.On || cfg.VisionScreenThumb {
		t.Errorf("cfg = %+v", cfg)
	}
	if cfg.MediaPublicBaseURL != "https://cdn.example.com/m" {
		t.Errorf("trailing slash must be trimmed: %q", cfg.MediaPublicBaseURL)
	}
}

// TestLoad_MediaInvalid: a bad thumb switch or flag mode fails startup instead of silently changing what is published.
func TestLoad_MediaInvalid(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"bad thumb switch", map[string]string{"VISION_SCREEN_THUMB": "maybe"}, "VISION_SCREEN_THUMB"},
		{"bad flag mode", map[string]string{"FEATURE_MEDIA": "sometimes"}, "FEATURE_MEDIA"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mediaEnv(t, tt.env)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("Load() err = %v, want mention of %s", err, tt.want)
			}
		})
	}
}
