package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/handle"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// service is the default Service implementation: business rules + validation over a Repo, backed by an
// instance Cache. It holds no Firestore-specific knowledge (that's repo_firestore.go).
type service struct {
	repo                 Repo
	cache                *Cache
	handleChangeCooldown time.Duration
	now                  func() time.Time
	blockChecker         BlockChecker
	features             FeatureFlags
	avatars              AvatarResolver
	// banners, pins and extras are the profile-extras seams. All nil by default: no resolver means a
	// non-empty banner_media_id is MEDIA_NOT_READY, no checker means a non-empty pinned_post_id is VALIDATION, and no
	// flags means profile_extras is off for every caller and globally off.
	banners BannerResolver
	pins    PinChecker
	extras  ExtrasFlags
	// signup is the M2 Auth-user check at the CreateProfile boundary; nil (tests) skips it. apiserver.Build always
	// wires it, so production never runs without it.
	signup *authAdmin
	// snap is the profile-snapshot-refresh trigger (profile_snapshot.go); nil = never publishes.
	snap *profileSnapshots
	// retire hands a replaced or removed avatar or banner to the media module after the commit (media_retire.go
	// A4); nil = never, the pre-A4 behaviour.
	retire *mediaRetire
	// privacy is the is_private toggle (privacy.go); nil = the behaviour (protect refused as coming soon).
	privacy *privacyDeps
	// listener is told after a committed unprotect (WithPrivacyListener); nil publishes nothing.
	listener *privacyListener
	// protected is the set loader GetProfile asks (AQ6) before it returns the pin of a protected account to a
	// viewer who is neither the account nor a follower; nil = the pin is not filtered (tests, behaviour).
	protected ProtectedAuthors
	// requests counts a protected caller's pending follow requests for GetMe; nil = always 0.
	requests FollowRequestCounter
	// badge counts a messaging caller's unread conversations for GetMe; nil = always 0.
	badge    MessageBadge
	badgeLog *slog.Logger
	// pinLog and reqLog receive the WARN lines; nil means slog.Default.
	pinLog, reqLog *slog.Logger
	// authAudit turns on the GetMe sign-in identity audit (auth_baseline.go); false = the comparison never runs.
	authAudit    bool
	authAuditLog *slog.Logger
}

// Option configures optional identity.New dependencies that didn't exist in the Phase 0 bootstrap
// A variadic option keeps every existing New(repo, cache, cooldown) call site compiling
// unchanged rather than forcing a positional-argument churn across every test file.
type Option func(*service)

// WithBlockChecker wires the graph module's block check into GetProfile. Nil (the default)
// disables the check, matching the Phase 0 bootstrap's behavior.
func WithBlockChecker(bc BlockChecker) Option {
	return func(s *service) { s.blockChecker = bc }
}

// WithProtectedAuthors wires the protected set into GetProfile's pin rule. Nil keeps the pin unfiltered. log receives the WARN pin_omitted line; nil means slog.Default.
func WithProtectedAuthors(p ProtectedAuthors, log *slog.Logger) Option {
	return func(s *service) { s.protected, s.pinLog = p, log }
}

// WithFollowRequestCounter wires GetMe's pending_follow_request_count. Nil leaves it 0. log receives the WARN for a failed count; nil means slog.Default.
func WithFollowRequestCounter(c FollowRequestCounter, log *slog.Logger) Option {
	return func(s *service) { s.requests, s.reqLog = c, log }
}

// WithMessageBadge wires GetMe's unread_conversation_count. Nil leaves it 0. log receives the WARN for
// a failed count; nil means slog.Default().
func WithMessageBadge(b MessageBadge, log *slog.Logger) Option {
	return func(s *service) { s.badge, s.badgeLog = b, log }
}

// WithAvatarResolver wires UpdateProfile.avatar_media_id. Nil keeps non-empty values rejected.
func WithAvatarResolver(r AvatarResolver) Option {
	return func(s *service) { s.avatars = r }
}

// WithBannerResolver wires UpdateProfile.banner_media_id. Nil keeps non-empty values rejected as not ready.
func WithBannerResolver(r BannerResolver) Option {
	return func(s *service) { s.banners = r }
}

// WithPinChecker wires UpdateProfile.pinned_post_id. Nil keeps non-empty values rejected with VALIDATION.
func WithPinChecker(c PinChecker) Option {
	return func(s *service) { s.pins = c }
}

// WithExtrasFlags wires the profile_extras flag: the per-caller gate on setting the new fields and the
// global-off check that omits the pin from responses. Nil means off for everyone.
func WithExtrasFlags(f ExtrasFlags) Option {
	return func(s *service) { s.extras = f }
}

// WithFeatureFlags wires GetMe.enabled_features. Nil (the default) reports no flags.
func WithFeatureFlags(ff FeatureFlags) Option {
	return func(s *service) { s.features = ff }
}

// WithSignupAuth wires the M2 check : before a first profile is created the caller's
// own Firebase Auth user must exist and be enabled, because an ID token can outlive its deleted or disabled user.
// auth is the same narrow client the account lifecycle holds (C2); log receives the C3 audit line.
func WithSignupAuth(auth AuthClient, log *slog.Logger) Option {
	return func(s *service) {
		if auth != nil {
			s.signup = newAuthAdmin(auth, log)
		}
	}
}

