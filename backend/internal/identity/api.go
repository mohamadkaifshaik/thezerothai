// Package identity owns users/{uid}, handles/{handleLower}, exports/{exportId}. It exposes
// Service (consumed by server.go, the Connect handler) and Counters (consumed by other modules through
// this interface only —: "modules depend on each other's api.go interfaces only").
//
// Scope: CreateProfile, CheckHandleAvailability, GetMe, GetProfile, UpdateProfile, ChangeHandle, plus the account
// lifecycle: DeleteAccount, RequestAccountExport and GetAccountExport behind
// FEATURE_ACCOUNT_LIFECYCLE, served by AccountLifecycle (lifecycle*.go) with the deletion orchestrator and export
// composer that other modules join through StepEraser / ExportSection.
package identity

import (
	"context"
	"errors"
	"time"

	"cloud.google.com/go/firestore"

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
	UserID               string
	Handle               string
	HandleLower          string
	DisplayName          string
	Bio                  string
	AvatarURL            string
	AvatarThumbURL       string
	IsPrivate            bool
	Verified             bool
	SubscriptionVerified bool
	Status               AccountStatus
	FollowersCount       int64
	FollowingCount       int64
	PostsCount           int64
	NotificationsSeenAt  time.Time
	HandleChangedAt      time.Time
	SnapshotVersion      int64
	CreatedAt            time.Time
	UpdatedAt            time.Time
	// Profile extras: all absent = none. Never part of the author snapshot. PinnedPostID is omitted from the
	// RPC responses while profile_extras is globally off.
	Location     string
	Website      string
	PinnedPostID string
	// ReadReceipts is the owner's "Read receipts" setting (F3), stored default false. Messaging reads it through the 60 s
	// profile cache. Shown only to the owner and omitted (false) while FEATURE_READ_RECEIPTS is globally off.
	ReadReceipts bool
	// DMPolicy is who may start a direct message with the account (F9); "" = DMPolicyEveryoneRequests, the stored default.
	// A plain string type so Profile stays comparable. Omitted from the RPC responses while dm_policy is globally off.
	DMPolicy DMPolicy
	// HomeTabsEnc is users/{uid}.homeTabs in a comparable, immutable form (Profile must stay comparable: UpdateProfile detects a
	// no-op with ==). Read it with HomeTabs(); only HomeTabsAdapter writes it.
	HomeTabsEnc string
	// AuthBaselineEnc is users/{uid}.authBaseline in a comparable form (JSON of AuthBaseline, hashes only), "" for an
	// account created before the baseline existed. Never serialized to clients or exports; only GetMe's audit reads it.
	AuthBaselineEnc string
	// DeletionRequestedAt and DeletionJob are the account-deletion job state: zero/nil for every live
	// account, set together by DeleteAccount. Never serialized to clients or exports.
	DeletionRequestedAt time.Time
	DeletionJob         *DeletionJob
}

// ReadReceiptsFlag is the wire name of FEATURE_READ_RECEIPTS (F3). It gates SETTING read_receipts=true through UpdateProfile
// (false is never gated, the undo rule), the receipt stamp of MarkConversationRead and the peer_read_at of ListMessages. While
// it is globally off Profile.read_receipts is omitted from every response.
const ReadReceiptsFlag = "read_receipts"

// DMPolicy is the "who can message me" setting. The strings are the stored values; the zero value is the default.
type DMPolicy string

const (
	// DMPolicyEveryoneRequests is today's behaviour: anyone can message, a sender the account does not follow arrives as a request.
	DMPolicyEveryoneRequests DMPolicy = ""
	// DMPolicyFollowingOnly lets only accounts the owner follows start a conversation or add to a pending request.
	DMPolicyFollowingOnly DMPolicy = "following_only"
)

// DMPolicyFlag is the wire name of FEATURE_DM_POLICY (F9). It gates SETTING FOLLOWING_ONLY through UpdateProfile; going back to
// EVERYONE_REQUESTS is never gated (the undo rule). While it is globally off Profile.dm_policy is omitted from every
// response, and messaging ignores a stored FOLLOWING_ONLY (it applies only to a recipient with the flag on).
const DMPolicyFlag = "dm_policy"

