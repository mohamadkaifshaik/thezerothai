// moderation_communities.go adapts the communities service to moderation.CommunityLookup: the composition
// root is the one place that knows both modules. moderation defines the interface and its own types and never imports communities;
// communities never imports moderation.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// lateCommunityLookup is moderation.CommunityLookup bound to the communities service after it is built: moderation is constructed
// first, the communities service later, and moderation needs the lookup only per request. Set once at startup, before ListenAndServe,
// and never again (the lateMessageLookup pattern).
type lateCommunityLookup struct{ r communities.CommunityReporter }

var _ moderation.CommunityLookup = (*lateCommunityLookup)(nil)

// ReportableCommunity maps communities' answer to moderation's: ErrNotFound (missing or SUSPENDED) and ErrOwnCommunity become
// moderation's sentinels (moderation builds the one wire NOT_FOUND from them), the evidence is copied field by field, anything else
// passes through.
func (l *lateCommunityLookup) ReportableCommunity(ctx context.Context, callerUID, communityID string) (moderation.ReportedCommunity, error) {
	if l.r == nil {
		return moderation.ReportedCommunity{}, errors.New("community reports are not wired")
	}
	c, err := l.r.ReportableCommunity(ctx, callerUID, communityID)
	switch {
	case errors.Is(err, communities.ErrNotFound):
		return moderation.ReportedCommunity{}, moderation.ErrCommunityNotFound
	case errors.Is(err, communities.ErrOwnCommunity):
		return moderation.ReportedCommunity{}, moderation.ErrOwnCommunity
	case err != nil:
		return moderation.ReportedCommunity{}, err
	}
	rules := make([]moderation.CommunityRule, len(c.Rules))
	for i, r := range c.Rules {
		rules[i] = moderation.CommunityRule(r)
	}
	return moderation.ReportedCommunity{OwnerUID: c.OwnerUID, OwnerHandle: c.OwnerHandle, Name: c.Name, Description: c.Description, Rules: rules, CreatedAt: c.CreatedAt}, nil
}