// service implements both Service (the Connect handler's dependency) and Directory (batch profile lookups for
// graph, posts, media and moderation); apiserver binds the latter from the same value, and this is the compile-time
// proof that the binding cannot fail at startup.
var _ Directory = (*service)(nil)

// New builds the identity Service.
func New(repo Repo, c *Cache, handleChangeCooldown time.Duration, opts ...Option) Service {
	s := &service{repo: repo, cache: c, handleChangeCooldown: handleChangeCooldown, now: time.Now}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// ProfileNotFoundError is the one NOT_FOUND "profile not found" answer for a missing user, exposed so other
// modules (posts' GetUserTimeline) return the same bytes as GetProfile instead of copying the string.
func ProfileNotFoundError() error { return notFoundErr() }

func notFoundErr() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "profile not found")
}

// getProfileCached is the read-through cache every RPC uses: a cache hit (60s TTL) and a
// negative-cache hit (M1: ~10s "no profile yet" cache) read nothing; the latter matters because this is
// exactly what authn.AccountStatusInterceptor calls (via AccountStatus below) for every request from a
// caller who never completes sign-up, so without it such a caller could burn one Firestore read per
// request indefinitely.
func (s *service) getProfileCached(ctx context.Context, uid string) (Profile, error) {
	if p, ok := s.cache.GetProfile(uid); ok {
		return p, nil
	}
	if s.cache.GetNotFound(uid) {
		return Profile{}, notFoundErr()
	}
	p, err := s.repo.GetProfile(ctx, uid)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			s.cache.SetNotFound(uid)
			return Profile{}, notFoundErr()
		}
		return Profile{}, logger.RedactErr(fmt.Errorf("identity: get profile: %w", err), uid)
	}
	s.cache.SetProfile(p)
	return p, nil
}

// CreateProfile: see repo_firestore.go for the transaction. Idempotent by uid: a
// replay (profile already exists) is a pure read, no writes and no Auth call. Auth (M2): exactly
// one users.get of the token's own uid, only when users/{uid} does not exist, before any create; a deleted or
// disabled Auth user is PERMISSION_DENIED, an Auth outage UNAVAILABLE (fail closed), nothing written either way.
// No extra Firestore operation.
func (s *service) CreateProfile(ctx context.Context, uid, idempotencyKey, handle, displayName string) (Profile, error) {
	if idempotencyKeyIssue(idempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if reason := handleFormatIssue(handle); reason != "" {
		return Profile{}, apierr.Validation("handle", "handle must be 3-15 characters: letters, numbers, underscore, and not reserved").WithMeta("reason", reason)
	}
	if displayNameIssue(displayName) {
		return Profile{}, apierr.Validation("display_name", "display name must be 1-50 characters and contain a visible character")
	}

	handleLower := strings.ToLower(handle)
	var authorize func(context.Context) (*AuthBaseline, error)
	if s.signup != nil {
		authorize = func(ctx context.Context) (*AuthBaseline, error) {
			return s.signup.checkSignup(ctx, newSignupTarget(uid))
		}
	}
	profile, _, err := s.repo.CreateProfile(ctx, uid, handle, handleLower, normalizeDisplayName(displayName), s.now().UTC(), authorize)
	if err != nil {
		switch {
		case errors.Is(err, errSignupRefused), errors.Is(err, ErrAuthAdminRefused):
			return Profile{}, apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "this account cannot be used to sign up")
		case errors.Is(err, errSignupUnavailable):
			return Profile{}, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "sign-up is temporarily unavailable, please retry").WithCause(err)
		}
		if errors.Is(err, ErrHandleTaken) {
			s.cache.InvalidateHandleFree(handleLower)
			return Profile{}, apierr.New(connect.CodeAlreadyExists, commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN, "handle is taken")
		}
		return Profile{}, logger.RedactErr(fmt.Errorf("identity: create profile: %w", err), uid)
	}
	s.cache.SetProfile(profile)
	return s.present(profile), nil
}

// CheckHandleAvailability reads once and never writes (a cache hit on the handle map or the 10 s negative handle
// cache reads nothing). A stale "available" is only a hint; CreateProfile/ChangeHandle stay transactional.
func (s *service) CheckHandleAvailability(ctx context.Context, handle string) (bool, string, error) {
	if reason := handleFormatIssue(handle); reason != "" {
		return false, reason, nil
	}
	lower := strings.ToLower(handle)
	if _, ok := s.cache.GetHandleUID(lower); ok {
		return false, "", nil
	}
	if s.cache.GetHandleFree(lower) {
		return true, "", nil
	}
	_, err := s.repo.ResolveHandle(ctx, lower)
	switch {
	case err == nil:
		return false, "", nil
	case errors.Is(err, ErrNotFound):
		s.cache.SetHandleFree(lower)
		return true, "", nil
	default:
		return false, "", fmt.Errorf("identity: check handle availability %q: %w", handle, err)
	}
}

