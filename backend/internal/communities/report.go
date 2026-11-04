package communities

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ErrOwnCommunity is what CommunityReporter answers when the caller owns the community they are reporting (VALIDATION target_id).
var ErrOwnCommunity = errors.New("communities: own community")

// ReportedCommunity is the evidence of one community at report time: the owner (the report's target owner, ""
// when ARCHIVED), the owner's handle ("" when none or not ACTIVE) and the community's public text. No member id and no moderator id.
type ReportedCommunity struct {
	// OwnerUID becomes the report's TargetOwnerID. Never in a response or a log.
	OwnerUID    string
	OwnerHandle string
	Name        string
	Description string
	Rules       []Rule
	CreatedAt   time.Time
}

// CommunityReporter is the part of the service a community report needs. The apiserver adapts it to moderation.CommunityLookup
// (moderation defines the interface and never imports communities); the service returned by New implements it.
type CommunityReporter interface {
	ReportableCommunity(ctx context.Context, callerUID, communityID string) (ReportedCommunity, error)
}

var _ CommunityReporter = (*service)(nil)

// ReportableCommunity implements CommunityReporter. A missing or SUSPENDED community is ErrNotFound, so the caller builds
// the one NOT_FOUND "community not found" for both; an ARCHIVED one is reportable. The caller's own community is ErrOwnCommunity. It
// checks no flag: the report handler has already required `reports` on and `communities` not globally off, so a user dropped from the
// allowlist can still report what they saw. Staleness: the community comes from the 60 s instance cache (D12), the owner's handle from
// the identity directory cache (60 s).
//
// Firestore, worst case: the community 1 (0 warm), the owner's profile 1 (directory cache, 0 warm); none for an ARCHIVED community.
func (s *service) ReportableCommunity(ctx context.Context, callerUID, communityID string) (ReportedCommunity, error) {
	if err := ValidateCommunityID(communityID); err != nil {
		return ReportedCommunity{}, ErrNotFound
	}
	c, err := s.loadCommunity(ctx, communityID)
	if err != nil {
		return ReportedCommunity{}, err
	}
	if c.Status == StatusSuspended {
		return ReportedCommunity{}, ErrNotFound
	}
	if c.OwnerID != "" && c.OwnerID == callerUID {
		return ReportedCommunity{}, ErrOwnCommunity
	}
	out := ReportedCommunity{OwnerUID: c.OwnerID, Name: c.Name, Description: c.Description, Rules: append([]Rule(nil), c.Rules...), CreatedAt: c.CreatedAt}
	if c.OwnerID == "" {
		return out, nil
	}
	profiles, err := s.d.Directory.GetProfiles(ctx, []string{c.OwnerID})
	if err != nil {
		return ReportedCommunity{}, logger.RedactErr(fmt.Errorf("communities: load owner for report: %w", err), c.OwnerID, callerUID)
	}
	if p, ok := profiles[c.OwnerID]; ok && p.Status == identity.AccountStatusActive {
		out.OwnerHandle = p.Handle
	}
	return out, nil
}