// ProfileTarget is the GetProfile oneof: exactly one of UserID/Handle is set.
type ProfileTarget struct {
	UserID string
	Handle string
}

// MeResult is everything GetMe needs beyond the ID token claims (email_verified comes from the token).
type MeResult struct {
	Profile                 Profile
	UnreadNotificationCount int64
	// EnabledFeatures is the caller's server feature flags, e.g. ["graph"]. Nil when no
	// FeatureFlags provider was wired (Phase 0 default) — GetMe still answers without a read either way.
	EnabledFeatures []string
	// PendingFollowRequestCount is the number of follow requests waiting for a protected caller, capped at
	// 1,000 by the counter; 0 for every other caller and when the count failed (WARN, never an error).
	PendingFollowRequestCount int64
	// UnreadConversationCount is the caller's unread direct-message conversations, capped at 100 by
	// the counter; 0 when messaging is off for the caller, when no MessageBadge is wired and when the count failed.
	UnreadConversationCount int64
	// HomeTabs is the caller's pinned Home tabs in order whose kind's flag is on for the caller. Dangling tabs
	// (list deleted or made private) are kept: GetMe adds no read, the client learns it from GetListTimeline. From the profile
	// GetMe already read: 0 extra reads.
	HomeTabs []HomeTab
}

// UpdateProfileParams carries only the fields the caller wants to change (nil = unchanged), matching the
// proto's `optional` fields.
type UpdateProfileParams struct {
	IdempotencyKey string
	DisplayName    *string
	Bio            *string
	// AvatarMediaID: "" removes the avatar; non-empty must reference a READY, caller-owned AVATAR media
	// item (WithAvatarResolver). Without a resolver, or with FEATURE_MEDIA off for the caller, a non-empty
	// value is rejected with ERROR_REASON_MEDIA_NOT_READY.
	AvatarMediaID *string
	// Setting any of the three (a non-empty value, whitespace-only included) needs FEATURE_PROFILE_EXTRAS on
	// for the caller (FEATURE_DISABLED feature=profile_extras, no read; a request that mixes a clear with a set is refused
	// whole). The exact value "" is a clear and is accepted from any authenticated caller whatever the flag, globally off
	// included. nil = unchanged.
	//
	// Location: <= 30 code points after NFC and trim, single line. Website: http(s) URL, <= 100 characters, no userinfo.
	// PinnedPostID: "" unpins; non-empty must be the caller's own visible POST, QUOTE or REPLY (WithPinChecker).
	Location     *string
	Website      *string
	PinnedPostID *string
	IsPrivate    *bool
	// ReadReceipts (F3): nil = unchanged. true needs FEATURE_READ_RECEIPTS on for the caller (FEATURE_DISABLED
	// feature=read_receipts, before any read); false never does.
	ReadReceipts *bool
	// DMPolicy (F9): nil = unchanged. Setting DMPolicyFollowingOnly needs FEATURE_DM_POLICY on for the caller
	// (FEATURE_DISABLED feature=dm_policy, before any read); DMPolicyEveryoneRequests never does.
	DMPolicy *DMPolicy
}

// Service is the Connect handler's dependency and the only thing server.go talks to.
type Service interface {
	CreateProfile(ctx context.Context, uid, idempotencyKey, handle, displayName string) (Profile, error)
	CheckHandleAvailability(ctx context.Context, handle string) (available bool, reason string, err error)
	// SuggestHandles returns up to MaxHandleSuggestions free handles derived from handle (see suggest_handles.go).
	// It never writes Firestore. The FEATURE_HANDLE_SUGGESTIONS gate is the handler's (server.go).
	SuggestHandles(ctx context.Context, handle string) ([]string, error)
	GetMe(ctx context.Context, uid string) (MeResult, error)
	GetProfile(ctx context.Context, callerUID string, target ProfileTarget) (Profile, error)
	UpdateProfile(ctx context.Context, uid string, params UpdateProfileParams) (Profile, error)
	ChangeHandle(ctx context.Context, uid, idempotencyKey, newHandle string) (Profile, error)

	// AccountStatus backs pkg/platform/authn.AccountStatusProvider (wired in main.go): whether uid has a
	// profile yet, and its current status, read from the same 60s instance cache as GetMe/GetProfile.
	AccountStatus(ctx context.Context, uid string) (exists bool, status AccountStatus, err error)
}

