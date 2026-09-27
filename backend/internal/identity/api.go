// Package identity owns users/{uid}, handles/{handleLower}, exports/{exportId} (ADR-0003). It exposes
// Service (consumed by server.go, the Connect handler) and Counters (consumed by other modules through
// this interface only — ADR-0002: "modules depend on each other's api.go interfaces only").
//
// Phase 0 scope (this bootstrap): CreateProfile, CheckHandleAvailability, GetMe, GetProfile,
// UpdateProfile, ChangeHandle. DeleteAccount/RequestAccountExport/GetAccountExport are stubbed
// Unimplemented in server.go — their resumable delete/export jobs need graph, posts, engagement,
// media and notifications to exist first (ADR-0003 "Deletes & privacy"); tracked for Phase 1.
package identity

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// AccountStatus mirrors identityv1.AccountStatus (kept as a plain Go type so this package has no proto
// import at the domain-model layer; server.go converts at the boundary).
type AccountStatus int

const (
	AccountStatusUnspecified AccountStatus = iota
	AccountStatusActive
	AccountStatusSuspended
	AccountStatusDeleting
)

// Profile is the identity module's domain representation of users/{uid}.
type Profile struct {
	UserID              string
	Handle              string
	HandleLower         string
	DisplayName         string
	Bio                 string
	AvatarURL           string
	AvatarThumbURL      string
	IsPrivate           bool
	Verified            bool
	Status              AccountStatus
	FollowersCount      int64
	FollowingCount      int64
	PostsCount          int64
	NotificationsSeenAt time.Time
	HandleChangedAt     time.Time
	SnapshotVersion     int64
	CreatedAt           time.Time
	UpdatedAt           time.Time
}

// ProfileTarget is the GetProfile oneof: exactly one of UserID/Handle is set.
type ProfileTarget struct {
	UserID string
	Handle string
}

// MeResult is everything GetMe needs beyond the ID token claims (email_verified comes from the token).
type MeResult struct {
	Profile                 Profile
	UnreadNotificationCount int64
}

// UpdateProfileParams carries only the fields the caller wants to change (nil = unchanged), matching the
// proto's `optional` fields.
type UpdateProfileParams struct {
	IdempotencyKey string
	DisplayName    *string
	Bio            *string
	// AvatarMediaID: "" removes the avatar; non-empty must reference a READY, caller-owned AVATAR media
	// item. The media module does not exist yet in Phase 0, so a non-empty value is rejected with
	// ERROR_REASON_MEDIA_NOT_READY until that integration lands (documented Phase 0 limitation).
	AvatarMediaID *string
	IsPrivate     *bool
}

// Service is the Connect handler's dependency and the only thing server.go talks to.
type Service interface {
	CreateProfile(ctx context.Context, uid, idempotencyKey, handle, displayName string) (Profile, error)
	CheckHandleAvailability(ctx context.Context, handle string) (available bool, reason string, err error)
	GetMe(ctx context.Context, uid string) (MeResult, error)
	GetProfile(ctx context.Context, callerUID string, target ProfileTarget) (Profile, error)
	UpdateProfile(ctx context.Context, uid string, params UpdateProfileParams) (Profile, error)
	ChangeHandle(ctx context.Context, uid, idempotencyKey, newHandle string) (Profile, error)

	// AccountStatus backs pkg/platform/authn.AccountStatusProvider (wired in main.go): whether uid has a
	// profile yet, and its current status, read from the same 60s instance cache as GetMe/GetProfile.
	AccountStatus(ctx context.Context, uid string) (exists bool, status AccountStatus, err error)
}

// Counters lets other modules atomically adjust denormalized counters on users/{uid} inside their own
// batch/transaction (ADR-0002 unit-of-work seam). No module other than identity ever writes to
// users/{uid} directly. Unused until posts/graph exist; kept here so their first write goes through the
// seam ADR-0002 specifies rather than a shortcut straight to Firestore.
type Counters interface {
	AddPostsCount(b store.Batch, uid string, delta int64)
	AddFollowersCount(b store.Batch, uid string, delta int64)
	AddFollowingCount(b store.Batch, uid string, delta int64)
}

// Repo is the storage seam service.go depends on; repo_firestore.go is the Firestore implementation,
// unit tests use an in-memory fake (identity_test.go) that implements the same interface.
type Repo interface {
	// GetProfile reads users/{uid}. Returns ErrNotFound if absent.
	GetProfile(ctx context.Context, uid string) (Profile, error)
	// ResolveHandle reads handles/{handleLower} and returns the owning uid. Returns ErrNotFound if free.
	ResolveHandle(ctx context.Context, handleLower string) (string, error)
	// CreateProfile runs the signup transaction (ADR-0003): read users/{uid}+handles/{h}; on first call,
	// create users, handles, and (via graphInit) graph. A replay (users/{uid} already exists) returns the
	// existing profile and performs no writes.
	CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time) (profile Profile, replay bool, err error)
	// UpdateProfile reads users/{uid}, applies mutate, writes the result back. Returns the new Profile.
	UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error)
	// ChangeHandle runs the rename transaction (ADR-0003): reads users/{uid} + handles/{new} (worst case 2
	// reads, matching the proto doc comment). Every invariant — no-op (identical handle), case-only rename
	// (same lower, different case), the handle-change cooldown, and handle uniqueness — is checked here,
	// against the doc read fresh inside this same transaction (M4: never against a value the caller
	// cached earlier, which could be stale relative to a change committed on another instance):
	//   - identical handle: 0 writes, returns the current profile unchanged.
	//   - same handleLower, different case: 1 write (users only); handles/{} is untouched since the
	//     uniqueness key didn't change.
	//   - different handleLower, cooldown not yet elapsed: ErrHandleChangeCooldown, 0 writes.
	//   - different handleLower, handles/{new} exists and is owned by a different uid: ErrHandleTaken.
	//   - different handleLower, handles/{new} exists and is already owned by uid: treated as a successful
	//     idempotent retry (not ErrHandleTaken) — creates/updates handles/{new}, deletes handles/{old},
	//     updates users; same 2 writes + 1 delete as the common case.
	//   - otherwise: creates handles/{new}, deletes handles/{old}, updates users (2 writes, 1 delete).
	// Returns the resulting profile and the old handleLower the caller should invalidate from its own
	// cache ("" for the no-op/case-only-rename paths, which never free a handle).
	ChangeHandle(ctx context.Context, uid, newHandle, newHandleLower string, now time.Time, cooldown time.Duration) (profile Profile, invalidateOldHandleLower string, err error)
	// UnreadNotificationCount runs a count() aggregation on users/{uid}/notifications with
	// createdAt > since.
	UnreadNotificationCount(ctx context.Context, uid string, since time.Time) (int64, error)
}

// GraphInitializer is the minimal seam identity depends on to create the caller's empty social-graph
// doc inside the same CreateProfile transaction (ADR-0003: "create users, handles, graph"). The full
// GraphService (follow/unfollow/block/mute) is a separate module and out of scope for this bootstrap;
// this interface only ever appends one Create() to the batch it's given.
type GraphInitializer interface {
	InitGraph(b store.Batch, uid string, now time.Time)
}
