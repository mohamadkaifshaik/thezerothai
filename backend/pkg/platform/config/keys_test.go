package config

import (
	"strings"
	"testing"
)

// TestLoad_KeysRateLimitDefaults pins the key directory's limits: the write bucket 20/min, the read bucket 60/min, the
// claim bucket 20/min, the claim daily cap 300 and the per-target claim daily cap 20.
func TestLoad_KeysRateLimitDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	rl := cfg.RateLimit
	if rl.KeysWritePerUserPerMinute != 20 || rl.KeysReadPerUserPerMinute != 60 || rl.KeysClaimPerUserPerMinute != 20 {
		t.Errorf("keys buckets = %d/%d/%d, want 20/60/20", rl.KeysWritePerUserPerMinute, rl.KeysReadPerUserPerMinute, rl.KeysClaimPerUserPerMinute)
	}
	if rl.KeysClaimsPerDay != 300 {
		t.Errorf("KeysClaimsPerDay = %d, want 300", rl.KeysClaimsPerDay)
	}
	if rl.KeysClaimsPerTargetPerDay != 20 {
		t.Errorf("KeysClaimsPerTargetPerDay = %d, want 20", rl.KeysClaimsPerTargetPerDay)
	}
}

// TestLoad_KeysRateLimitOverridesAndValidation: every key is overridable, and a zero, negative or unparseable value fails
// startup naming the key.
func TestLoad_KeysRateLimitOverridesAndValidation(t *testing.T) {
	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		for k, v := range map[string]string{
			"RATE_LIMIT_KEYS_WRITE_PER_MIN": "7", "RATE_LIMIT_KEYS_READ_PER_MIN": "8", "RATE_LIMIT_KEYS_CLAIM_PER_MIN": "9",
			"KEYS_CLAIMS_PER_DAY": "11", "KEYS_CLAIMS_PER_TARGET_PER_DAY": "12",
		} {
			t.Setenv(k, v)
		}
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		rl := cfg.RateLimit
		if rl.KeysWritePerUserPerMinute != 7 || rl.KeysReadPerUserPerMinute != 8 || rl.KeysClaimPerUserPerMinute != 9 || rl.KeysClaimsPerDay != 11 ||
			rl.KeysClaimsPerTargetPerDay != 12 {
			t.Errorf("override = %d/%d/%d/%d/%d", rl.KeysWritePerUserPerMinute, rl.KeysReadPerUserPerMinute, rl.KeysClaimPerUserPerMinute,
				rl.KeysClaimsPerDay, rl.KeysClaimsPerTargetPerDay)
		}
	})
	for _, key := range []string{
		"RATE_LIMIT_KEYS_WRITE_PER_MIN", "RATE_LIMIT_KEYS_READ_PER_MIN", "RATE_LIMIT_KEYS_CLAIM_PER_MIN", "KEYS_CLAIMS_PER_DAY",
		"KEYS_CLAIMS_PER_TARGET_PER_DAY",
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
}
