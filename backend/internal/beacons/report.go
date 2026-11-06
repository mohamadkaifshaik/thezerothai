package beacons

import (
	"context"
	"errors"
	"time"
)

// ErrOwnBeacon is what BeaconReporter answers when the caller organises the beacon they are reporting.
var ErrOwnBeacon = errors.New("beacons: own beacon")

// ReportedBeacon is the evidence of one beacon at report time (R16): the organiser (the report's target owner), the
// organiser's handle and the beacon's title, details and venue. No participant, no community id: the evidence holds no uid
// but OrganiserUID.
type ReportedBeacon struct {
	// OrganiserUID becomes the report's TargetOwnerID. Never in a response or a log.
	OrganiserUID    string
	OrganiserHandle string
	Title           string
	Details         string
	Venue           string
	CreatedAt       time.Time
}

// BeaconReporter is the part of the service a beacon report needs. The apiserver adapts it to moderation.BeaconLookup
// (moderation defines the interface and never imports beacons); the service returned by New implements it.
type BeaconReporter interface {
	ReportableBeacon(ctx context.Context, callerUID, beaconID string) (ReportedBeacon, error)
}

var _ BeaconReporter = (*service)(nil)

// ReportableBeacon implements BeaconReporter: the caller may report exactly the beacons they may see (a missing,
// malformed-id, hidden, blocked or inactive-organiser beacon is ErrNotFound after the same reads as GetBeacon, and so is
// a community beacon the caller is not a JOINED member of, R17: a report lookup must not leak membership). The caller's
// own beacon is ErrOwnBeacon. It checks no flag: the report handler has already required `reports` on and `beacons` not
// globally off, so a user dropped from the allowlist can still report what they saw.
func (s *service) ReportableBeacon(ctx context.Context, callerUID, beaconID string) (ReportedBeacon, error) {
	a, err := s.resolve(ctx, callerUID, beaconID)
	if err != nil {
		if errors.Is(err, ErrNotMember) {
			return ReportedBeacon{}, ErrNotFound
		}
		return ReportedBeacon{}, err
	}
	if a.isOrganiser {
		return ReportedBeacon{}, ErrOwnBeacon
	}
	b := a.beacon
	return ReportedBeacon{
		OrganiserUID: b.OrganiserID, OrganiserHandle: a.organiser.Handle, Title: b.Title, Details: b.Details, Venue: b.Venue, CreatedAt: b.CreatedAt,
	}, nil
}
