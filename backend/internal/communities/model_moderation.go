package communities

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Defaults for the moderation caps when a Limits value is zero (the config defaults, COMMUNITY_MAX_MODERATORS, COMMUNITY_RECENT_REMOVALS_MAX
// and COMMUNITY_MODLOG_MAX): a zero cap would make every append drop everything.
const (
	defaultMaxModerators     = 10
	defaultRecentRemovalsMax = 50
	defaultModlogCap         = 100
	// LogPageMax is the most entries ListModerationLog returns in one page (the default too).
	LogPageMax = 25
)

// Moderation is the owner and moderator surface of a community (ADR-0031 D1, D4, D5): the four calls behind HideCommunityPost,
// RestoreCommunityPost, SetMemberRole and ListModerationLog. The capped arrays (recentRemovals, modlog) sit behind it, so a later
// `modlog` collection changes no caller. *service implements it, and Service embeds it.
type Moderation interface {
	// HideCommunityPost removes the post from the community's view (A12). Owner or moderator (FORBIDDEN not_moderator otherwise), ARCHIVED is
	// COMMUNITY_STATE, a post that was not created into this community is NOT_FOUND. Firestore (interceptor excluded): reads 4 (idempotency,
	// community, actor memberships, post; all fresh); writes 3 (post, community, idempotency) + 1 on the actor's first log entry in this community
	// (memberships modlogged); already hidden 1 write (the idempotency doc); replay 1 read, 0 writes; refused 0 writes.
	HideCommunityPost(ctx context.Context, uid string, in PostActionInput) error
	// RestoreCommunityPost is the reverse of HideCommunityPost, with the same roles, errors and budget.
	RestoreCommunityPost(ctx context.Context, uid string, in PostActionInput) error
	// SetMemberRole bans, unbans, appoints or removes a moderator (D4). Firestore (interceptor excluded): reads 6 (target profile via the
	// directory cache, idempotency, community, target member doc, target memberships, actor memberships); writes BAN 4, UNBAN 3 + 1 delete,
	// MAKE or REMOVE_MODERATOR 2 to 3, +1 on the actor's first log entry in this community, worst 5; a request that changes nothing 1 write (the
	// idempotency doc); replay 3 reads, 0 writes; refused 0 writes.
	SetMemberRole(ctx context.Context, uid string, in RoleInput) (RoleResult, error)
	// ListModerationLog is one page of the log, newest first, for the owner and moderators (FORBIDDEN not_moderator otherwise). Firestore
	// (interceptor excluded): reads 1 community + <= 50 profiles cold, 0 warm; writes 0.
	ListModerationLog(ctx context.Context, uid string, in LogInput) (LogPage, error)
}

// PostActionInput is a HideCommunityPost or RestoreCommunityPost request after the transport layer.
type PostActionInput struct {
	Key         string
	CommunityID string
	PostID      string
}

// RoleAction is what SetMemberRole does to its target.
type RoleAction int

// The four actions of communities.proto MemberRoleAction (UNSPECIFIED is a VALIDATION error before it gets here).
const (
	RoleActionNone RoleAction = iota
	RoleActionBan
	RoleActionUnban
	RoleActionMakeModerator
	RoleActionRemoveModerator
)

func (a RoleAction) String() string {
	switch a {
	case RoleActionBan:
		return "ban"
	case RoleActionUnban:
		return "unban"
	case RoleActionMakeModerator:
		return "make_moderator"
	case RoleActionRemoveModerator:
		return "remove_moderator"
	}
	return "none"
}

// RoleInput is a SetMemberRole request after the transport layer.
type RoleInput struct {
	Key         string
	CommunityID string
	UserID      string
	Action      RoleAction
}

// RoleResult is what SetMemberRole answers: the target's role after the call and the community as the caller sees it.
type RoleResult struct {
	Role Role
	View View
}

// LogInput is a ListModerationLog request after the transport layer. PageSize 0 or over LogPageMax is LogPageMax.
type LogInput struct {
	CommunityID string
	PageSize    int32
	PageToken   string
}

// LogItem is one row of the moderation log with its people resolved. Actor and Target are nil when deleted (or never set); the flags say
// which.
type LogItem struct {
	Entry                       LogEntry
	Actor, Target               *identity.Profile
	ActorDeleted, TargetDeleted bool
}

// LogPage is one page of ListModerationLog.
type LogPage struct {
	Items         []LogItem
	NextPageToken string
}

// Errors of the moderation repository, mapped to Connect codes by mapErr only.
var (
	// ErrNotModerator: the caller is neither the owner nor a moderator (FORBIDDEN not_moderator).
	ErrNotModerator = errors.New("communities: not a moderator")
	// ErrModeratorTarget: the owner bans a moderator; the role must be removed first (COMMUNITY_STATE moderator).
	ErrModeratorTarget = errors.New("communities: target is a moderator")
	// ErrBadTarget: the target is not valid for the action (VALIDATION user_id).
	ErrBadTarget = errors.New("communities: invalid target")
	// ErrModeratorCap: the community is at COMMUNITY_MAX_MODERATORS (LIMIT_REACHED community_moderators).
	ErrModeratorCap = errors.New("communities: moderator limit reached")
	// ErrPostNotFound: the post is missing or was not created into this community (NOT_FOUND "post not found").
	ErrPostNotFound = errors.New("communities: post not found")
)

// ModeratePostParams is one Hide or Restore write. RemovalsMax and ModlogMax are the capped array sizes.
type ModeratePostParams struct {
	UID, ID, PostID, IdemKey, RequestHash string
	Restore                               bool
	RemovalsMax, ModlogMax                int
}

// ModeratePostResult is what Repo.ModeratePost answers. Community is the freshly written document when Outcome is Written. Reply is true when the
// target was a reply of the community's conversation (ADR-0031 Amendment 1 D4a), known once the post was read, so also on an F16 refusal; false on a replay.
type ModeratePostResult struct {
	Outcome   Outcome
	Community Community
	Reply     bool
}

// SetRoleParams is one SetMemberRole write.
type SetRoleParams struct {
	UID, ID, Target, IdemKey, RequestHash string
	Action                                RoleAction
	ModlogMax, MaxModerators              int
}

// SetRoleResult is what ModerationRepo.SetRole answers. Community is the document after the write (on a replay or no change, as read).
// TargetState is the target's member state afterwards.
type SetRoleResult struct {
	Outcome     Outcome
	Community   Community
	TargetState MemberState
}

// ModerationRepo is the storage of Moderation (FirestoreRepo in production). Each method is one transaction that reads the idempotency
// document first (a replay returns there) and writes it last.
type ModerationRepo interface {
	// ModeratePost hides or restores a post in a community, see Moderation.HideCommunityPost.
	ModeratePost(ctx context.Context, p ModeratePostParams) (ModeratePostResult, error)
	// SetRole applies a SetMemberRole action, see Moderation.SetMemberRole.
	SetRole(ctx context.Context, p SetRoleParams) (SetRoleResult, error)
}
