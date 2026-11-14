package communities

// comembers.go is the communities half of messaging's ListMessageSuggestions (F30): people who recently joined the community
// the caller joined most recently. Read-only; nothing is stored. messaging reaches it through a consumer-side seam wired in
// apiserver, never the communities collections.

import (
	"context"
	"errors"
	"fmt"
)

// CoMember is one JOINED member of a community the caller is in, with that community's id and current name.
type CoMember struct {
	UID, CommunityID, CommunityName string
}

// maxCoMembers bounds RecentCoMembers whatever the caller asks.
const maxCoMembers = 6

// RecentCoMembers returns the newest JOINED members (one page of at most maxMembers, clamped to 6, the caller then excluded) of the community the caller
// joined most recently (the last entry of communityMemberships.joined, cached 60 s), when that community is ACTIVE (the
// community document, cached 60 s). Reads: the memberships doc and the community doc on a cold cache, and one member page query.
// No block filtering here: the consumer applies its own rules.
func (s *service) RecentCoMembers(ctx context.Context, uid string, maxMembers int) ([]CoMember, error) {
	maxMembers = min(max(maxMembers, 1), maxCoMembers)
	ms, err := s.membershipsCached(ctx, uid)
	if err != nil {
		return nil, fmt.Errorf("communities: co-members memberships: %w", err)
	}
	if len(ms.Joined) == 0 {
		return nil, nil
	}
	cid := ms.Joined[len(ms.Joined)-1]
	c, err := s.loadCommunity(ctx, cid)
	if errors.Is(err, ErrNotFound) {
		return nil, nil // a community that is gone has no co-members
	}
	if err != nil {
		return nil, fmt.Errorf("communities: co-members community: %w", err)
	}
	if c.Status != StatusActive {
		return nil, nil
	}
	rows, err := s.d.Repo.ListMembers(ctx, MembersQuery{CommunityID: cid, Limit: maxMembers})
	if err != nil {
		return nil, fmt.Errorf("communities: co-members page: %w", err)
	}
	out := make([]CoMember, 0, len(rows))
	for _, r := range rows {
		if r.UID != uid {
			out = append(out, CoMember{UID: r.UID, CommunityID: cid, CommunityName: c.Name})
		}
	}
	return out, nil
}