// GetMe returns the caller's profile plus the unread notification count.
// enabled_features comes from the FeatureFlags provider, with no extra read.
// pending_follow_request_count is one count() on followRequests, only for a caller whose isPrivate is true and whose
// 30 s cached count is gone; every other caller (a public caller never reaches the counter) and every hit reads
// nothing. A failed count is WARN pending_count_failed with the badge at 0.
// unread_conversation_count is a count on users/{uid}/dmInbox (Limit 100) on a cache miss for a caller with
// messaging on; every other caller and every hit (30 s) reads nothing. A failed count is WARN
// unread_conversations_failed with the badge at 0.
func (s *service) GetMe(ctx context.Context, uid string) (MeResult, error) {
	profile, err := s.getProfileCached(ctx, uid)
	if err != nil {
		return MeResult{}, err
	}
	// Warn-only: no result, no error, no read; it cannot change what GetMe answers.
	s.auditAuthIdentity(ctx, profile)
	var enabled []string
	if s.features != nil {
		enabled = s.features.EnabledFeatures(uid)
	}
	res := MeResult{Profile: s.present(profile), EnabledFeatures: enabled, PendingFollowRequestCount: s.pendingRequests(ctx, profile)}
	res.UnreadConversationCount = s.unreadConversations(ctx, uid, enabled)
	res.HomeTabs = visibleHomeTabs(profile.HomeTabs(), enabled)
	if n, ok := s.cache.GetUnreadCount(uid); ok {
		res.UnreadNotificationCount = n
		return res, nil
	}
	n, err := s.repo.UnreadNotificationCount(ctx, uid, profile.NotificationsSeenAt)
	if err != nil {
		return MeResult{}, logger.RedactErr(fmt.Errorf("identity: get me: %w", err), uid)
	}
	s.cache.SetUnreadCount(uid, n)
	res.UnreadNotificationCount = n
	return res, nil
}

// unreadConversations is the GetMe messages badge: the caller's unread conversations when messaging is on for the caller
// (enabled holds "messaging"), else 0 with no read. Cached 30 s per uid (staleness bound: 30 s, shorter when this
// instance sees a send to or a mark-read by the user, which evict it through MessageBadgeCache). An error is logged and
// answers 0; it is never cached, so the next GetMe retries.
func (s *service) unreadConversations(ctx context.Context, uid string, enabled []string) int64 {
	if s.badge == nil || !slices.Contains(enabled, MessagingFlag) {
		return 0
	}
	if n, ok := s.cache.GetConversationBadge(uid); ok {
		logger.SetRequestField(ctx, "unread_conversations_cache_hit", true)
		return n
	}
	logger.SetRequestField(ctx, "unread_conversations_cache_hit", false)
	n, err := s.badge.UnreadConversations(ctx, uid)
	if err != nil {
		orDefault(s.badgeLog).WarnContext(ctx, "unread_conversations_failed", append([]any{"uid_hash", logger.HashUID(uid), "error", logger.CauseChain(logger.RedactErr(err, uid))}, logger.TraceAttrs(ctx)...)...)
		return 0
	}
	s.cache.SetConversationBadge(uid, n)
	return n
}

// MessageBadgeCache implements messaging.BadgeCache on identity's side: Forget evicts only the cached
// unread_conversation_count of these users on this instance, leaving the profile and the notification count cached.
// apiserver passes it as messaging.Deps.Badge.
type MessageBadgeCache struct{ c *Cache }

// NewMessageBadgeCache binds the eviction to identity's cache.
func NewMessageBadgeCache(c *Cache) *MessageBadgeCache { return &MessageBadgeCache{c: c} }

// Forget evicts the cached unread conversation count of each uid (a send evicts sender and recipient, a mark-read the caller).
func (m *MessageBadgeCache) Forget(uids ...string) {
	for _, uid := range uids {
		m.c.InvalidateConversationBadge(uid)
	}
}

// pendingRequests is the GetMe badge: the caller's pending follow requests when the caller is protected, else 0 with no
// read. Cached 30 s per uid (staleness bound: 30 s, shorter when this instance sees a follow_request notification or an
// accept, which evict it). An error is logged and answers 0; it is never cached, so the next GetMe retries.
func (s *service) pendingRequests(ctx context.Context, p Profile) int64 {
	if s.requests == nil || !p.IsPrivate {
		return 0
	}
	if n, ok := s.cache.GetPendingCount(p.UserID); ok {
		logger.SetRequestField(ctx, "follow_requests_count_cache_hit", true)
		return n
	}
	logger.SetRequestField(ctx, "follow_requests_count_cache_hit", false)
	n, err := s.requests.PendingFollowRequests(ctx, p.UserID)
	if err != nil {
		orDefault(s.reqLog).WarnContext(ctx, "pending_count_failed", append([]any{"uid_hash", logger.HashUID(p.UserID), "error", logger.CauseChain(logger.RedactErr(err, p.UserID))}, logger.TraceAttrs(ctx)...)...)
		return 0
	}
	s.cache.SetPendingCount(p.UserID, n)
	return n
}

