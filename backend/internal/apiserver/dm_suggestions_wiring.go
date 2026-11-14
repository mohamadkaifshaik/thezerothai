package apiserver

// dm_suggestions_wiring.go adapts beacons and communities to messaging's ListMessageSuggestions sources (F30). messaging is built
// before both modules, so the adapters are bound late (before ListenAndServe), like the moderation lookups; an unbound source
// is an error, which messaging treats as a best-effort source contributing nothing.

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// planCoParticipants is the method beacons' service exposes for the plan source.
type planCoParticipants interface {
	RecentCoParticipants(ctx context.Context, uid string, since time.Time, maxPlans, perPlan int) ([]beacons.CoParticipant, error)
}

// communityCoMembers is the method communities' service exposes for the community source.
type communityCoMembers interface {
	RecentCoMembers(ctx context.Context, uid string, maxMembers int) ([]communities.CoMember, error)
}

var errSuggestionSourceUnbound = errors.New("message suggestion source is not wired")

// latePlanMates is messaging.PlanSource over beacons, bound after beacons is built.
type latePlanMates struct{ src planCoParticipants }

var _ messaging.PlanSource = (*latePlanMates)(nil)

func (l *latePlanMates) RecentCoParticipants(ctx context.Context, uid string, since time.Time, maxPlans, perPlan int) ([]messaging.PlanMate, error) {
	if l.src == nil {
		return nil, errSuggestionSourceUnbound
	}
	rows, err := l.src.RecentCoParticipants(ctx, uid, since, maxPlans, perPlan)
	if err != nil {
		return nil, err
	}
	out := make([]messaging.PlanMate, len(rows))
	for i, r := range rows {
		out[i] = messaging.PlanMate{UID: r.UID, Activity: beacons.PreviewActivityProto(r.Activity)}
	}
	return out, nil
}

// lateCommunityMates is messaging.CommunitySource over communities, bound after communities is built.
type lateCommunityMates struct{ src communityCoMembers }

var _ messaging.CommunitySource = (*lateCommunityMates)(nil)

func (l *lateCommunityMates) RecentCoMembers(ctx context.Context, uid string, maxMembers int) ([]messaging.CommunityMate, error) {
	if l.src == nil {
		return nil, errSuggestionSourceUnbound
	}
	rows, err := l.src.RecentCoMembers(ctx, uid, maxMembers)
	if err != nil {
		return nil, err
	}
	out := make([]messaging.CommunityMate, len(rows))
	for i, r := range rows {
		out[i] = messaging.CommunityMate{UID: r.UID, CommunityID: r.CommunityID, CommunityName: r.CommunityName}
	}
	return out, nil
}
