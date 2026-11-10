package config

import (
	"strings"
	"testing"
)

// TestLoad_MediaOrphanSweep: off by default (the kill switch is safe when unset), the three values load, and anything
// else fails startup instead of silently deleting (or not deleting) unattached images. Case-sensitive, not trimmed.
func TestLoad_MediaOrphanSweep(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    MediaOrphanSweep
		wantErr string
	}{
		{name: "default is off", want: MediaOrphanSweepOff},
		{name: "empty is off", env: map[string]string{"MEDIA_ORPHAN_SWEEP": ""}, want: MediaOrphanSweepOff},
		{name: "off", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "off"}, want: MediaOrphanSweepOff},
		{name: "mark", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "mark"}, want: MediaOrphanSweepMark},
		{name: "delete", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "delete"}, want: MediaOrphanSweepDelete},
		{name: "unknown value", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "on"}, wantErr: "MEDIA_ORPHAN_SWEEP"},
		{name: "upper case", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "DELETE"}, wantErr: "MEDIA_ORPHAN_SWEEP"},
		{name: "true is not a mode", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "true"}, wantErr: "MEDIA_ORPHAN_SWEEP"},
		{name: "padded", env: map[string]string{"MEDIA_ORPHAN_SWEEP": "mark "}, wantErr: "MEDIA_ORPHAN_SWEEP"},
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
			if cfg.MediaOrphanSweep != tc.want {
				t.Errorf("MediaOrphanSweep = %q, want %q", cfg.MediaOrphanSweep, tc.want)
			}
		})
	}
}

// TestMediaOrphanSweep_Modes: what each mode lets the sweep do. The zero value behaves as off.
func TestMediaOrphanSweep_Modes(t *testing.T) {
	tests := []struct {
		mode               MediaOrphanSweep
		runs, deletes, bad bool
	}{
		{MediaOrphanSweepOff, false, false, false},
		{MediaOrphanSweepMark, true, false, false},
		{MediaOrphanSweepDelete, true, true, false},
		{"", false, false, true},
		{"bogus", false, false, true},
	}
	for _, tc := range tests {
		if got := tc.mode.Runs(); got != tc.runs {
			t.Errorf("%q.Runs() = %v, want %v", tc.mode, got, tc.runs)
		}
		if got := tc.mode.Deletes(); got != tc.deletes {
			t.Errorf("%q.Deletes() = %v, want %v", tc.mode, got, tc.deletes)
		}
		if _, err := ParseMediaOrphanSweep(string(tc.mode)); (err != nil) != (tc.bad && tc.mode != "") {
			t.Errorf("ParseMediaOrphanSweep(%q) err = %v", tc.mode, err)
		}
	}
}