// GetProfile resolves the handle and loads the profile (both cacheable), and consults BlockChecker when it is
// wired. If the
// target blocked the caller, returns the byte-identical NOT_FOUND used for a missing profile ("no existence leak")
// — the caller can still view a target they themselves blocked, so they can unblock.
func (s *service) GetProfile(ctx context.Context, callerUID string, target ProfileTarget) (Profile, error) {
	uid := target.UserID
	if uid == "" {
		if target.Handle == "" {
			return Profile{}, apierr.Validation("target", "user_id or handle is required")
		}
		// L3: only a well-formed handle can exist; anything else (reserved doc-id shape, over-long) would
		// otherwise reach Firestore as an invalid document id and surface as INTERNAL.
		if !handle.ValidRun(target.Handle) || reservedDocID(target.Handle) {
			return Profile{}, apierr.Validation("handle", "handle must be 3-15 characters: letters, numbers, underscore")
		}
	} else if userIDIssue(uid) {
		return Profile{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if uid == "" {
		lower := strings.ToLower(target.Handle)
		if cached, ok := s.cache.GetHandleUID(lower); ok {
			uid = cached
		} else if s.cache.GetHandleFree(lower) {
			return Profile{}, notFoundErr() // negative handle cache: no read
		} else {
			resolved, err := s.repo.ResolveHandle(ctx, lower)
			if err != nil {
				if errors.Is(err, ErrNotFound) {
					s.cache.SetHandleFree(lower)
					return Profile{}, notFoundErr()
				}
				return Profile{}, fmt.Errorf("identity: resolve handle %q: %w", target.Handle, err)
			}
			uid = resolved
		}
	}
	profile, err := s.getProfileCached(ctx, uid)
	if err != nil {
		return Profile{}, err
	}
	// M3 (security review): a SUSPENDED or DELETING profile is invisible to everyone but its
	// owner, with the byte-identical NOT_FOUND a missing user gets, by id and by handle alike. 0 extra reads.
	// This is also what keeps "handle taken + NOT_FOUND" ambiguous between blocked-by, suspended and deleting.
	if profile.Status != AccountStatusActive && callerUID != uid {
		return Profile{}, notFoundErr()
	}
	if s.blockChecker != nil && callerUID != "" && callerUID != uid {
		blocked, err := s.blockChecker.IsBlockedBy(ctx, callerUID, uid)
		if err != nil {
			return Profile{}, logger.RedactErr(fmt.Errorf("identity: block check: %w", err), callerUID, uid)
		}
		if blocked {
			return Profile{}, notFoundErr()
		}
	}
	out := s.present(profile)
	if out.PinnedPostID != "" && callerUID != uid {
		out.PinnedPostID = s.pinForViewer(ctx, callerUID, uid, out.PinnedPostID)
	}
	return out, nil
}

// present is the response view of a profile, the one place the profile_extras kill switch is applied:
// while the flag is globally off (Registry.GloballyOff: mode off; an allowlist or a percent, even an
// empty one or 0, is a rollout, not the switch; no flags wired counts as off) it omits pinned_post_id (so clients stop
// the GetPost call) and website (the one field that sends a viewer somewhere else, the phishing surface). It covers
// every Profile identity returns, the owner's own view included, without a read. Everything else is returned as stored;
// rendering of banner and location stays ungated (D9). The cache, the stored document and the export keep the stored
// values, so a flag that comes back shows both again without a write.
func (s *service) present(p Profile) Profile {
	if s.extras == nil || s.extras.GloballyOff(ProfileExtrasFlag) {
		p.PinnedPostID = ""
		p.Website = ""
	}
	return p
}

// pinRejected is the one answer for every pinned_post_id the caller may not pin (bad format, no checker, not theirs,
// not visible, a REPOST, unknown): VALIDATION field=pinned_post_id, so the call is no existence oracle. The request log
// gets pin_check=rejected and never the cause.
func pinRejected(ctx context.Context) error {
	logger.SetRequestField(ctx, "pin_check", "rejected")
	return apierr.Validation("pinned_post_id", "pinned_post_id must be one of your own posts")
}

// extrasDisabled is the profile_extras gate for UpdateProfile: nil when the flag is on for uid, otherwise
// FEATURE_DISABLED with metadata feature=profile_extras. No flags wired = off. It never reads Firestore.
func (s *service) extrasDisabled(ctx context.Context, uid string) error {
	var enabled func(uid, name string) bool
	if s.extras != nil {
		enabled = s.extras.Enabled
	}
	if flags.Guard(ctx, enabled, uid, ProfileExtrasFlag) != nil {
		return flags.DisabledError().WithMeta("feature", ProfileExtrasFlag)
	}
	return nil
}

// setsExtra reports whether an optional profile-extras field sets a value: present and not exactly "". The exact empty
// string is a clear and is never gated; anything else, whitespace-only included, is a set.
func setsExtra(p *string) bool { return p != nil && *p != "" }

// UpdateProfile runs the users/{uid} transaction (L-4: it writes nothing when the request changes nothing,
// because UpdatedAt moves only on a real change and the repo then skips the write). Before the transaction it
// resolves a non-empty avatar_media_id and banner_media_id against the media doc and a non-empty pinned_post_id
// against the post (cache-first). A media id that is not a READY, caller-owned AVATAR or
// BANNER is ERROR_REASON_MEDIA_NOT_READY; any pinned_post_id the caller may not pin is VALIDATION
// field=pinned_post_id (one answer for every cause, so the call is no existence oracle).
// Setting banner_media_id, location, website or pinned_post_id (any non-empty value, whitespace-only included) needs
// profile_extras on for the caller: otherwise FEATURE_DISABLED feature=profile_extras, checked before any validation or
// read, so nothing is written (D9), and a request that mixes a clear with a set is refused whole. The exact string "" (a clear) is
// accepted from any authenticated caller whatever the flag, globally off included
// (Amendment 1 A2: a rectification or erasure request must not wait for a flag). None of them bumps
// snapshotVersion, spends snapshotEdits or enqueues a snapshot job (not in AuthorSnapshot). The request log carries
// profile_fields_changed (names only, never values) and, for a non-empty pinned_post_id, pin_check=ok|rejected
// (never the cause).
//
// An is_private that differs from the stored value runs one transaction (repo_privacy_firestore.go):
// a protect reads users and the privacy/protectedAuthors doc for the cap, and writes isPrivate and the set doc
// with ArrayUnion; an unprotect reads users and writes the same two (ArrayRemove, no cap check). An is_private equal to
// the stored value is the plain update. A full set is LIMIT_REACHED limit=private_accounts, writing nothing. After the commit the committing instance updates its own copy of
// the set at once (Install on a protect, Apply on an unprotect; other instances within CACHE_TTL), and an unprotect calls
// PrivacyListener.BecamePublic (detached, short deadline; a failure is ERROR privacy_public_enqueue_failed and never fails the
// call). The cached profile is written from the committed data (SetProfile), so no Directory.Forget is needed. A toggle bumps
// no snapshotVersion and enqueues no snapshot job. is_private=true is gated by private_accounts; is_private=false never is.
//
// A4: a commit that replaced or removed the avatar or the banner hands the old image to the media
// module's retire step (WithMediaRetirer, after the commit, best effort): no extra Firestore read, since the old URLs are
// in the document the transaction read, and at most 2 Pub/Sub publishes (one per image, each under a 2 s deadline). The
// step deletes the old objects after a grace of at least 24 h, only while PROFILE_MEDIA_RETIRE allows it; a failed hand-over
// is logged at ERROR and the image stays until the account is deleted. A request that changes nothing hands over
// nothing.
func (s *service) UpdateProfile(ctx context.Context, uid string, params UpdateProfileParams) (Profile, error) {
	if idempotencyKeyIssue(params.IdempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	// Is_private=true needs private_accounts on for the caller, checked first so a caller outside the
	// cohort learns nothing about the other fields and nothing is read or written. A request that sets is_private=true
	// together with other fields is refused whole (the M-1 mixed rule). is_private=false is never gated (the undo rule).
	if params.IsPrivate != nil && *params.IsPrivate {
		if err := s.privateAccountsDisabled(ctx, uid); err != nil {
			return Profile{}, err
		}
	}
	if params.DisplayName != nil && displayNameIssue(*params.DisplayName) {
		return Profile{}, apierr.Validation("display_name", "display name must be 1-50 characters and contain a visible character")
	}
	if params.Bio != nil && bioIssue(*params.Bio) {
		return Profile{}, apierr.Validation("bio", "bio must be at most 160 characters")
	}
	// The flag gate comes before the field validation and before any read, so a
	// caller outside the cohort learns nothing about the fields and costs nothing. Only a SET is gated: the exact
	// string "" is a clear and always passes. The test is on the raw value, before normalisation, so "   " (which
	// would normalise to a clear) is still a set here.
	if setsExtra(params.BannerMediaID) || setsExtra(params.Location) || setsExtra(params.Website) || setsExtra(params.PinnedPostID) {
		if err := s.extrasDisabled(ctx, uid); err != nil {
			return Profile{}, err
		}
	}
	var location, website string
	if params.Location != nil {
		location = normalizeLocation(*params.Location)
		if locationIssue(location) {
			return Profile{}, apierr.Validation("location", "location must be at most 30 characters on one line, without invisible characters")
		}
	}
	if params.Website != nil {
		var ok bool
		if website, ok = normalizeWebsite(*params.Website); !ok {
			return Profile{}, apierr.Validation("website", "website must be an http or https address of at most 100 characters")
		}
	}
	if params.PinnedPostID != nil && *params.PinnedPostID != "" && !ids.ValidPostID(*params.PinnedPostID) {
		return Profile{}, pinRejected(ctx)
	}
	var avatar *AvatarRef
	if params.AvatarMediaID != nil && *params.AvatarMediaID != "" {
		notReady := apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY, "avatar is not ready; upload it again")
		if s.avatars == nil {
			return Profile{}, notReady
		}
		ref, err := s.avatars.ResolveAvatar(ctx, uid, *params.AvatarMediaID)
		switch {
		case errors.Is(err, ErrAvatarNotReady):
			return Profile{}, notReady
		case err != nil:
			return Profile{}, logger.RedactErr(fmt.Errorf("identity: resolve avatar: %w", err), uid)
		}
		avatar = &ref
	}
	var banner *BannerRef
	if params.BannerMediaID != nil && *params.BannerMediaID != "" {
		notReady := apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY, "banner is not ready; upload it again")
		if s.banners == nil {
			// No resolver wired (apiserver always wires one): every non-empty banner_media_id gets this one answer.
			return Profile{}, notReady
		}
		ref, err := s.banners.ResolveBanner(ctx, uid, *params.BannerMediaID)
		switch {
		case errors.Is(err, ErrBannerNotReady):
			return Profile{}, notReady
		case err != nil:
			return Profile{}, logger.RedactErr(fmt.Errorf("identity: resolve banner: %w", err), uid)
		}
		banner = &ref
	}
	if params.PinnedPostID != nil && *params.PinnedPostID != "" {
		if s.pins == nil {
			// No checker wired (apiserver always wires one): pinning is unavailable and answers like any other post the
			// caller may not pin.
			return Profile{}, pinRejected(ctx)
		}
		can, err := s.pins.CanPin(ctx, uid, *params.PinnedPostID)
		if err != nil {
			return Profile{}, logger.RedactErr(fmt.Errorf("identity: pin check: %w", err), uid)
		}
		if !can {
			return Profile{}, pinRejected(ctx)
		}
		logger.SetRequestField(ctx, "pin_check", "ok")
	}
	// Without the privacy wiring (unit tests) protecting stays refused before any read or write (behaviour).
	if s.privacy == nil && params.IsPrivate != nil && *params.IsPrivate {
		return Profile{}, apierr.Validation("is_private", "private accounts are coming soon")
	}

	// A display-name edit rewrites the author snapshot on the user's posts, only while FEATURE_PROFILE_SNAPSHOT is on for
	// the caller.
	refresh := s.snapshotsOn(uid)

	now := s.now().UTC()
	snapshotChanged := false
	var changed []string
	var retired []retiredImage // the old avatar and banner this commit replaced or removed (A4); 0 extra reads
	mutate := func(p *Profile) {
		changed, snapshotChanged, retired = changed[:0], false, retired[:0] // the transaction may run more than once
		// L-4: a request that changes nothing must leave the profile (UpdatedAt included) as it was, so the repo
		// skips the write; UpdatedAt moves only below, when something really changed.
		orig := *p
		// note records a field name for profile_fields_changed when the stored value really changes.
		note := func(name string, differs bool) {
			if differs {
				changed = append(changed, name)
			}
		}
		if params.DisplayName != nil {
			if name := normalizeDisplayName(*params.DisplayName); name != p.DisplayName {
				p.DisplayName = name
				p.SnapshotVersion++
				snapshotChanged = true
				changed = append(changed, "display_name")
			}
		}
		if params.Bio != nil {
			bio := normalizeBio(*params.Bio) // trim + NFC, the form bioIssue counted (L-2c)
			note("bio", bio != p.Bio)
			p.Bio = bio
		}
		if avatar != nil {
			note("avatar", avatar.URL != p.AvatarURL || avatar.ThumbURL != p.AvatarThumbURL)
			p.AvatarURL, p.AvatarThumbURL = avatar.URL, avatar.ThumbURL
		}
		if params.AvatarMediaID != nil && *params.AvatarMediaID == "" {
			note("avatar", p.AvatarURL != "" || p.AvatarThumbURL != "")
			p.AvatarURL = ""
			p.AvatarThumbURL = ""
		}
		// The extras are plain field writes. None of them touches snapshotVersion (not in AuthorSnapshot).
		if banner != nil {
			note("banner", banner.URL != p.BannerURL || banner.ThumbURL != p.BannerThumbURL)
			p.BannerURL, p.BannerThumbURL = banner.URL, banner.ThumbURL
		}
		if params.BannerMediaID != nil && *params.BannerMediaID == "" {
			note("banner", p.BannerURL != "" || p.BannerThumbURL != "")
			p.BannerURL = ""
			p.BannerThumbURL = ""
		}
		if params.Location != nil {
			note("location", location != p.Location)
			p.Location = location
		}
		if params.Website != nil {
			note("website", website != p.Website)
			p.Website = website
		}
		if params.PinnedPostID != nil {
			note("pinned_post", *params.PinnedPostID != p.PinnedPostID)
			p.PinnedPostID = *params.PinnedPostID
		}
		if params.IsPrivate != nil {
			p.IsPrivate = *params.IsPrivate
		}
		if *p != orig {
			p.UpdatedAt = now
			// Compared against the document this transaction read, so the old URLs cost no read of their own, and a
			// request that changed nothing (no write) retires nothing.
			retired = retiredImages(orig, *p)
		}
	}
	var (
		profile Profile
		err     error
		toggle  PrivacyUpdate
	)
	if s.privacy != nil && params.IsPrivate != nil {
		// An is_private request runs the toggle transaction. Equal to the stored value it behaves like the plain
		// update.
		toggle, err = s.privacy.repo.UpdateProfileWithPrivacy(ctx, uid, mutate, s.privacy.limits)
		profile = toggle.Profile
		logger.SetRequestField(ctx, fieldPrivacyToggleAttempts, toggle.Attempts)
		if err != nil {
			if refusal := privacyRefusal(ctx, err); refusal != nil {
				return Profile{}, refusal
			}
		}
	} else {
		profile, err = s.repo.UpdateProfile(ctx, uid, mutate)
	}
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Profile{}, notFoundErr()
		}
		return Profile{}, logger.RedactErr(fmt.Errorf("identity: update profile: %w", err), uid)
	}
	// The written profile is the cache entry (read-your-writes, no read); Directory.Forget would only evict it.
	s.cache.SetProfile(profile)
	if s.privacy != nil && params.IsPrivate != nil {
		s.afterPrivacyCommit(ctx, uid, toggle, now)
	}
	if refresh && snapshotChanged {
		s.enqueueSnapshotRefresh(ctx, uid, profile.SnapshotVersion)
	}
	if len(changed) > 0 {
		logger.SetRequestField(ctx, "profile_fields_changed", strings.Join(changed, ",")) // names only, never values
	}
	s.retireImages(ctx, uid, retired, now)
	return s.present(profile), nil
}

