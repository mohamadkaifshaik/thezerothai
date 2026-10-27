package config

import (
	"strings"
	"testing"
)

// TestLoad_ProfileMediaRetire (ADR-0024 Amendment 1 A4): off by default, the three values load, and anything else fails
// startup instead of silently deleting (or not deleting) public images. The value is case-sensitive and not trimmed.
func TestLoad_ProfileMediaRetire(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    ProfileMediaRetire
		wantErr string
	}{
		{name: "default is off", want: ProfileMediaRetireOff},
		{name: "empty is off", env: map[string]string{"PROFILE_MEDIA_RETIRE": ""}, want: ProfileMediaRetireOff},
		{name: "off", env: map[string]string{"PROFILE_MEDIA_RETIRE": "off"}, want: ProfileMediaRetireOff},
		{name: "banner", env: map[string]string{"PROFILE_MEDIA_RETIRE": "banner"}, want: ProfileMediaRetireBanner},
		{name: "all", env: map[string]string{"PROFILE_MEDIA_RETIRE": "all"}, want: ProfileMediaRetireAll},
		{name: "unknown value", env: map[string]string{"PROFILE_MEDIA_RETIRE": "avatar"}, wantErr: "PROFILE_MEDIA_RETIRE"},
		{name: "upper case", env: map[string]string{"PROFILE_MEDIA_RETIRE": "ALL"}, wantErr: "PROFILE_MEDIA_RETIRE"},
		{name: "true is not a mode", env: map[string]string{"PROFILE_MEDIA_RETIRE": "true"}, wantErr: "PROFILE_MEDIA_RETIRE"},
		{name: "padded", env: map[string]string{"PROFILE_MEDIA_RETIRE": " all"}, wantErr: "PROFILE_MEDIA_RETIRE"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			clearEnv(t)
			t.Setenv("ENV", "local")
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			cfg, err := Load()
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("Load() err = %v, want it to mention %s", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.ProfileMediaRetire != tc.want {
				t.Errorf("ProfileMediaRetire = %q, want %q", cfg.ProfileMediaRetire, tc.want)
			}
		})
	}
}

// TestProfileMediaRetire_Allows is the one rule publish, handler and opsctl share: off allows nothing, banner only
// BANNER, all both profile purposes; a POST image (or anything unknown) is never retired by this step.
func TestProfileMediaRetire_Allows(t *testing.T) {
	tests := []struct {
		mode    ProfileMediaRetire
		purpose string
		want    bool
	}{
		{ProfileMediaRetireOff, "BANNER", false},
		{ProfileMediaRetireOff, "AVATAR", false},
		{ProfileMediaRetireBanner, "BANNER", true},
		{ProfileMediaRetireBanner, "AVATAR", false},
		{ProfileMediaRetireAll, "BANNER", true},
		{ProfileMediaRetireAll, "AVATAR", true},
		{ProfileMediaRetireAll, "POST", false},
		{ProfileMediaRetireAll, "", false},
		{ProfileMediaRetireBanner, "banner", false},
		{"", "BANNER", false}, // the zero value is off: a Jobs built without the switch deletes nothing
		{"bogus", "BANNER", false},
	}
	for _, tc := range tests {
		if got := tc.mode.Allows(tc.purpose); got != tc.want {
			t.Errorf("%q.Allows(%q) = %v, want %v", tc.mode, tc.purpose, got, tc.want)
		}
	}
}

func TestParseProfileMediaRetire(t *testing.T) {
	if m, err := ParseProfileMediaRetire(""); err != nil || m != ProfileMediaRetireOff {
		t.Errorf("empty = %q, %v; want off", m, err)
	}
	if _, err := ParseProfileMediaRetire("nope"); err == nil {
		t.Error("an unknown value must be an error")
	}
}