// Counters lets other modules atomically adjust denormalized counters on users/{uid} inside their own
// batch/transaction (unit-of-work seam). No module other than identity ever writes to
// users/{uid} directly. Unused until posts/graph exist; kept here so their first write goes through the
// seam the design specifies rather than a shortcut straight to Firestore.
type Counters interface {
	AddPostsCount(b store.Batch, uid string, delta int64)
	AddFollowersCount(b store.Batch, uid string, delta int64)
	AddFollowingCount(b store.Batch, uid string, delta int64)
	// AddCounts combines a followingCount and a followersCount delta into a single Update() call — i.e. one
	// write, not two — for the case where both counters on the *same* uid's doc change together (Block's counter decrements are "combined per doc").
	// A zero delta is simply omitted from the
	// update; if both are zero, no write is appended at all.
	AddCounts(b store.Batch, uid string, followingDelta, followersDelta int64)
}

// TxProfiles lets another module read the author's users/{uid} document INSIDE its own transaction, uncached, so a
// concurrent status change (an opsctl suspension, a DeleteAccount) conflicts with the transaction instead of being
// missed (security review L-7). It is the read-side companion of Counters: no module other
// than identity ever reads or writes users/{uid} directly. Unlike Directory.GetProfiles it does NOT filter by status:
// SUSPENDED and DELETING profiles come back with their Status so the caller can decide.
type TxProfiles interface {
	// ProfileInTx reads users/{uid} through tx. ErrNotFound when the
	// document is absent. The error text never includes the uid.
	ProfileInTx(ctx context.Context, tx *firestore.Transaction, uid string) (Profile, error)
}

// Repo is the storage seam service.go depends on; repo_firestore.go is the Firestore implementation,
// unit tests use an in-memory fake (identity_test.go) that implements the same interface.
type Repo interface {
	// GetProfile reads users/{uid}. Returns ErrNotFound if absent.
	GetProfile(ctx context.Context, uid string) (Profile, error)
	// ResolveHandle reads handles/{handleLower} and returns the owning uid. Returns ErrNotFound if free.
	ResolveHandle(ctx context.Context, handleLower string) (string, error)
	// ResolveHandles batch-reads handles/{h} for every handle in handleLowers via one GetAll (<=
	// MaxResolveHandles). Handles with no document are absent from the result.
	ResolveHandles(ctx context.Context, handleLowers []string) (map[string]string, error)
	// SearchHandles runs the handleLower prefix range query (limit already clamped 1..20).
	SearchHandles(ctx context.Context, prefix string, limit int) ([]Profile, error)
	// CreateProfile runs the signup transaction: read users/{uid}+handles/{h}; on first call,
	// create users, handles, and (via graphInit) graph. A replay (users/{uid} already exists) returns the
	// existing profile and performs no writes. authorize (nil = none) runs only on the not-found path, inside the
	// transaction after the users/{uid} read and before any other read or write;
	// its error aborts the transaction unchanged and nothing is written. It never runs on a replay.
	CreateProfile(ctx context.Context, uid, handle, handleLower, displayName string, now time.Time, authorize func(context.Context) (*AuthBaseline, error)) (profile Profile, replay bool, err error)
	// UpdateProfile reads users/{uid}, applies mutate, writes the result back and returns the new Profile. When mutate
	// leaves the profile unchanged (the caller must not touch UpdatedAt then) nothing is written.
	UpdateProfile(ctx context.Context, uid string, mutate func(*Profile)) (Profile, error)
	// ChangeHandle runs the rename transaction: reads users/{uid} + handles/{new}. Every invariant — no-op (identical handle), case-only rename
	// (same lower, different case), the handle-change cooldown, and handle uniqueness — is checked here,
	// against the doc read fresh inside this same transaction (M4: never against a value the caller
	// cached earlier, which could be stale relative to a change committed on another instance):
	//   - identical handle: writes nothing, returns the current profile unchanged.
	//   - same handleLower, different case: updates users only; handles/{} is untouched since the
	//     uniqueness key didn't change.
	//   - different handleLower, cooldown not yet elapsed: ErrHandleChangeCooldown, nothing written.
	//   - different handleLower, handles/{new} exists and is owned by a different uid: ErrHandleTaken.
	//   - different handleLower, handles/{new} exists and is already owned by uid: treated as a successful
	//     idempotent retry (not ErrHandleTaken) — creates/updates handles/{new}, deletes handles/{old},
	//     updates users; same writes as the common case.
	//   - otherwise: creates handles/{new}, deletes handles/{old}, updates users.
	// Returns the resulting profile and the old handleLower the caller should invalidate from its own
	// cache ("" for the no-op/case-only-rename paths, which never free a handle).
	ChangeHandle(ctx context.Context, uid, newHandle, newHandleLower string, now time.Time, cooldown time.Duration) (profile Profile, invalidateOldHandleLower string, err error)
	// UnreadNotificationCount runs a count() aggregation on users/{uid}/notifications with
	// createdAt > since. It counts rows the caller's block/mute context hides, so GetMe uses it only when no
	// NotificationBadge is wired.
	UnreadNotificationCount(ctx context.Context, uid string, since time.Time) (int64, error)
	// GetProfiles batch-reads users/{uid} for every id in uids via one GetAll (<= 50 ids). Ids
	// with no document are simply absent from the result map (not an error).
	GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error)
}

