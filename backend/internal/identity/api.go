// Package identity owns users/{uid}, handles/{handleLower}, exports/{exportId} (ADR-0003). It exposes
// Service (consumed by server.go, the Connect handler) and Counters (consumed by other modules through
// this interface only — ADR-0002: "modules depend on each other's api.go interfaces only").
//
// Scope: CreateProfile, CheckHandleAvailability, GetMe, GetProfile, UpdateProfile, ChangeHandle, plus the account
// lifecycle (P8, ADR-0011): DeleteAccount, RequestAccountExport and GetAccountExport behind
// FEATURE_ACCOUNT_LIFECYCLE, served by AccountLifecycle (lifecycle*.go) with the deletion orchestrator and export
// composer that other modules join through StepEraser / ExportSection.
package identity

import (
	"context"
	"errors"
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
	// DeletionRequestedAt and DeletionJob are the account-deletion job state (ADR-0011): zero/nil for every live
	// account, set together by DeleteAccount. Never serialized to clients or exports.
	DeletionRequestedAt time.Time
	DeletionJob         *DeletionJob
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
	// EnabledFeatures is the caller's server feature flags (ADR-0008 D6), e.g. ["graph"]. Nil when no
	// FeatureFlags provider was wired (Phase 0 default) — GetMe still returns 0 reads either way.
	EnabledFeatures []string
}

// UpdateProfileParams carries only the fields the caller wants to change (nil = unchanged), matching the
// proto's `optional` fields.
type UpdateProfileParams struct {
	IdempotencyKey string
	DisplayName    *string
	Bio            *string
	// AvatarMediaID: "" removes the avatar; non-empty must reference a READY, caller-owned AVATAR media
	// item (WithAvatarResolver, P4). Without a resolver, or with FEATURE_MEDIA off for the caller, a non-empty
	// value is rejected with ERROR_REASON_MEDIA_NOT_READY.
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
	// AddCounts combines a followingCount and a followersCount delta into a single Update() call — i.e. one
	// write, not two — for the case where both counters on the *same* uid's doc change together (ADR-0008
	// D3: Block's counter decrements are "combined per doc"). A zero delta is simply omitted from the
	// update; if both are zero, no write is appended at all.
	AddCounts(b store.Batch, uid string, followingDelta, followersDelta int64)
}

// Repo is the storage seam service.go depends on; repo_firestore.go is the Firestore implementation,
// unit tests use an in-memory fake (identity_test.go) that implements the same interface.
type Repo interface {
	// GetProfile reads users/{uid}. Returns ErrNotFound if absent.
	GetProfile(ctx context.Context, uid string) (Profile, error)
	// ResolveHandle reads handles/{handleLower} and returns the owning uid. Returns ErrNotFound if free.
	ResolveHandle(ctx context.Context, handleLower string) (string, error)
	// ResolveHandles batch-reads handles/{h} for every handle in handleLowers via one GetAll (<=
	// MaxResolveHandles). Reads: len(handleLowers). Handles with no document are absent from the result.
	ResolveHandles(ctx context.Context, handleLowers []string) (map[string]string, error)
	// CreateProfile runs the signup transaction (ADR-0003): read users/{uid}+handles/{h}; on first call,
	// create users, handles, and (via graphInit) graph. A replay (users/{uid} already exists) returns the
	// existing profile and performs no writes. authorize (nil = none) runs only on the not-found path, inside the
	// transaction after the users/{uid} read and before any other read or write (ADR-0011 amendment M2: the
	// Auth-user check); its error aborts the transaction unchanged and nothing is written. It never runs on a replay.
	CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time, authorize func(context.Context) error) (profile Profile, replay bool, err error)
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
	// GetProfiles batch-reads users/{uid} for every id in uids via one GetAll (<= 50 ids; ADR-0008 T6). Ids
	// with no document are simply absent from the result map (not an error).
	GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error)
}

