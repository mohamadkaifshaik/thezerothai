package config

import (
	"strings"
	"testing"
)

// TestLoad_FollowListAndSearchPeopleCaps: the SearchPeople and follow-list daily caps default to 1000 under their own keys,
// are overridable, must be > 0, and are not driven by the old SEARCH_CALLS_PER_DAY and LIST_CALLS_PER_DAY keys that
// deployed environments may still set.
func TestLoad_FollowListAndSearchPeopleCaps(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.RateLimit.SearchPeopleCallsPerDay != 1000 || cfg.RateLimit.FollowListCallsPerDay != 1000 {
		t.Errorf("defaults = %d/%d, want 1000/1000", cfg.RateLimit.SearchPeopleCallsPerDay, cfg.RateLimit.FollowListCallsPerDay)
	}

	t.Run("old keys are ignored", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SEARCH_CALLS_PER_DAY", "300")
		t.Setenv("LIST_CALLS_PER_DAY", "100")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if cfg.RateLimit.SearchPeopleCallsPerDay != 1000 || cfg.RateLimit.FollowListCallsPerDay != 1000 {
			t.Errorf("old keys changed the new caps: %d/%d, want 1000/1000", cfg.RateLimit.SearchPeopleCallsPerDay, cfg.RateLimit.FollowListCallsPerDay)
		}
	})

	t.Run("overrides", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("SEARCH_PEOPLE_CALLS_PER_DAY", "7")
		t.Setenv("FOLLOW_LIST_CALLS_PER_DAY", "8")
		cfg, err := Load()
		if err != nil {
			t.Fatalf("Load() error = %v", err)
		}
		if cfg.RateLimit.SearchPeopleCallsPerDay != 7 || cfg.RateLimit.FollowListCallsPerDay != 8 {
			t.Errorf("overrides = %d/%d, want 7/8", cfg.RateLimit.SearchPeopleCallsPerDay, cfg.RateLimit.FollowListCallsPerDay)
		}
	})

	for _, key := range []string{"SEARCH_PEOPLE_CALLS_PER_DAY", "FOLLOW_LIST_CALLS_PER_DAY"} {
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