// FeatureFlags reports which server feature flags are enabled for a caller, for
// GetMeResponse.enabled_features. It reads nothing from Firestore. Implemented by pkg/platform/flags.Registry; declared
// here (rather than identity importing that package's concrete type into its exported API) so identity's
// dependency stays interface-shaped.
type FeatureFlags interface {
	EnabledFeatures(uid string) []string
}

// BlockChecker lets GetProfile ask "did target block viewer" without identity importing graph (
// "identity declares a consumer-side interface identity.BlockChecker in its api.go... graph implements it
// ... graph never gets imported by identity" — the same pattern as GraphInitializer below). Backed by the
// viewer's own cached graph.Snapshot.BlockedBy (0 extra reads on a cache hit; the blockedBy-cap
// overflow fallback may add one read on the rare account that has been blocked by more than 10,000 users).
type BlockChecker interface {
	IsBlockedBy(ctx context.Context, viewerUID, targetUID string) (bool, error)
	// IsFollowing reports whether viewerUID follows targetUID, from the viewer's own cached graph snapshot (no read on a hit).
	// GetProfile uses it to decide, before it touches the protected set, whether a viewer is an
	// approved follower who keeps the pin.
	IsFollowing(ctx context.Context, viewerUID, targetUID string) (bool, error)
}

