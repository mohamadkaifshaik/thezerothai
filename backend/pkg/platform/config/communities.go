package config

import (
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// MaxCommunityCreators is the most uids COMMUNITY_CREATORS may hold: creation is a launch-time allowlist of the
// founders, not a rollout, so a longer list is a mistake and fails startup.
const MaxCommunityCreators = 10

// CommunitiesConfig holds the community values that are neither a rate limit nor a daily cap. The
// community buckets and the two daily caps are RateLimitConfig fields. Every count is > 0: a 0 would lock every user out of the feature or disable a cap,
// so startup fails instead.
type CommunitiesConfig struct {
	// Creators are the uids that may call CreateCommunity (COMMUNITY_CREATORS, at most MaxCommunityCreators, each ids.ValidUID,
	// duplicates dropped, default none). CreateCommunity also needs FEATURE_COMMUNITIES on for the caller. Only the count is ever
	// logged, never the uids.
	Creators []string
	// MaxOwned is the most communities one account owns, lifetime (COMMUNITIES_MAX_OWNED, default 2), checked exactly against the
	// memberships doc in the CreateCommunity transaction.
	MaxOwned int
	// MaxJoined is the most communities one account is a member of (COMMUNITIES_MAX_JOINED, default 50), exact.
	MaxJoined int
	// MaxModerators is the most moderators one community has (COMMUNITY_MAX_MODERATORS, default 10), exact.
	MaxModerators int
	// MaxRules is the most rules one community lists (COMMUNITY_MAX_RULES, default 10), exact.
	MaxRules int
	// RecentRemovalsMax and ModlogMax are the sizes of the capped arrays on the community doc (COMMUNITY_RECENT_REMOVALS_MAX 50,
	// COMMUNITY_MODLOG_MAX 100).
	RecentRemovalsMax int
	ModlogMax         int
	// CacheEntries is the per-instance community-doc cache (CACHE_COMMUNITIES_ENTRIES, default 200; 60 s TTL), FeedCacheEntries the
	// shared community feed entries (CACHE_COMMUNITY_FEED_ENTRIES, default 100; newest 30 each, 60 s) and MembersCacheEntries the
	// member-doc cache (CACHE_COMMUNITY_MEMBERS_ENTRIES, default 5,000; 60 s on read paths, posting reads it fresh).
	CacheEntries        int
	FeedCacheEntries    int
	MembersCacheEntries int
}

// loadCommunities reads and validates COMMUNITY_CREATORS and the community count keys. An invalid uid, more than
// MaxCommunityCreators uids, or a count <= 0 fails startup naming the key. The error never echoes a uid.
func loadCommunities() (CommunitiesConfig, error) {
	var c CommunitiesConfig
	if err := loadPositiveInts([]positiveInt{
		{&c.MaxOwned, "COMMUNITIES_MAX_OWNED", 2},
		{&c.MaxJoined, "COMMUNITIES_MAX_JOINED", 50},
		{&c.MaxModerators, "COMMUNITY_MAX_MODERATORS", 10},
		{&c.MaxRules, "COMMUNITY_MAX_RULES", 10},
		{&c.RecentRemovalsMax, "COMMUNITY_RECENT_REMOVALS_MAX", 50},
		{&c.ModlogMax, "COMMUNITY_MODLOG_MAX", 100},
		{&c.CacheEntries, "CACHE_COMMUNITIES_ENTRIES", 200},
		{&c.FeedCacheEntries, "CACHE_COMMUNITY_FEED_ENTRIES", 100},
		{&c.MembersCacheEntries, "CACHE_COMMUNITY_MEMBERS_ENTRIES", 5000},
	}); err != nil {
		return CommunitiesConfig{}, err
	}
	seen := map[string]struct{}{}
	for _, uid := range splitCSV(getenv("COMMUNITY_CREATORS", "")) {
		if !ids.ValidUID(uid) {
			return CommunitiesConfig{}, fmt.Errorf("config: COMMUNITY_CREATORS has an invalid uid (want 1-128 characters of [A-Za-z0-9-])")
		}
		if _, dup := seen[uid]; dup {
			continue
		}
		seen[uid] = struct{}{}
		c.Creators = append(c.Creators, uid)
	}
	if len(c.Creators) > MaxCommunityCreators {
		return CommunitiesConfig{}, fmt.Errorf("config: COMMUNITY_CREATORS lists %d uids, at most %d", len(c.Creators), MaxCommunityCreators)
	}
	return c, nil
}
