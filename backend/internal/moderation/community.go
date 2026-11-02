// community.go is moderation's side of "report a community" (ADR-0031 D14, plan W5-29): the target type, the consumer-side seam
// through which moderation reaches a community, and its sentinels. moderation never reads communities/* itself: communities implements
// CommunityReporter and the composition root adapts it (the ListLookup and MessageLookup pattern).
package moderation

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TargetCommunity is a report about one community. The doc stores "COMMUNITY"; targetId is the community id (19 digits) and
// targetOwnerId the owner ("" for an ARCHIVED community). Reports of a community's posts use the POST target.
const TargetCommunity TargetType = "COMMUNITY"

// CommunitiesFlagName is the wire name of FEATURE_COMMUNITIES (communities.FlagName; moderation does not import communities). A
// report of a community needs it not globally off, the same rule as MESSAGE and LIST: a user dropped from the allowlist can still
// report what they saw.
const CommunitiesFlagName = "communities"

// CommunityRule is one rule of the reported community, as the reporter saw it.
type CommunityRule struct {
	Title string
	Text  string
}

// ReportedCommunity is what a CommunityLookup answers: the evidence of one community, taken at report time. It holds no member id.
type ReportedCommunity struct {
	// OwnerUID becomes the report's TargetOwnerID ("" for an ARCHIVED community). It never reaches a client or a log.
	OwnerUID string
	// OwnerHandle is the owner's handle ("" when there is no ACTIVE owner).
	OwnerHandle string
	// Name, Description and Rules are the community's public text as the reporter saw it.
	Name        string
	Description string
	Rules       []CommunityRule
	// CreatedAt is when the community was created.
	CreatedAt time.Time
}

// Lookup errors. Sentinels: moderation builds the wire answer, so every "no such community" cause has the same bytes.
var (
	// ErrCommunityNotFound covers a missing or SUSPENDED community.
	ErrCommunityNotFound = errors.New("moderation: community not found")
	// ErrOwnCommunity is a community the caller owns.
	ErrOwnCommunity = errors.New("moderation: own community")
)

// CommunityLookup is the consumer-side seam to communities. ReportableCommunity returns the evidence of the community, or
// ErrCommunityNotFound, ErrOwnCommunity or an infrastructure error. It checks no flag. Firestore, worst case: community 1 + the owner's
// profile 1 (both cache-first, 0 warm); an ARCHIVED community has no owner to read.
type CommunityLookup interface {
	ReportableCommunity(ctx context.Context, callerUID, communityID string) (ReportedCommunity, error)
}

// communityNotFound is the one NOT_FOUND of a community report: the bytes communities.NotFoundError answers on every community RPC.
func communityNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "community not found")
}
