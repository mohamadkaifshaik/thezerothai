package config

// LocationConfig holds the location limits (location design 2026-11-15, section 5.4). The two LocationService buckets
// (RATE_LIMIT_LOCATION_READ_PER_MIN, RATE_LIMIT_LOCATION_WRITE_PER_MIN) live in RateLimit.
type LocationConfig struct {
	// ConsentChangesPerDay is LOCATION_CONSENT_CHANGES_PER_DAY (default 10, > 0): consent records per user per IST day.
	// SetArea counts them inside its transaction when it grants and refuses with LIMIT_REACHED "location_consent_changes"
	// at the cap; ClearArea is never limited by it.
	ConsentChangesPerDay int
	// ConsentMinCopyVersion is LOCATION_CONSENT_MIN_COPY_VERSION (default 1, > 0): the oldest rationale copy a consent may
	// be at. Raising it makes every older consent non-current, so the next SetArea needs a new grant.
	ConsentMinCopyVersion int
	// NearbyKMin is LOCATION_NEARBY_K_MIN (default 5, > 0): the count of live plans in an area from which
	// ListNearbyBeacons shows an exact number (below it, "a few"). Read by beacons in P2 (PR 5).
	NearbyKMin int
}

// loadLocation reads and validates the LOCATION_* keys; a value <= 0 fails startup naming the key.
func loadLocation() (LocationConfig, error) {
	var c LocationConfig
	err := loadPositiveInts([]positiveInt{
		{&c.ConsentChangesPerDay, "LOCATION_CONSENT_CHANGES_PER_DAY", 10},
		{&c.ConsentMinCopyVersion, "LOCATION_CONSENT_MIN_COPY_VERSION", 1},
		{&c.NearbyKMin, "LOCATION_NEARBY_K_MIN", 5},
	})
	return c, err
}
