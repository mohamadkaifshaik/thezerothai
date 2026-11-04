package communities

import (
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// ForbiddenReason is the metadata["reason"] of PERMISSION_DENIED + ERROR_REASON_FORBIDDEN (communities.proto).
// Clients show one fixed message per reason. FORBIDDEN is never an account suspension (that is ACCOUNT_RESTRICTED).
type ForbiddenReason string

const (
	// ReasonBanned: a BANNED user joins or posts.
	ReasonBanned ForbiddenReason = "banned"
	// ReasonNotMember: a non-member or BANNED user posts or replies.
	ReasonNotMember ForbiddenReason = "not_member"
	// ReasonNotModerator: a member, a banned user or an outsider hides, restores, bans, unbans, asks for the BANNED member page or
	// reads the moderation log.
	ReasonNotModerator ForbiddenReason = "not_moderator"
	// ReasonNotOwner: anyone but the owner updates the community or appoints or removes a moderator, or a moderator acts on the
	// owner or on a moderator.
	ReasonNotOwner ForbiddenReason = "not_owner"
	// ReasonNotCreator: CreateCommunity by a caller outside COMMUNITY_CREATORS.
	ReasonNotCreator ForbiddenReason = "not_creator"
)

// StateReason is the metadata["reason"] of FAILED_PRECONDITION + ERROR_REASON_COMMUNITY_STATE.
type StateReason string

const (
	// StateOwner: the owner leaves (the owner cannot leave).
	StateOwner StateReason = "owner"
	// StateModerator: the owner bans a moderator (remove the role first).
	StateModerator StateReason = "moderator"
	// StateArchived: a write to an ARCHIVED community.
	StateArchived StateReason = "community_archived"
)

// Forbidden is PERMISSION_DENIED + FORBIDDEN with metadata["reason"] = reason. The message is fixed and generic: the client
// branches on the reason.
func Forbidden(reason ForbiddenReason) *apierr.Error {
	return apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_FORBIDDEN, "you cannot do that in this community").
		WithMeta("reason", string(reason))
}

// StateConflict is FAILED_PRECONDITION + COMMUNITY_STATE with metadata["reason"] = reason.
func StateConflict(reason StateReason) *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_COMMUNITY_STATE, "the community state does not allow that").
		WithMeta("reason", string(reason))
}

// Names of the fixed caps behind FAILED_PRECONDITION + LIMIT_REACHED, metadata["limit"] (communities.proto).
const (
	// LimitOwned is COMMUNITIES_MAX_OWNED (2 owned communities per creator, lifetime).
	LimitOwned = "communities_owned"
	// LimitJoined is COMMUNITIES_MAX_JOINED (50 joined communities per user).
	LimitJoined = "communities_joined"
	// LimitModerators is COMMUNITY_MAX_MODERATORS (10 per community).
	LimitModerators = "community_moderators"
)

// LimitReached is FAILED_PRECONDITION + LIMIT_REACHED with metadata["limit"] = limit (one of the Limit* names).
func LimitReached(limit string) *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit reached").
		WithMeta("limit", limit)
}