// ChangeHandle: M4 fix: the no-op, case-only
// rename, cooldown and handle-uniqueness checks all run inside FirestoreRepo.ChangeHandle's own
// transaction, against the doc read fresh there — never against this instance's cache, which could be
// stale relative to a change committed on another Cloud Run instance. That also means this service method
// no longer needs its own pre-transaction read to decide those, whether or not the caller's profile was already
// cached.
func (s *service) ChangeHandle(ctx context.Context, uid, idempotencyKey, newHandle string) (Profile, error) {
	if idempotencyKeyIssue(idempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if reason := handleFormatIssue(newHandle); reason != "" {
		return Profile{}, apierr.Validation("new_handle", "handle must be 3-15 characters: letters, numbers, underscore, and not reserved").WithMeta("reason", reason)
	}
	newLower := strings.ToLower(newHandle)
	// Whether this rename changed the snapshot is decided by the version the repo's transaction writes; the
	// version known before the call (cache, no read) is the baseline. No cached baseline means "assume changed":
	// the job is replay-safe and a no-op write is rare.
	before, haveBefore := s.cache.GetProfile(uid)

	profile, oldHandleLower, err := s.repo.ChangeHandle(ctx, uid, newHandle, newLower, s.now().UTC(), s.handleChangeCooldown)
	if err != nil {
		var cooldown *ErrHandleChangeCooldown
		switch {
		case errors.As(err, &cooldown):
			return Profile{}, apierr.New(
				connect.CodeFailedPrecondition,
				commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
				"you can only change your handle once every 7 days",
			).WithMeta("quota", "handle_change").WithRetryAfter(cooldown.RetryAfter)
		case errors.Is(err, ErrHandleTaken):
			s.cache.InvalidateHandleFree(newLower)
			return Profile{}, apierr.New(connect.CodeAlreadyExists, commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN, "handle is taken")
		case errors.Is(err, ErrNotFound):
			return Profile{}, notFoundErr()
		default:
			return Profile{}, logger.RedactErr(fmt.Errorf("identity: change handle: %w", err), uid)
		}
	}
	s.cache.SetProfile(profile)
	if oldHandleLower != "" {
		s.cache.InvalidateHandle(oldHandleLower)
	}
	// Handle changes are bounded by the 7-day cooldown.
	if s.snapshotsOn(uid) && (!haveBefore || before.SnapshotVersion != profile.SnapshotVersion) {
		s.enqueueSnapshotRefresh(ctx, uid, profile.SnapshotVersion)
	}
	return s.present(profile), nil
}

// GetProfiles implements Directory: cache-first, then one GetAll for misses. Ids with no
// ACTIVE profile (missing, or a status other than ACTIVE) are simply absent from the result.
func (s *service) GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error) {
	found, _, err := s.LookupProfiles(ctx, uids)
	return found, err
}