// Directory is the batched, cache-first profile lookup other modules use to hydrate list rows: it checks the cache first, then does one
// GetAll for misses (<= 50), reusing getProfileCached and Cache (no second cache). GetProfiles silently drops uids with no profile or a non-ACTIVE status — callers
// drop the corresponding row rather than erroring. Forget evicts uid's cached profile and unread count
// immediately after another module's own commit changed users/{uid} counters (via Counters), so a
// subsequent read on this instance reflects the write without waiting out the cache TTL (project rule: "update
// the instance cache from written data instead of re-reading").
type Directory interface {
	GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error)
	// LookupProfiles is GetProfiles that also reports, in missing, the uids whose users/{uid} doc was
	// confirmed absent by a fresh read in this call. Non-ACTIVE users (SUSPENDED, DELETING)
	// appear in neither found nor missing, so a caller can never mistake them for deleted. Same read cost.
	LookupProfiles(ctx context.Context, uids []string) (found map[string]Profile, missing []string, err error)
	// ResolveHandles maps lower-case handles to their owning uids for @mention resolution: at
	// most MaxResolveHandles distinct handles, cache-first (the handle->uid cache, then the 10 s negative
	// handle cache), then one GetAll on handles/* for the rest (at most 10). Handles that are unknown, reserved or malformed are
	// absent from the map and are never looked up; the caller leaves them as plain text. It does not check account status.
	ResolveHandles(ctx context.Context, lowers []string) (map[string]string, error)
	// SearchHandles lists users whose handleLower starts with prefix (lower-cased by the service), in handleLower
	// order so an exact match comes first, raw profiles including status (SUSPENDED and DELETING included;
	// filtering is the caller's job, as with posts.Reader). limit is clamped to 1..20. It never writes, and an
	// empty prefix returns nothing without a query. Not cached here; the search module caches by (prefix, limit) for 60 s.
	SearchHandles(ctx context.Context, prefix string, limit int) ([]Profile, error)
	Forget(uids ...string)
	// ForgetUnread evicts only uid's cached unread count, leaving the profile cached (for a caller that just
	// wrote a notification row: the profile is unchanged, the badge is not).
	ForgetUnread(uids ...string)
}

// MaxResolveHandles is the most distinct handles one ResolveHandles call takes (one post carries at most 10
// mentions).
const MaxResolveHandles = 10

// GraphInitializer is the minimal seam identity depends on to create the caller's empty social-graph
// doc inside the same CreateProfile transaction ("create users, handles, graph"). The full
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

// AvatarResolver is the consumer-side seam to the media module; apiserver adapts media.Library and
// the FEATURE_MEDIA check.
type AvatarResolver interface {
	ResolveAvatar(ctx context.Context, uid, mediaID string) (AvatarRef, error)
}

// ProfileExtrasFlag is the wire name of FEATURE_PROFILE_EXTRAS: it gates SETTING the location, website and pinned
// post through UpdateProfile; a clear (the exact value "") is never gated (Amendment 1 A2). Rendering of data already stored stays ungated, except the pin and the
// website, which are omitted while the flag is globally off (D3, Amendment 1 A1).
const ProfileExtrasFlag = "profile_extras"

// ExtrasFlags is the consumer-side flag seam of the profile extras (*flags.Registry satisfies it). It reads nothing from Firestore.
// Enabled is the per-caller answer that gates the writes; GloballyOff is the kill switch: only mode off, never a
// rollout, so an allowlisted user's pin and website keep showing to everyone while the flag ramps. A nil ExtrasFlags
// means off for every caller (fail closed) and globally off.
type ExtrasFlags interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// PinChecker is the consumer-side seam to the posts module (the BlockChecker pattern, so identity never imports posts).
// CanPin reports whether postID is uid's own POST, QUOTE or REPLY that is still visible (not a
// REPOST, not deleted or taken down, not owned by anyone else). Every "no" is the same (false, nil): the caller
// answers one VALIDATION field=pinned_post_id for every cause, so the call is no existence oracle. A non-nil error is
// an infrastructure failure, not a verdict. Read cache-first. A nil checker (the
// WithPinChecker default) turns every non-empty pinned_post_id into that same VALIDATION answer.
type PinChecker interface {
	CanPin(ctx context.Context, uid, postID string) (bool, error)
}

// Pins is the identity step of the post_delete job. ClearIfPinned runs one transaction: it reads
// users/{uid} fresh and only when pinnedPostId == postID updates it to "" (field-level, so a purged
// users doc is never recreated; NotFound is "not pinned"). It never touches a newer pin. cleared reports whether it
// wrote. A takedown does not call it: a restore brings the pin back. *FirestoreRepo implements it.
type Pins interface {
	ClearIfPinned(ctx context.Context, uid, postID string) (cleared bool, err error)
}

