package beacons

import "github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"

// This file is the part of the module another binary (opsctl) or module may use besides the seams: the one NOT_FOUND
// and the beacon_id check. Each is the same code the RPCs run, exported rather than copied, so they cannot drift apart.

// NotFoundError is the one NOT_FOUND of the module: byte-identical for a missing, hidden, blocked or not-visible beacon.
func NotFoundError() *apierr.Error { return notFound() }

// ValidateBeaconID is the 0-read VALIDATION field=beacon_id check every beacon RPC runs before a read.
func ValidateBeaconID(id string) error { return validateBeaconID(id) }
