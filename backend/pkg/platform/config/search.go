package config

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// SearchConfig holds the SEARCH_*-adjacent values of search and trends that are neither a rate limit nor a daily cap
// (ADR-0028 D9). The per-minute buckets and the shared daily cap live in RateLimitConfig (SearchPeoplePerUserPerMinute,
// SearchPostsPerUserPerMinute, SearchCallsPerDay). Every number is > 0: a 0 would disable a cache or lock the feature out,
// so startup fails instead.
type SearchConfig struct {
	// PrefixCacheEntries is the size of the per-instance handle-prefix cache keyed by (prefix, limit)
	// (CACHE_SEARCH_PREFIX_ENTRIES, default 2,000; 60 s TTL).
	PrefixCacheEntries int
	// TagCacheEntries is the size of the per-instance hashtag cache holding the newest 30 posts per tag
	// (CACHE_SEARCH_TAG_ENTRIES, default 500; 60 s TTL).
	TagCacheEntries int
	// TrendsMinAuthors is the fewest distinct authors a tag needs to trend (TRENDS_MIN_AUTHORS, default 3).
	TrendsMinAuthors int
	// TrendsMaxPostsPerRun caps the posts one refresh run scans (TRENDS_MAX_POSTS_PER_RUN, default 2,000).
	TrendsMaxPostsPerRun int
	// TrendsMinInterval is the shortest time between two refreshes: a run within it of the last list is skipped as
	// "fresh" (TRENDS_MIN_INTERVAL, default 12h; 50m with the hourly option, ADR-0028 D6). Must be > 0.
	TrendsMinInterval time.Duration
	// TrendsDenylist holds tag bodies that never trend (TRENDS_DENYLIST, comma-separated, default empty). Entries are
	// trimmed, lower-cased and stripped of one leading '#'; empty entries are dropped. Further normalisation is the
	// refresher's (ADR-0028 D6).
	TrendsDenylist []string
}

// loadSearch reads and validates the search and trends keys; a number or duration <= 0 fails startup naming the key.
func loadSearch() (SearchConfig, error) {
	var c SearchConfig
	for _, f := range []struct {
		dst *int
		key string
		def int
	}{
		{&c.PrefixCacheEntries, "CACHE_SEARCH_PREFIX_ENTRIES", 2000},
		{&c.TagCacheEntries, "CACHE_SEARCH_TAG_ENTRIES", 500},
		{&c.TrendsMinAuthors, "TRENDS_MIN_AUTHORS", 3},
		{&c.TrendsMaxPostsPerRun, "TRENDS_MAX_POSTS_PER_RUN", 2000},
	} {
		v, err := getInt(f.key, f.def)
		if err != nil {
			return SearchConfig{}, err
		}
		if v <= 0 {
			return SearchConfig{}, fmt.Errorf("config: %s must be > 0 (got %d)", f.key, v)
		}
		*f.dst = v
	}
	d, err := getDuration("TRENDS_MIN_INTERVAL", 12*time.Hour)
	if err != nil {
		return SearchConfig{}, err
	}
	if d <= 0 {
		return SearchConfig{}, fmt.Errorf("config: TRENDS_MIN_INTERVAL must be > 0 (got %v)", d)
	}
	c.TrendsMinInterval = d
	for _, t := range splitCSV(os.Getenv("TRENDS_DENYLIST")) {
		t = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(t)), "#")
		if t != "" {
			c.TrendsDenylist = append(c.TrendsDenylist, t)
		}
	}
	return c, nil
}
