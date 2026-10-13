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
		"FEATURE_MEDIA", "FEATURE_MEDIA_ALLOWLIST", "FEATURE_MEDIA_PERCENT", "VISION_MONTHLY_CAP",
		"VISION_EXHAUSTED_POLICY", "VISION_SCREEN_THUMB", "MEDIA_BUCKET", "MEDIA_UPLOAD_BUCKET", "MEDIA_PUBLIC_BASE_URL",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("ENV", "local")
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

// TestLoad_MediaDefaults (ADR-0005, P4): the flag is off in every environment, the Vision cap is 10,000 units and the
// thumbnail is screened by default.
func TestLoad_MediaDefaults(t *testing.T) {
	mediaEnv(t, nil)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FeatureMedia.Mode != flags.Off || cfg.FeatureMedia.Name != "media" {
		t.Errorf("FeatureMedia = %+v, want off / media", cfg.FeatureMedia)
	}
	if cfg.VisionMonthlyCap != 10000 || cfg.VisionExhaustedPolicy != VisionPolicyEstablished || !cfg.VisionScreenThumb {
		t.Errorf("vision = %d %q thumb=%v", cfg.VisionMonthlyCap, cfg.VisionExhaustedPolicy, cfg.VisionScreenThumb)
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
		"FEATURE_MEDIA": "on", "VISION_MONTHLY_CAP": "0", "VISION_EXHAUSTED_POLICY": "reject",
		"VISION_SCREEN_THUMB": "false", "MEDIA_PUBLIC_BASE_URL": "https://cdn.example.com/m/",
	})
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.FeatureMedia.Mode != flags.On || cfg.VisionMonthlyCap != 0 || cfg.VisionExhaustedPolicy != VisionPolicyReject || cfg.VisionScreenThumb {
		t.Errorf("cfg = %+v", cfg)
	}
	if cfg.MediaPublicBaseURL != "https://cdn.example.com/m" {
		t.Errorf("trailing slash must be trimmed: %q", cfg.MediaPublicBaseURL)
	}
}

// TestLoad_MediaInvalid: a bad cap, policy or switch fails startup instead of silently changing what is published.
func TestLoad_MediaInvalid(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"negative cap", map[string]string{"VISION_MONTHLY_CAP": "-1"}, "VISION_MONTHLY_CAP"},
		{"non-numeric cap", map[string]string{"VISION_MONTHLY_CAP": "lots"}, "VISION_MONTHLY_CAP"},
		{"unknown policy", map[string]string{"VISION_EXHAUSTED_POLICY": "allow_all"}, "VISION_EXHAUSTED_POLICY"},
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