// LookupProfiles implements Directory: GetProfiles plus the uids CONFIRMED to have no
// users/{uid} document by the GetAll issued in this call. Same cost as GetProfiles (cache-first, one GetAll
// for misses, 0 extra reads). Non-ACTIVE users are in neither result. A uid known missing only from the
// short negative cache is also in neither: a clean-up must rest on a fresh read, so a re-created profile
// can't be mistaken for a deleted one.
func (s *service) LookupProfiles(ctx context.Context, uids []string) (map[string]Profile, []string, error) {
	out := make(map[string]Profile, len(uids))
	var misses []string
	for _, uid := range uids {
		if p, ok := s.cache.GetProfile(uid); ok {
			if p.Status == AccountStatusActive {
				out[uid] = p
			}
			continue
		}
		if s.cache.GetNotFound(uid) {
			continue
		}
		misses = append(misses, uid)
	}
	if len(misses) == 0 {
		return out, nil, nil
	}
	fetched, err := s.repo.GetProfiles(ctx, misses)
	if err != nil {
		return nil, nil, fmt.Errorf("identity: get profiles: %w", err)
	}
	for uid, p := range fetched {
		s.cache.SetProfile(p)
		if p.Status == AccountStatusActive {
			out[uid] = p
		}
	}
	var missing []string
	for _, uid := range misses {
		if _, ok := fetched[uid]; !ok {
			s.cache.SetNotFound(uid)
			missing = append(missing, uid)
		}
	}
	return out, missing, nil
}

