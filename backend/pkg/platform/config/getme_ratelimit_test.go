package config

import (
	"strings"
	"testing"
)

// TestLoad_GetMeRateLimit pins RATE_LIMIT_GET_ME_PER_MIN (audit follow-up L1): default 60, overridable, and a zero,
// negative or unparseable value fails startup naming the key.
func TestLoad_GetMeRateLimit(t *testing.T) {
	const key = "RATE_LIMIT_GET_ME_PER_MIN"
	tests := []struct {
		name string
		val  string // "" leaves the key unset
		want int
	}{
		{"default", "", 60},
		{"override", "45", 45},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearEnv(t)
			if tt.val != "" {
				t.Setenv(key, tt.val)
			}
			cfg, err := Load()
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if got := cfg.RateLimit.GetMePerUserPerMinute; got != tt.want {
				t.Errorf("GetMePerUserPerMinute = %d, want %d", got, tt.want)
			}
		})
	}
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