// ProtectedSet is one instance's copy of privacy/protectedAuthors: the uids whose accounts are protected.
// It is an immutable snapshot, so Has and CanSee are map lookups with no I/O.
type ProtectedSet interface {
	// Has reports whether uid is a protected account.
	Has(uid string) bool
	// CanSee is the one expression of the D3 predicate: viewer == author || !Has(author) || following.
	// following is the viewer's follow state toward author, decided by the caller from the viewer's own cached graph
	// snapshot before it asks for the set. posts.Audience.CanSee delegates here, so the rule exists in one place;
	// GetProfile (the pin, D4) is the only other caller.
	CanSee(viewerUID, authorUID string, following bool) bool
}

// ProtectedAuthors is the loader of the protected set, declared here so every consumer depends on this
// interface only (the Stage 2 sharded set or Memorystore changes no caller). The implementation is lazy, singleflight,
// at most one load per instance per CACHE_TTL, never on a caller's behalf.
type ProtectedAuthors interface {
	// Current returns the instance's copy of the set. A missing doc is an empty set. When a refresh fails it keeps the
	// last good copy for at most PROTECTED_SET_MAX_STALE; past that, or when the instance never loaded a set, it returns
	// an error and the caller answers UNAVAILABLE. An unknown set is never read as "everyone public".
	Current(ctx context.Context) (ProtectedSet, error)
}

// ProtectedAuthorsCached is the optional second face of a ProtectedAuthors loader (L-4): the copy the instance
// already holds, with no refresh, no log and no read. posts.Audience.ProtectedAuthor type-asserts it for the viewer's
// own and followed authors; a loader without it (a test fake) is asked through Current as before. Staleness: CACHE_TTL.
type ProtectedAuthorsCached interface {
	Cached() (ProtectedSet, bool)
}

// PrivacyListener is told by identity, after the commit, that an account stopped being protected.
// graph owns the privacy_public job that accepts the pending requests; apiserver adapts this to its publish (the
// MediaRetirer split). A nil listener publishes nothing (apiserver wires graph.PrivacyListener since then). identity calls it
// with a detached, short-deadline context; an error is ERROR privacy_public_enqueue_failed and never fails the toggle.
type PrivacyListener interface {
	BecamePublic(ctx context.Context, uid string, at time.Time) error
}

// FollowRequestCounter is the consumer-side seam GetMe uses for pending_follow_request_count (the
// BlockChecker pattern: identity cannot query graph's collection). graph implements it with a count() on
// followRequests where followeeId == uid. identity caches the answer 30 s per uid.
type FollowRequestCounter interface {
	PendingFollowRequests(ctx context.Context, uid string) (int64, error)
}

// MessagingFlag is the wire name of FEATURE_MESSAGING in GetMe.enabled_features. identity cannot import
// messaging, so GetMe reads the per-caller answer from the enabled_features list it already computed (no read).
const MessagingFlag = "messaging"

// MessageBadge is the consumer-side seam to the messaging module for GetMe.unread_conversation_count (
// the BlockChecker / PinChecker pattern, so identity never imports messaging). messaging implements it with a
// count() of users/{uid}/dmInbox where unreadCount > 0, Limit 100. Requests do not count. identity
// caches the answer 30 s per uid and calls it only for a caller with messaging on. A nil MessageBadge
// (WithMessageBadge not called) leaves the count 0.
type MessageBadge interface {
	UnreadConversations(ctx context.Context, uid string) (int64, error)
}

// NotificationBadge is the consumer-side seam to the notifications module for GetMe.unread_notification_count (the
// MessageBadge pattern: notifications imports identity, so identity never imports notifications).
// notifications.UnreadBadge implements it: the rows newer than since that ListNotifications would show (rows whose
// displayed actor the caller blocks or mutes, or who blocks the caller, are not counted), capped at 100. identity
// caches the answer 30 s per uid. An error is WARN unread_notifications_failed and answers 0, never cached. Without it (WithNotificationBadge not called)
// GetMe falls back to Repo.UnreadNotificationCount, the raw count() that also counts hidden rows; apiserver always wires it.
type NotificationBadge interface {
	UnreadNotifications(ctx context.Context, uid string, since time.Time) (int64, error)
}
