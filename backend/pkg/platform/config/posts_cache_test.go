package config

import "testing"

// TestLoad_PostsCacheSizes (ADR-0010 D15): defaults 20,000 / 1,000, overridable, and <= 0 fails fast (rule 11).
func TestLoad_PostsCacheSizes(t *testing.T) {
	clearEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.CachePostsEntries != 20_000 || cfg.CacheAuthorRecentEntries != 1_000 {
		t.Fatalf("defaults = %d / %d, want 20000 / 1000", cfg.CachePostsEntries, cfg.CacheAuthorRecentEntries)
	}

	clearEnv(t)
	t.Setenv("CACHE_POSTS_ENTRIES", "500")
	t.Setenv("CACHE_AUTHOR_RECENT_ENTRIES", "50")
	cfg, err = Load()
	if err != nil || cfg.CachePostsEntries != 500 || cfg.CacheAuthorRecentEntries != 50 {
		t.Fatalf("override: %d / %d err=%v", cfg.CachePostsEntries, cfg.CacheAuthorRecentEntries, err)
	}

	for _, key := range []string{"CACHE_POSTS_ENTRIES", "CACHE_AUTHOR_RECENT_ENTRIES"} {
		for _, bad := range []string{"0", "-1", "lots"} {
			t.Run(key+"="+bad, func(t *testing.T) {
				clearEnv(t)
				t.Setenv(key, bad)
				if _, err := Load(); err == nil {
					t.Fatalf("Load() with %s=%s must fail", key, bad)
				}
			})
		}
	}
}
