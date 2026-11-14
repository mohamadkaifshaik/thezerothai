package beacons

// coparticipants.go is the beacons half of messaging's ListMessageSuggestions (F30): who the caller was in a recent plan
// with. Read-only over existing rows; nothing is stored. messaging reaches it through a consumer-side seam wired in apiserver,
// never the beacons collections.

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// CoParticipant is one person the caller shared an ended plan with, and that plan's activity.
type CoParticipant struct {
	UID      string
	Activity Activity
}

// maxCoPlans and maxCoPerPlan bound RecentCoParticipants whatever the caller asks (2 plans, 4 rows each).
const (
	maxCoPlans   = 2
	maxCoPerPlan = 4
)

// RecentCoParticipants returns the organiser and the ACCEPTED participants of the caller's most recent ended plans (newest
// end first), the caller excluded, in plan order then the participant page order. Reads: one query of at most maxPlans of the
// caller's past membership rows (organiser or participant role, endAt < now), one GetAll of those beacons, then one participant
// page of at most perPlan ACCEPTED rows for each plan that qualifies: the caller was the organiser or ACCEPTED, the plan ended at
// or after since (the TTL removes rows 30 days after start anyway), it was not cancelled and is not hidden. The caps are
// clamped to 2 plans and 4 rows. A uid may repeat across plans; the caller dedupes.
func (s *service) RecentCoParticipants(ctx context.Context, uid string, since time.Time, maxPlans, perPlan int) ([]CoParticipant, error) {
	maxPlans, perPlan = min(max(maxPlans, 1), maxCoPlans), min(max(perPlan, 1), maxCoPerPlan)
	now := s.now()
	rows, err := s.d.Repo.ListMemberships(ctx, MembershipQuery{UID: uid, Roles: []string{RoleOrganiser, RoleParticipant}, Past: true, Now: now, Limit: maxPlans})
	if err != nil {
		return nil, fmt.Errorf("beacons: co-participants memberships: %w", err)
	}
	var ids []string
	for _, m := range rows {
		if inPlan(m) && !m.EndAt.Before(since) {
			ids = append(ids, m.BeaconID)
		}
	}
	if len(ids) == 0 {
		return nil, nil
	}
	plans, err := s.d.Repo.GetBeacons(ctx, ids)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("beacons: co-participants plans: %w", err), uid)
	}
	var out []CoParticipant
	for _, id := range ids {
		b, ok := plans[id]
		if !ok || b.Hidden || b.Status == StatusCancelled {
			continue
		}
		if b.OrganiserID != "" && b.OrganiserID != uid {
			out = append(out, CoParticipant{UID: b.OrganiserID, Activity: b.Activity})
		}
		ps, err := s.d.Repo.ListParticipants(ctx, ParticipantQuery{BeaconID: id, State: PStateAccepted, Limit: perPlan})
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("beacons: co-participants rows: %w", err), uid)
		}
		for _, p := range ps {
			if p.UID != uid && p.UID != b.OrganiserID {
				out = append(out, CoParticipant{UID: p.UID, Activity: b.Activity})
			}
		}
	}
	return out, nil
}
