// moderation_beacons.go adapts the beacons service to moderation.BeaconLookup: the composition root is the one place
// that knows both modules. moderation defines the interface and its own types and never imports beacons; beacons never
// imports moderation.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// lateBeaconLookup is moderation.BeaconLookup bound to the beacons service after it is built: moderation is constructed
// first, the beacons service later, and moderation needs the lookup only per request. Set once at startup, before
// ListenAndServe, and never again (the lateCommunityLookup pattern).
type lateBeaconLookup struct{ r beacons.BeaconReporter }

var _ moderation.BeaconLookup = (*lateBeaconLookup)(nil)

// ReportableBeacon maps beacons' answer to moderation's: ErrNotFound (missing, hidden, blocked, not a member, organiser
// gone) and ErrOwnBeacon become moderation's sentinels (moderation builds the one wire NOT_FOUND from them), the evidence
// is copied field by field, anything else passes through.
func (l *lateBeaconLookup) ReportableBeacon(ctx context.Context, callerUID, beaconID string) (moderation.ReportedBeacon, error) {
	if l.r == nil {
		return moderation.ReportedBeacon{}, errors.New("beacon reports are not wired")
	}
	b, err := l.r.ReportableBeacon(ctx, callerUID, beaconID)
	switch {
	case errors.Is(err, beacons.ErrNotFound):
		return moderation.ReportedBeacon{}, moderation.ErrBeaconNotFound
	case errors.Is(err, beacons.ErrOwnBeacon):
		return moderation.ReportedBeacon{}, moderation.ErrOwnBeacon
	case err != nil:
		return moderation.ReportedBeacon{}, err
	}
	return moderation.ReportedBeacon{
		OrganiserUID: b.OrganiserUID, OrganiserHandle: b.OrganiserHandle, Title: b.Title, Details: b.Details, Venue: b.Venue, CreatedAt: b.CreatedAt,
	}, nil
}