// ResolveHandles implements Directory: cache-first (handle->uid hits, then the negative handle
// cache), then one GetAll for the remaining handles. Malformed and reserved handles are skipped without a read
// (they can never own a handle doc); more than MaxResolveHandles distinct candidates is a caller bug.
// A positive cache entry older than notFoundTTL (10 s), or contradicted by a cached profile, is a miss.
// Residual, accepted: a rename plus a reclaim within 10 s observed on another instance.
// It never writes.
func (s *service) ResolveHandles(ctx context.Context, lowers []string) (map[string]string, error) {
	out := make(map[string]string, len(lowers))
	var misses []string
	seen := make(map[string]struct{}, len(lowers))
	for _, h := range lowers {
		h = strings.ToLower(h)
		if _, dup := seen[h]; dup {
			continue
		}
		seen[h] = struct{}{}
		if handleFormatIssue(h) != "" {
			continue
		}
		// D21 G5: mentions are stored permanently, so a positive entry only counts while it is at most
		// notFoundTTL old (GetProfile by handle keeps the 60 s TTL), and not when a cached profile of that uid
		// shows another handle (a rename seen through a fresher profile). Both only turn a hit into a miss in
		// the same single GetAll below.
		if uid, ok := s.cache.GetHandleUIDFresh(h, notFoundTTL); ok {
			if p, cached := s.cache.GetProfile(uid); !cached || p.HandleLower == h {
				out[h] = uid
				continue
			}
			s.cache.InvalidateHandle(h)
		}
		if s.cache.GetHandleFree(h) {
			continue
		}
		misses = append(misses, h)
	}
	if len(seen) > MaxResolveHandles {
		return nil, fmt.Errorf("identity: ResolveHandles of %d handles exceeds the limit of %d", len(seen), MaxResolveHandles)
	}
	if len(misses) == 0 {
		return out, nil
	}
	found, err := s.repo.ResolveHandles(ctx, misses)
	if err != nil {
		return nil, fmt.Errorf("identity: resolve handles: %w", err)
	}
	for _, h := range misses {
		if uid, ok := found[h]; ok {
			s.cache.SetHandleUID(h, uid)
			out[h] = uid
			continue
		}
		s.cache.SetHandleFree(h)
	}
	return out, nil
}

