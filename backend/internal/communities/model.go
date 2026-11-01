package communities

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// Field limits of a community (ADR-0031 D2), in code points after trim and NFC. The number of rules and the capped arrays are
// config (COMMUNITY_MAX_RULES, COMMUNITY_MODLOG_MAX), not constants.
const (
	MinNameRunes        = 1
	MaxNameRunes        = 30
	MaxDescriptionRunes = 160
	MinRuleTitleRunes   = 1
	MaxRuleTitleRunes   = 60
	MaxRuleTextRunes    = 300
)

// DeletedMarker replaces a deleted account's uid in the moderation log (ADR-0031 D2, D9; the ADR-0027 marker). A log entry keeps its
// action and time, so the owner still sees that something happened.
const DeletedMarker = "_deleted"

// Status is communities/{cid}.status (ADR-0031 D2).
type Status string

const (
	// StatusActive is the normal state.
	StatusActive Status = "ACTIVE"
	// StatusArchived is read-only and out of the directory (F12): the owner's account was deleted with no ACTIVE moderator to take
	// over, or opsctl archived it.
	StatusArchived Status = "ARCHIVED"
	// StatusSuspended is the platform's offline switch (opsctl, W5-29).
	StatusSuspended Status = "SUSPENDED"
)

// VisibilityPublic is the only visibility at Stage 0 (F6).
const VisibilityPublic = "PUBLIC"

// MemberState is communityMembers/{uid}.state (ADR-0031 D2): never a role.
type MemberState string

const (
	// MemberNone is the absence of a member doc.
	MemberNone MemberState = ""
	// MemberJoined: the doc carries joinedAt.
	MemberJoined MemberState = "JOINED"
	// MemberBanned: the doc carries bannedAt.
	MemberBanned MemberState = "BANNED"
)

// Role is the viewer's role in a community (ADR-0031 D4), computed from the community doc (OWNER, MODERATOR) and the member doc
// (MEMBER, BANNED); the client never infers one.
type Role int

// The five roles of D4.
const (
	RoleNone Role = iota
	RoleOwner
	RoleModerator
	RoleMember
	RoleBanned
)

// Moderation-log actions (ADR-0031 D2). W5-23 writes EDIT and W5-24 OWNER_HANDOVER; the others belong to W5-25 and W5-28.
const (
	ActionHide          = "HIDE"
	ActionRestore       = "RESTORE"
	ActionBan           = "BAN"
	ActionUnban         = "UNBAN"
	ActionMakeModerator = "MAKE_MODERATOR"
	ActionRemoveMod     = "REMOVE_MODERATOR"
	ActionEdit          = "EDIT"
	ActionModeratorLeft = "MODERATOR_LEFT"
	ActionOwnerHandover = "OWNER_HANDOVER"
)

// Rule is one community rule: title 1-60 code points on one line, text 0-300 (the bio rules).
type Rule struct {
	Title string
	Text  string
}

// LogEntry is one communities/{cid}.modlog element. Actor and Target are a uid or DeletedMarker; Target and PostID are empty
// when not applicable; the author of a hidden post is never stored.
type LogEntry struct {
	Seq    int64
	At     time.Time
	Actor  string
	Action string
	Target string
	PostID string
}

// Removal is one communities/{cid}.recentRemovals element (a hide, A3). Written from W5-28 on.
type Removal struct {
	PostID string
	At     time.Time
}

// Community is one communities/{cid} document as the module sees it (ADR-0031 D2). Slices are copies the caller may keep.
type Community struct {
	ID                  string
	Name                string
	Description         string
	Rules               []Rule
	OwnerID             string // "" only when ARCHIVED (or SUSPENDED) with no successor (F12)
	ModeratorIDs        []string
	MemberCount         int64
	Status              Status
	Visibility          string
	RecentRemovals      []Removal
	RemovalsTruncatedAt time.Time // zero = never
	Modlog              []LogEntry
	ModlogSeq           int64
	CreatedAt           time.Time
	UpdatedAt           time.Time
}

// RoleOf is the community-doc half of the role (D4): OWNER, MODERATOR or, for everyone else, none (the member doc decides).
func (c Community) RoleOf(uid string) Role {
	switch {
	case uid != "" && c.OwnerID == uid:
		return RoleOwner
	case uid != "" && containsString(c.ModeratorIDs, uid):
		return RoleModerator
	}
	return RoleNone
}

