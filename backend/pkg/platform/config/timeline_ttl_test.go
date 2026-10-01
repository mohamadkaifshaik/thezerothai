package config

import (
	"testing"
	"time"
)

// TestLoad_TimelineTokenTTL (ADR-0010 D14): default 720h, overridable, and a value below 24h (including zero and
// negative values) or an unparsable one fails startup.
func TestLoad_TimelineTokenTTL(t *testing.T) {
	tests := []struct {
		name    string
		env     string
		want    time.Duration
		wantErr bool
	}{
		{"default", "", 720 * time.Hour, false},
		{"override", "48h", 48 * time.Hour, false},
		{"exactly 24h", "24h", 24 * time.Hour, false},
		{"just under 24h", "23h59m59s", 0, true},
		{"zero", "0s", 0, true},
		{"negative", "-720h", 0, true},
		{"not a duration", "30d", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			if tt.env != "" {
				t.Setenv("TIMELINE_TOKEN_TTL", tt.env)
			}
			cfg, err := Load()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Load() error = %v, wantErr %v", err, tt.wantErr)
			}
			if err == nil && cfg.TimelineTokenTTL != tt.want {
				t.Fatalf("TimelineTokenTTL = %v, want %v", cfg.TimelineTokenTTL, tt.want)
			}
		})
	}
}