// Forget implements Directory: evicts uid's cached profile and unread count on this instance (project rule:
// "update the instance cache from written data instead of re-reading" — this is the eviction half, called
// by another module right after its own commit changed users/{uid} through Counters).
func (s *service) Forget(uids ...string) {
	for _, uid := range uids {
		s.cache.InvalidateProfile(uid)
		s.cache.InvalidateUnreadCount(uid)
	}
}

// ForgetUnread implements Directory: evicts only the cached unread count.
func (s *service) ForgetUnread(uids ...string) {
	for _, uid := range uids {
		s.cache.InvalidateUnreadCount(uid)
	}
}

// AccountStatus backs pkg/platform/authn.AccountStatusProvider; reuses the same 60s cache as every
// other RPC, so it adds no Firestore read once a user's first request has warmed the cache.
func (s *service) AccountStatus(ctx context.Context, uid string) (bool, AccountStatus, error) {
	p, err := s.getProfileCached(ctx, uid)
	if err != nil {
		var ae *apierr.Error
		if errors.As(err, &ae) && ae.Code == connect.CodeNotFound {
			return false, AccountStatusUnspecified, nil
		}
		return false, AccountStatusUnspecified, err
	}
	return true, p.Status, nil
}

// PrivateAccountsFlag is the wire name of FEATURE_PRIVATE_ACCOUNTS: it gates setting is_private=true
// through UpdateProfile (and, in later tickets, nothing that enforces an existing protection). is_private=false is
// accepted from any caller whatever the flag (the undo rule).
const PrivateAccountsFlag = "private_accounts"

// privateAccountsDisabled is the private_accounts gate for UpdateProfile: nil when the flag is on for uid, otherwise
// FEATURE_DISABLED with metadata feature=private_accounts. No flags wired = off. It never reads Firestore. It shares the
// ExtrasFlags seam (WithExtrasFlags), which *flags.Registry satisfies for every flag name.
func (s *service) privateAccountsDisabled(ctx context.Context, uid string) error {
	var enabled func(uid, name string) bool
	if s.extras != nil {
		enabled = s.extras.Enabled
	}
	if flags.Guard(ctx, enabled, uid, PrivateAccountsFlag) != nil {
		return flags.DisabledError().WithMeta("feature", PrivateAccountsFlag)
	}
	return nil
}

// pinForViewer is the pin rule for GetProfile: the pin of a protected account is shown to the account
// itself (the caller never gets here), to its followers and to nobody else; every other header field is public. Order, so
// that the common cases cost nothing (AQ6): a follower keeps the pin on the viewer's cached snapshot alone, without the set;
// anyone else needs the set (a detached instance cache, not read on the caller's behalf), and a set that cannot be loaded
// omits the pin (fail closed) with WARN pin_omitted=set_unavailable while the rest of the profile is returned. The snapshot was loaded by the block check just before.
// A failed follow check also omits the pin.
func (s *service) pinForViewer(ctx context.Context, viewerUID, targetUID, pin string) string {
	if s.protected == nil {
		return pin
	}
	following := false
	if s.blockChecker != nil && viewerUID != "" {
		f, err := s.blockChecker.IsFollowing(ctx, viewerUID, targetUID)
		if err != nil {
			s.warnPinOmitted(ctx, "follow_check_failed", viewerUID)
			return ""
		}
		following = f
	}
	if following {
		return pin
	}
	set, err := s.protected.Current(ctx)
	if err != nil {
		s.warnPinOmitted(ctx, "set_unavailable", viewerUID)
		return ""
	}
	if set.CanSee(viewerUID, targetUID, false) { // not a follower here: visible only when the account is public
		return pin
	}
	logger.SetRequestField(ctx, "pin_omitted", "protected")
	return ""
}

func (s *service) warnPinOmitted(ctx context.Context, reason, viewerUID string) {
	logger.SetRequestField(ctx, "pin_omitted", reason)
	orDefault(s.pinLog).WarnContext(ctx, "pin_omitted", append([]any{"pin_omitted", reason, "uid_hash", logger.HashUID(viewerUID)}, logger.TraceAttrs(ctx)...)...)
}

func orDefault(l *slog.Logger) *slog.Logger {
	if l == nil {
		return slog.Default()
	}
	return l
}