// FeatureFlags reports which server feature flags (ADR-0008 D6) are enabled for a caller, for
// GetMeResponse.enabled_features. 0 Firestore reads. Implemented by pkg/platform/flags.Registry; declared
// here (rather than identity importing that package's concrete type into its exported API) so identity's
// dependency stays interface-shaped (ADR-0002).
type FeatureFlags interface {
	EnabledFeatures(uid string) []string
}

// BlockChecker lets GetProfile ask "did target block viewer" without identity importing graph (ADR-0008:
// "identity declares a consumer-side interface identity.BlockChecker in its api.go... graph implements it
// ... graph never gets imported by identity" — the same pattern as GraphInitializer below). Backed by the
// viewer's own cached graph.Snapshot.BlockedBy (0 extra reads on a cache hit; ADR-0008 D2's blockedBy-cap
// overflow fallback may add one read on the rare account that has been blocked by more than 10,000 users).
type BlockChecker interface {
	IsBlockedBy(ctx context.Context, viewerUID, targetUID string) (bool, error)
}

// Directory is the batched, cache-first profile lookup other modules use to hydrate list rows (ADR-0008
// T6/T9: "checks the cache first, then does one GetAll for misses (<= 50)... Reuse getProfileCached and
// Cache; no second cache"). GetProfiles silently drops uids with no profile or a non-ACTIVE status — callers
// drop the corresponding row rather than erroring. Forget evicts uid's cached profile and unread count
// immediately after another module's own commit changed users/{uid} counters (via Counters), so a
// subsequent read on this instance reflects the write without waiting out the cache TTL (CLAUDE.md: "update
// the instance cache from written data instead of re-reading").
type Directory interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error)
	// LookupProfiles is GetProfiles that also reports, in missing, the uids whose users/{uid} doc was
	// confirmed absent by a fresh read in this call (ADR-0008 T27). Non-ACTIVE users (SUSPENDED, DELETING)
	// appear in neither found nor missing, so a caller can never mistake them for deleted. Same read cost.
	LookupProfiles(ctx context.Context, uids []string) (found map[string]Profile, missing []string, err error)
	// ResolveHandles maps lower-case handles to their owning uids for @mention resolution (ADR-0010 D7): at
	// most MaxResolveHandles distinct handles, cache-first (the handle->uid cache, then the 10 s negative
	// handle cache), then one GetAll on handles/* for the rest, so reads = the number of uncached handles
	// (<= 10, typically 0-4). Handles that are unknown, reserved or malformed are absent from the map and cost
	// nothing; the caller leaves them as plain text. It does not check account status.
	ResolveHandles(ctx context.Context, lowers []string) (map[string]string, error)
	Forget(uids ...string)
}

// MaxResolveHandles is the most distinct handles one ResolveHandles call takes (one post carries at most 10
// mentions, ADR-0010 D7).
const MaxResolveHandles = 10

// GraphInitializer is the minimal seam identity depends on to create the caller's empty social-graph
// doc inside the same CreateProfile transaction (ADR-0003: "create users, handles, graph"). The full
// GraphService (follow/unfollow/block/mute) is a separate module and out of scope for this bootstrap;
// this interface only ever appends one Create() to the batch it's given.
type GraphInitializer interface {
	InitGraph(b store.Batch, uid string, now time.Time)
}

// AvatarRef is a published avatar: the full image and the 96 px thumbnail (Profile.AvatarURL and
// AvatarThumbURL).
type AvatarRef struct {
	URL      string
	ThumbURL string
}

// ErrAvatarNotReady is returned by an AvatarResolver for a media id that is missing, not the caller's, not an
// AVATAR, not READY, or when FEATURE_MEDIA is off for the caller (one answer, no oracle).
var ErrAvatarNotReady = errors.New("identity: avatar media not ready")

// AvatarResolver is the consumer-side seam to the media module (ADR-0002); apiserver adapts media.Library and
// the FEATURE_MEDIA check. 1 Firestore read.
type AvatarResolver interface {
	ResolveAvatar(ctx context.Context, uid, mediaID string) (AvatarRef, error)
}
