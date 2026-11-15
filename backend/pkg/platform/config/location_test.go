package config

import (
	"strings"
	"testing"
)

// TestLoad_LocationDefaults pins every location default (design section 5.4).
func TestLoad_LocationDefaults(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.LocationReadPerUserPerMinute != 30 || rl.LocationWritePerUserPerMinute != 6 {
		t.Errorf("location buckets = %d/%d, want 30/6", rl.LocationReadPerUserPerMinute, rl.LocationWritePerUserPerMinute)
	}
	if l := cfg.Location; l.ConsentChangesPerDay != 10 || l.ConsentMinCopyVersion != 1 || l.ConsentCopyVersion != 1 || l.NearbyKMin != 5 {
		t.Errorf("location config = %+v, want 10/1/1/5", l)
	}
}

// TestLoad_LocationOverridesAndValidation: every key is overridable, and a zero, negative or unparseable value fails
// startup naming the key.
func TestLoad_LocationOverridesAndValidation(t *testing.T) {
	clearEnv(t)
	for k, v := range map[string]string{
		"RATE_LIMIT_LOCATION_READ_PER_MIN": "11", "RATE_LIMIT_LOCATION_WRITE_PER_MIN": "3",
		"LOCATION_CONSENT_CHANGES_PER_DAY": "4", "LOCATION_CONSENT_MIN_COPY_VERSION": "2", "LOCATION_CONSENT_COPY_VERSION": "3", "LOCATION_NEARBY_K_MIN": "1",
	} {
		t.Setenv(k, v)
	}
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if rl := cfg.RateLimit; rl.LocationReadPerUserPerMinute != 11 || rl.LocationWritePerUserPerMinute != 3 {
		t.Errorf("buckets = %d/%d", rl.LocationReadPerUserPerMinute, rl.LocationWritePerUserPerMinute)
	}
	if l := cfg.Location; l.ConsentChangesPerDay != 4 || l.ConsentMinCopyVersion != 2 || l.ConsentCopyVersion != 3 || l.NearbyKMin != 1 {
		t.Errorf("location config = %+v", l)
	}
	for _, k := range []string{
		"RATE_LIMIT_LOCATION_READ_PER_MIN", "RATE_LIMIT_LOCATION_WRITE_PER_MIN",
		"LOCATION_CONSENT_CHANGES_PER_DAY", "LOCATION_CONSENT_MIN_COPY_VERSION", "LOCATION_CONSENT_COPY_VERSION", "LOCATION_NEARBY_K_MIN",
	} {
		for _, v := range []string{"0", "-1", "x"} {
			t.Run(k+"="+v, func(t *testing.T) {
				clearEnv(t)
				t.Setenv(k, v)
				if _, err := Load(); err == nil || !strings.Contains(err.Error(), k) {
					t.Fatalf("Load() error = %v, want one naming %s", err, k)
				}
			})
		}
	}
}

// TestLoad_LocationCopyVersionBelowMin: the current copy version cannot be below the minimum.
func TestLoad_LocationCopyVersionBelowMin(t *testing.T) {
	clearEnv(t)
	t.Setenv("LOCATION_CONSENT_MIN_COPY_VERSION", "3")
	t.Setenv("LOCATION_CONSENT_COPY_VERSION", "2")
	if _, err := Load(); err == nil || !strings.Contains(err.Error(), "LOCATION_CONSENT_COPY_VERSION must be >=") {
		t.Fatalf("Load() error = %v", err)
	}
}
