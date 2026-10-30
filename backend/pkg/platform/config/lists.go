package config

// ListsConfig holds the list values that are neither a rate limit nor a daily quota (ADR-0030 D10). The list buckets and the
// daily mutation cap are RateLimitConfig fields; the create and add quotas are QuotaConfig fields. Every value is > 0: a 0
// would lock every user out of the feature or disable a cap, so startup fails instead.
type ListsConfig struct {
	// MaxPerUser is the most lists one account owns (LISTS_MAX_PER_USER, default 20), checked exactly with a count() inside the
	// CreateList transaction.
	MaxPerUser int
	// MaxMembers is the most members one list holds (LIST_MAX_MEMBERS, default 150), checked exactly against the list doc in
	// the AddListMember transaction (ADR-0030 F2).
	MaxMembers int
	// HomeTabsMaxPinned is the most pinned Home tabs (HOME_TABS_MAX_PINNED, default 5), checked exactly by SetHomeTabs (F5).
	HomeTabsMaxPinned int
	// CacheEntries is the size of the per-instance list-doc cache (CACHE_LISTS_ENTRIES, default 2,000; 60 s TTL; a doc is at
	// most about 8 KB in memory, so about 16 MB at the default).
	CacheEntries int
}

// loadLists reads and validates the LISTS_MAX_PER_USER, LIST_MAX_MEMBERS, HOME_TABS_MAX_PINNED and CACHE_LISTS_ENTRIES keys;
// a value <= 0 fails startup naming the key.
func loadLists() (ListsConfig, error) {
	var c ListsConfig
	err := loadPositiveInts([]positiveInt{
		{&c.MaxPerUser, "LISTS_MAX_PER_USER", 20},
		{&c.MaxMembers, "LIST_MAX_MEMBERS", 150},
		{&c.HomeTabsMaxPinned, "HOME_TABS_MAX_PINNED", 5},
		{&c.CacheEntries, "CACHE_LISTS_ENTRIES", 2000},
	})
	return c, err
}