func containsString(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// Memberships is communityMemberships/{uid} (ADR-0031 D2): the per-user index of the communities the user joined, owns, is banned
// from or appears in a moderation log of (I-L). Written only in the transaction of the document it mirrors.
type Memberships struct {
	Joined, Owned, Banned, Modlogged []string
}

// CreateInput is a CreateCommunity request after the transport layer.
type CreateInput struct {
	Key         string
	Name        string
	Description string
	Rules       []Rule
}

// UpdateInput is an UpdateCommunity request: a nil field is unchanged; Rules non-nil replaces every rule (an empty list removes them
// all).
type UpdateInput struct {
	Key         string
	CommunityID string
	Name        *string
	Description *string
	Rules       *[]Rule
}

// View is a community as one caller sees it: the document and the caller's role.
type View struct {
	Community Community
	Role      Role
}

// Person is one role holder on GetCommunity: the live profile row and the caller's relationship to it.
type Person struct {
	Profile      identity.Profile
	Relationship graph.Relationship
}

// Detail is what GetCommunity answers: the header, the owner (nil when none or not ACTIVE) and the ACTIVE moderators in appointment
// order.
type Detail struct {
	View       View
	Owner      *Person
	Moderators []Person
}

// Service is everything the CommunityService handlers call (ADR-0031 D1, the seam: handlers call only this). W5-23 holds Create, Update
// and Get; W5-25 adds Join, Leave and the lists, W5-28 the moderation calls.
type Service interface {
	// CreateCommunity creates a community owned by uid, who becomes its first member. COMMUNITY_CREATORS is checked first (FORBIDDEN
	// not_creator, 0 reads), then the key and the text rules. No daily quota: the owned cap is exact and lifetime. Firestore: reads 2
	// (idempotency, memberships; the interceptor's 1 on top = 3 cold); writes 4 (community, owner member doc, memberships,
	// idempotency); replay reads 2 (idempotency, the community), writes 0; refused 0 writes.
	CreateCommunity(ctx context.Context, uid string, in CreateInput) (View, error)
	// UpdateCommunity changes the set fields of uid's own community. Firestore: reads 3 (idempotency, community, owner memberships;
	// 2 when nothing changes), writes 3 for an owner's first edit (community, idempotency, memberships modlogged), 2 after that, 1
	// when nothing changes; replay reads 2, writes 0.
	UpdateCommunity(ctx context.Context, uid string, in UpdateInput) (View, error)
	// GetCommunity returns one community with its owner and moderators as uid may see it. Firestore: reads cold 1 community + 1 caller
	// member doc (skipped for the owner and moderators) + 1 caller graph + owner and <= 10 moderator profiles (the interceptor's 1 on
	// top = 15); warm 0; writes 0.
	GetCommunity(ctx context.Context, uid, communityID string) (Detail, error)
}

// IDSource issues community ids (a Snowflake node, rule 1). *snowflake.Node satisfies it.
type IDSource interface {
	Generate() string
}

// Outcome is how a repository write ended.
type Outcome int

const (
	// Written: the documents changed.
	Written Outcome = iota
	// Replayed: the idempotency record already existed and answered; nothing was written.
	Replayed
	// Unchanged: only the idempotency document was written.
	Unchanged
)

// Errors of the repository, mapped to Connect codes by the service only.
var (
	// ErrNotFound is the one cause-blind answer for a community the caller cannot reach: missing, or SUSPENDED (N3).
	ErrNotFound = errors.New("communities: community not found")
	// ErrKeyReused: the idempotency key was used for a different request body.
	ErrKeyReused = errors.New("communities: idempotency key reused")
	// ErrOwnedLimit: the creator is at COMMUNITIES_MAX_OWNED.
	ErrOwnedLimit = errors.New("communities: owned limit reached")
	// ErrJoinedLimit: the creator is at COMMUNITIES_MAX_JOINED.
	ErrJoinedLimit = errors.New("communities: joined limit reached")
	// ErrNotOwner: the caller is not the community's owner.
	ErrNotOwner = errors.New("communities: not the owner")
	// ErrArchived: the community is ARCHIVED.
	ErrArchived = errors.New("communities: community archived")
)

// CreateParams is one CreateCommunity write.
type CreateParams struct {
	UID, ID, IdemKey, RequestHash string
	Name, Description             string
	Rules                         []Rule
	MaxOwned, MaxJoined           int
}

// CreateResult is what Repo.Create answers. Community is the stored document (on a replay, re-read).
type CreateResult struct {
	Outcome   Outcome
	Community Community
}

// UpdateParams is one UpdateCommunity write. ModlogMax is COMMUNITY_MODLOG_MAX.
type UpdateParams struct {
	UID, ID, IdemKey, RequestHash string
	Name, Description             *string
	Rules                         *[]Rule
	ModlogMax                     int
}

// UpdateResult is what Repo.Update answers. Community is the stored document after the write (on a replay, re-read).
type UpdateResult struct {
	Outcome   Outcome
	Community Community
}

// Repo is the storage of the module (FirestoreRepo in production). Create and Update are one transaction each that reads the
// idempotency document first (a replay returns there) and writes it last.
type Repo interface {
	Create(ctx context.Context, p CreateParams) (CreateResult, error)
	Update(ctx context.Context, p UpdateParams) (UpdateResult, error)
	// Get reads communities/{id} outside any transaction (1 read, charged even when missing): ErrNotFound when it does not exist. It
	// does not apply the SUSPENDED rule; the service does.
	Get(ctx context.Context, id string) (Community, error)
	// Member reads the member doc (1 read, charged even when missing): MemberNone when there is none.
	Member(ctx context.Context, communityID, uid string) (MemberState, error)
}
