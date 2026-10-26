package config

import (
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// MaxSuggestedUserIDs is the most uids SUGGESTED_USER_IDS may list (ADR-0024 D8: the curated fallback, <= 20).
const MaxSuggestedUserIDs = 20

// SuggestionsConfig holds the SUGGESTIONS_* limits and the curated fallback list of GraphService.ListSuggestedUsers
// (ADR-0024 D8, D10). The RPC's per-minute bucket and daily call cap live in RateLimitConfig
// (RATE_LIMIT_SUGGESTIONS_PER_MIN, SUGGESTIONS_CALLS_PER_DAY). These values bound the read cap: friends of friends
// is 1 (interceptor) + 1 (graph) + EdgeLimit (edges) + HydrateMax (profiles) = 42 reads at the defaults, the curated
// path 1 + 1 + HydrateMax = 12.
type SuggestionsConfig struct {
	// SampleFollowees is how many of the caller's newest followees seed the friends-of-friends query
	// (SUGGESTIONS_SAMPLE_FOLLOWEES, default 30, at most 30: the Firestore `in` limit).
	SampleFollowees int
	// EdgeLimit is the Limit of that query (SUGGESTIONS_EDGE_LIMIT, default 30, at most 50: CLAUDE.md rule 5).
	EdgeLimit int
	// HydrateMax is the most candidates hydrated through identity.Directory (SUGGESTIONS_HYDRATE_MAX, default 10, at
	// most 50).
	HydrateMax int
	// MaxResults is the most users one call returns (SUGGESTIONS_MAX_RESULTS, default and maximum 5: the proto clamps
	// max_results to 1..5).
	MaxResults int
	// CacheTTL is how long a viewer's result is kept on the instance (SUGGESTIONS_CACHE_TTL, default 1h). Staleness
	// bound: a suggestion may be up to CacheTTL old; this instance's Follow removes the followed uid at once.
	CacheTTL time.Duration
	// UserIDs is the curated fallback list (SUGGESTED_USER_IDS, comma-separated uids, at most MaxSuggestedUserIDs,
	// each a valid uid, de-duplicated in order; empty means no curated fallback). A Terraform variable, not a secret.
	UserIDs []string
}

// loadSuggestions reads and validates the SUGGESTIONS_* keys and SUGGESTED_USER_IDS. A value outside a bound fails
// startup instead of silently raising the per-call read count above the documented hard cap.
func loadSuggestions() (SuggestionsConfig, error) {
	var (
		c   SuggestionsConfig
		err error
	)
	ints := []struct {
		dst      *int
		key      string
		def      int
		min, max int
	}{
		{&c.SampleFollowees, "SUGGESTIONS_SAMPLE_FOLLOWEES", 30, 1, 30},
		{&c.EdgeLimit, "SUGGESTIONS_EDGE_LIMIT", 30, 1, 50},
		{&c.HydrateMax, "SUGGESTIONS_HYDRATE_MAX", 10, 1, 50},
		{&c.MaxResults, "SUGGESTIONS_MAX_RESULTS", 5, 1, 5},
	}
	for _, f := range ints {
		if *f.dst, err = getInt(f.key, f.def); err != nil {
			return SuggestionsConfig{}, err
		}
		if *f.dst < f.min || *f.dst > f.max {
			return SuggestionsConfig{}, fmt.Errorf("config: %s must be between %d and %d (got %d)", f.key, f.min, f.max, *f.dst)
		}
	}
	if c.CacheTTL, err = getDuration("SUGGESTIONS_CACHE_TTL", time.Hour); err != nil {
		return SuggestionsConfig{}, err
	}
	if c.CacheTTL <= 0 || c.CacheTTL > 24*time.Hour {
		return SuggestionsConfig{}, fmt.Errorf("config: SUGGESTIONS_CACHE_TTL %v must be > 0 and at most 24h", c.CacheTTL)
	}
	seen := map[string]struct{}{}
	for _, uid := range splitCSV(getenv("SUGGESTED_USER_IDS", "")) {
		if !ids.ValidUID(uid) {
			return SuggestionsConfig{}, fmt.Errorf("config: SUGGESTED_USER_IDS has an invalid uid (want 1-128 characters of [A-Za-z0-9-])")
		}
		if _, dup := seen[uid]; dup {
			continue
		}
		seen[uid] = struct{}{}
		c.UserIDs = append(c.UserIDs, uid)
	}
	if len(c.UserIDs) > MaxSuggestedUserIDs {
		return SuggestionsConfig{}, fmt.Errorf("config: SUGGESTED_USER_IDS lists %d uids, at most %d", len(c.UserIDs), MaxSuggestedUserIDs)
	}
	return c, nil
}
