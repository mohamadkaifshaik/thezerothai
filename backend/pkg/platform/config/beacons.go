package config

import "fmt"

// MaxBeaconOpenSpotsCeiling bounds BEACONS_MAX_OPEN_SPOTS: a beacon is a small plan, and every accepted participant is
// one row the organiser's view hydrates, so the cap cannot be raised past this without a design change.
const MaxBeaconOpenSpotsCeiling = 50

// BeaconsConfig holds the beacon caps (docs/beacons-plan.md section 5). The beacon buckets and the daily create cap
// live in RateLimit.
type BeaconsConfig struct {
	// MaxOpenPerUser is the most OPEN or FULL beacons one organiser holds (BEACONS_MAX_OPEN_PER_USER, default 5), checked
	// exactly with a count() inside the CreateBeacon transaction; LIMIT_REACHED "beacons_open" past it.
	MaxOpenPerUser int
	// MaxPendingRequests is the most REQUESTED participant rows one user holds across beacons
	// (BEACONS_MAX_PENDING_REQUESTS, default 10); LIMIT_REACHED "beacon_requests_pending" past it.
	MaxPendingRequests int
	// MaxOpenSpots is the most seats beyond the organiser a beacon offers (BEACONS_MAX_OPEN_SPOTS, default 20, at most
	// MaxBeaconOpenSpotsCeiling); open_spots above it => LIMIT_REACHED "beacon_participants".
	MaxOpenSpots int
}

// loadBeacons reads and validates the BEACONS_MAX_OPEN_PER_USER, BEACONS_MAX_PENDING_REQUESTS and BEACONS_MAX_OPEN_SPOTS
// keys; a value <= 0 fails startup naming the key, and BEACONS_MAX_OPEN_SPOTS above MaxBeaconOpenSpotsCeiling (50) does
// too.
func loadBeacons() (BeaconsConfig, error) {
	var c BeaconsConfig
	err := loadPositiveInts([]positiveInt{
		{&c.MaxOpenPerUser, "BEACONS_MAX_OPEN_PER_USER", 5},
		{&c.MaxPendingRequests, "BEACONS_MAX_PENDING_REQUESTS", 10},
		{&c.MaxOpenSpots, "BEACONS_MAX_OPEN_SPOTS", 20},
	})
	if err == nil && c.MaxOpenSpots > MaxBeaconOpenSpotsCeiling {
		err = fmt.Errorf("config: BEACONS_MAX_OPEN_SPOTS must be 1..%d (got %d)", MaxBeaconOpenSpotsCeiling, c.MaxOpenSpots)
	}
	return c, err
}
