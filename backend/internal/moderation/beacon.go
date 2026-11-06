// beacon.go is moderation's side of "report a beacon" (docs/beacons-plan.md PR 4): the target type, the shape check of
// the beacon id and the consumer-side seam through which moderation reaches a beacon. moderation never reads beacons/*
// itself: beacons implements BeaconReporter and the composition root adapts it (the ListLookup pattern).
package moderation

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TargetBeacon is a report about one beacon. The doc stores "BEACON"; targetId is the beacon id (19 digits, the post id shape).
const TargetBeacon TargetType = "BEACON"

// BeaconsFlagName is the wire name of FEATURE_BEACONS (beacons.FlagName; moderation does not import beacons). A report of a
// beacon needs it not globally off, the LIST rule: a user dropped from the allowlist can still report what they saw.
const BeaconsFlagName = "beacons"

// ReportedBeacon is what a BeaconLookup answers: the evidence of one beacon, taken at report time (R16). It holds no
// participant and no community id.
type ReportedBeacon struct {
	// OrganiserUID becomes the report's TargetOwnerID. It never reaches a client or a log.
	OrganiserUID string
	// OrganiserHandle is the organiser's handle.
	OrganiserHandle string
	// Title, Details and Venue are the beacon's text as the reporter saw it.
	Title   string
	Details string
	Venue   string
	// CreatedAt is when the beacon was created.
	CreatedAt time.Time
}

// Lookup errors. Sentinels: moderation builds the wire answer, so every "no such beacon" cause has the same bytes.
var (
	// ErrBeaconNotFound covers every way a beacon can be unreportable for this caller: missing, malformed id, hidden, a
	// block in either direction with the organiser, an organiser who is not ACTIVE, or a community the caller is not a
	// member of (R17: the lookup leaks no membership).
	ErrBeaconNotFound = errors.New("moderation: beacon not found")
	// ErrOwnBeacon is a beacon the caller organises.
	ErrOwnBeacon = errors.New("moderation: own beacon")
)

// BeaconLookup is the consumer-side seam to beacons. ReportableBeacon answers whether callerUID may see the beacon and is
// not its organiser, and returns its evidence. It returns ErrBeaconNotFound, ErrOwnBeacon or an infrastructure error. It
// checks no flag. It reads the beacon, the caller's graph, the community role and the organiser's user (all cache-first).
type BeaconLookup interface {
	ReportableBeacon(ctx context.Context, callerUID, beaconID string) (ReportedBeacon, error)
}

// beaconNotFound is the one NOT_FOUND of a beacon report (byte-identical for every cause, and the same bytes GetBeacon answers).
func beaconNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "beacon not found")
}
