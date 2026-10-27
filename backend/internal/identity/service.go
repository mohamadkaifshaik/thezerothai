package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
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
	// banners, pins and extras are the ADR-0024 profile-extras seams (W3-6). All nil by default: no resolver means a
	// non-empty banner_media_id is MEDIA_NOT_READY, no checker means a non-empty pinned_post_id is VALIDATION, and no
	// flags means profile_extras is off for every caller and globally off.
	banners BannerResolver
	pins    PinChecker
	extras  ExtrasFlags
	// signup is the M2 Auth-user check at the CreateProfile boundary; nil (tests) skips it. apiserver.Build always
	// wires it, so production never runs without it.
	signup *authAdmin
	// snap is the P2 profile-snapshot-refresh trigger (profile_snapshot.go); nil = never publishes.
	snap *profileSnapshots
}

// Option configures optional identity.New dependencies that didn't exist in the Phase 0 bootstrap
// (ADR-0008 T6): a variadic option keeps every existing New(repo, cache, cooldown) call site compiling
// unchanged rather than forcing a positional-argument churn across every test file.
type Option func(*service)

// WithBlockChecker wires the graph module's block check into GetProfile (ADR-0008 D9). Nil (the default)
// disables the check, matching the Phase 0 bootstrap's behavior.
func WithBlockChecker(bc BlockChecker) Option {
	return func(s *service) { s.blockChecker = bc }
}

// WithAvatarResolver wires UpdateProfile.avatar_media_id (P4). Nil keeps non-empty values rejected.
func WithAvatarResolver(r AvatarResolver) Option {
	return func(s *service) { s.avatars = r }
}

// WithBannerResolver wires UpdateProfile.banner_media_id (ADR-0024 D1). Nil keeps non-empty values rejected as not ready.
func WithBannerResolver(r BannerResolver) Option {
	return func(s *service) { s.banners = r }
}

// WithPinChecker wires UpdateProfile.pinned_post_id (ADR-0024 D3). Nil keeps non-empty values rejected with VALIDATION.
func WithPinChecker(c PinChecker) Option {
	return func(s *service) { s.pins = c }
}

// WithExtrasFlags wires the profile_extras flag (ADR-0024 D9): the per-caller gate on setting the new fields and the
// global-off check that omits the pin from responses. Nil means off for everyone.
func WithExtrasFlags(f ExtrasFlags) Option {
	return func(s *service) { s.extras = f }
}

// WithFeatureFlags wires GetMe.enabled_features (ADR-0008 D6). Nil (the default) reports no flags.
func WithFeatureFlags(ff FeatureFlags) Option {
	return func(s *service) { s.features = ff }
}

// WithSignupAuth wires the M2 check (ADR-0011 amendment 2026-10-08): before a first profile is created the caller's
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
// modules (posts' GetUserTimeline) return the same bytes as GetProfile instead of copying the string (ADR-0010 T9).
func ProfileNotFoundError() error { return notFoundErr() }

func notFoundErr() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "profile not found")
}

// getProfileCached is the read-through cache every RPC uses: 0 reads on a cache hit (ADR-0003: 60s TTL),
// 0 reads on a negative-cache hit (M1: ~10s "no profile yet" cache) — the latter matters because this is
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

// CreateProfile: worst case Firestore reads 2, writes 3 (ADR-0003; see repo_firestore.go). Idempotent by uid: a
// replay (profile already exists) is a pure read, no writes and no Auth call. Auth (M2, ADR-0011 amendment): exactly
// one users.get of the token's own uid, only when users/{uid} does not exist, before any create; a deleted or
// disabled Auth user is PERMISSION_DENIED, an Auth outage UNAVAILABLE (fail closed), nothing written either way.
// 0 extra Firestore ops.
func (s *service) CreateProfile(ctx context.Context, uid, idempotencyKey, handle, displayName string) (Profile, error) {
	if idempotencyKeyIssue(idempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if reason := handleFormatIssue(handle); reason != "" {
		return Profile{}, apierr.Validation("handle", "handle must be 3-15 characters: letters, numbers, underscore, and not reserved").WithMeta("reason", reason)
	}
	if displayNameIssue(displayName) {
		return Profile{}, apierr.Validation("display_name", "display name must be 1-50 characters")
	}

	handleLower := strings.ToLower(handle)
	var authorize func(context.Context) error
	if s.signup != nil {
		authorize = func(ctx context.Context) error { return s.signup.checkSignup(ctx, newSignupTarget(uid)) }
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

// CheckHandleAvailability: 1 read, 0 writes (cache hit on the handle map or the 10 s negative handle cache
// (ADR-0010 D5): 0 reads). A stale "available" is only a hint; CreateProfile/ChangeHandle stay transactional.
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

// GetMe: reads 2 worst case (profile + unread count, both cache misses), 1 typical (ADR-0003/proto).
// enabled_features (ADR-0008 D6) comes from the FeatureFlags provider, 0 extra reads.
func (s *service) GetMe(ctx context.Context, uid string) (MeResult, error) {
	profile, err := s.getProfileCached(ctx, uid)
	if err != nil {
		return MeResult{}, err
	}
	var enabled []string
	if s.features != nil {
		enabled = s.features.EnabledFeatures(uid)
	}
	if n, ok := s.cache.GetUnreadCount(uid); ok {
		return MeResult{Profile: s.present(profile), UnreadNotificationCount: n, EnabledFeatures: enabled}, nil
	}
	n, err := s.repo.UnreadNotificationCount(ctx, uid, profile.NotificationsSeenAt)
	if err != nil {
		return MeResult{}, logger.RedactErr(fmt.Errorf("identity: get me: %w", err), uid)
	}
	s.cache.SetUnreadCount(uid, n)
	return MeResult{Profile: s.present(profile), UnreadNotificationCount: n, EnabledFeatures: enabled}, nil
}

// GetProfile: reads up to 2 (handle resolve + profile; both cacheable), +1 more when BlockChecker is wired
// and misses its own cache (ADR-0008 D9/D2: proto worst case 3, +1 on a viewer's blockedByOverflow). If the
// target blocked the caller, returns the byte-identical NOT_FOUND used for a missing profile (ADR-0006 §6:
// "no existence leak") — the caller can still view a target they themselves blocked, so they can unblock.
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
			return Profile{}, notFoundErr() // negative handle cache (ADR-0010 D5): 0 reads
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
	// M3 (security review, ADR-0008 D9): a SUSPENDED or DELETING profile is invisible to everyone but its
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
	return s.present(profile), nil
}

// present is the response view of a profile: the pin is omitted while profile_extras is globally off (ADR-0024 D3, the
// kill switch that makes clients stop the GetPost call), 0 reads. Everything else is returned as stored; rendering
// of banner, location and website stays ungated (D9). The cache keeps the stored value, so a re-enabled flag shows the
// pin again without a write.
func (s *service) present(p Profile) Profile {
	if p.PinnedPostID != "" && (s.extras == nil || s.extras.GloballyOff(ProfileExtrasFlag)) {
		p.PinnedPostID = ""
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

// UpdateProfile: reads 1, writes 1 (the transaction's read and write of users/{uid}; 0 writes when the request changes nothing,
// W3-22 L-4: UpdatedAt moves only on a real change and the repo then skips the write), plus the account-status
// interceptor's profile read when its cache is cold (+1, outside this method). Resolves before the transaction add
// reads: +1 for a non-empty avatar_media_id (the media doc), +1 for a non-empty banner_media_id (the media doc,
// ADR-0024 D1), +1 for a non-empty pinned_post_id (the post, cache-first so 1 cold / 0 warm, D3). Worst case with the
// ADR-0024 fields (banner and pin) is 3 reads / 1 write in this method (4 with the interceptor cold); a request that
// also sets an avatar adds a fourth (5 with the interceptor). A media id that is not a READY, caller-owned AVATAR or
// BANNER is ERROR_REASON_MEDIA_NOT_READY; any pinned_post_id the caller may not pin is VALIDATION
// field=pinned_post_id (one answer for every cause, so the call is no existence oracle).
// banner_media_id, location, website and pinned_post_id (even "") need profile_extras on for the caller: otherwise
// FEATURE_DISABLED feature=profile_extras, checked before any validation or read, 0 writes (D9). None of them bumps
// snapshotVersion, spends snapshotEdits or enqueues a snapshot job (not in AuthorSnapshot). The request log carries
// profile_fields_changed (names only, never values) and, for a non-empty pinned_post_id, pin_check=ok|rejected
// (never the cause).
func (s *service) UpdateProfile(ctx context.Context, uid string, params UpdateProfileParams) (Profile, error) {
	if idempotencyKeyIssue(params.IdempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if params.DisplayName != nil && displayNameIssue(*params.DisplayName) {
		return Profile{}, apierr.Validation("display_name", "display name must be 1-50 characters")
	}
	if params.Bio != nil && bioIssue(*params.Bio) {
		return Profile{}, apierr.Validation("bio", "bio must be at most 160 characters")
	}
	// ADR-0024 D9: the flag gate comes before the field validation and before any read, so a caller outside the
	// cohort learns nothing about the fields and costs nothing.
	hasExtras := params.BannerMediaID != nil || params.Location != nil || params.Website != nil || params.PinnedPostID != nil
	if hasExtras {
		if err := s.extrasDisabled(ctx, uid); err != nil {
			return Profile{}, err
		}
	}
	var location, website string
	if params.Location != nil {
		location = normalizeLocation(*params.Location)
		if locationIssue(location) {
			return Profile{}, apierr.Validation("location", "location must be at most 30 characters on one line")
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
	// ADR-0008 D1 (L9): private accounts are deferred. is_private=false stays accepted (already the only
	// value profiles can hold); is_private=true is rejected before any read, 0 writes.
	if params.IsPrivate != nil && *params.IsPrivate {
		return Profile{}, apierr.Validation("is_private", "private accounts are coming soon")
	}

	// P2 (ADR-0003): a display-name edit rewrites the author snapshot on the user's posts, limited to
	// SnapshotEditsPerDay a day. The comparison uses the cached profile (0 reads: the interceptor warmed it); a
	// stale cache can only over-count an edit. Reserved before the write: 1 read, 1 write on quotas/{uid}.
	// Only while FEATURE_PROFILE_SNAPSHOT is on for the caller.
	refresh := s.snapshotsOn(uid)
	if refresh && params.DisplayName != nil {
		cur, err := s.getProfileCached(ctx, uid)
		if err != nil {
			return Profile{}, err
		}
		if normalizeDisplayName(*params.DisplayName) != cur.DisplayName {
			if err := s.reserveSnapshotEdit(ctx, uid); err != nil {
				return Profile{}, err
			}
		}
	}

	now := s.now().UTC()
	snapshotChanged := false
	var changed []string
	profile, err := s.repo.UpdateProfile(ctx, uid, func(p *Profile) {
		changed, snapshotChanged = changed[:0], false // the transaction may run more than once
		// W3-22 L-4: a request that changes nothing must leave the profile (UpdatedAt included) as it was, so the repo
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
			bio := strings.TrimSpace(*params.Bio)
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
		// ADR-0024: the extras are plain field writes. None of them touches snapshotVersion (not in AuthorSnapshot).
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
		}
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Profile{}, notFoundErr()
		}
		return Profile{}, logger.RedactErr(fmt.Errorf("identity: update profile: %w", err), uid)
	}
	s.cache.SetProfile(profile)
	if refresh && snapshotChanged {
		s.enqueueSnapshotRefresh(ctx, uid, profile.SnapshotVersion)
	}
	if len(changed) > 0 {
		logger.SetRequestField(ctx, "profile_fields_changed", strings.Join(changed, ",")) // names only, never values
	}
	// TODO(Phase 2): if IsPrivate changed, publish the visibility job (ADR-0003); private accounts are deferred.
	return s.present(profile), nil
}

// ChangeHandle: reads 2, writes 2, deletes 1 worst case (ADR-0003/proto). M4 fix: the no-op, case-only
// rename, cooldown and handle-uniqueness checks all run inside FirestoreRepo.ChangeHandle's own
// transaction, against the doc read fresh there — never against this instance's cache, which could be
// stale relative to a change committed on another Cloud Run instance. That also means this service method
// no longer needs its own pre-transaction read to decide those: every call costs exactly the repo's 2
// reads, matching the proto doc comment regardless of whether the caller's profile was already cached.
func (s *service) ChangeHandle(ctx context.Context, uid, idempotencyKey, newHandle string) (Profile, error) {
	if idempotencyKeyIssue(idempotencyKey) {
		return Profile{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if reason := handleFormatIssue(newHandle); reason != "" {
		return Profile{}, apierr.Validation("new_handle", "handle must be 3-15 characters: letters, numbers, underscore, and not reserved").WithMeta("reason", reason)
	}
	newLower := strings.ToLower(newHandle)
	// P2: whether this rename changed the snapshot is decided by the version the repo's transaction writes; the
	// version known before the call (cache, 0 reads) is the baseline. No cached baseline means "assume changed":
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
	// Handle changes are bounded by the 7-day cooldown, so they do not spend the daily snapshot-edit quota.
	if s.snapshotsOn(uid) && (!haveBefore || before.SnapshotVersion != profile.SnapshotVersion) {
		s.enqueueSnapshotRefresh(ctx, uid, profile.SnapshotVersion)
	}
	return s.present(profile), nil
}

// GetProfiles implements Directory: cache-first, then one GetAll for misses (ADR-0008 T6). Ids with no
// ACTIVE profile (missing, or a status other than ACTIVE) are simply absent from the result.
func (s *service) GetProfiles(ctx context.Context, uids []string) (map[string]Profile, error) {
	found, _, err := s.LookupProfiles(ctx, uids)
	return found, err
}

// LookupProfiles implements Directory (ADR-0008 T27): GetProfiles plus the uids CONFIRMED to have no
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

// ResolveHandles implements Directory (ADR-0010 D7, T7): cache-first (handle->uid hits, then the negative handle
// cache), then one GetAll for the remaining handles. Malformed and reserved handles are skipped without a read
// (they can never own a handle doc); more than MaxResolveHandles distinct candidates is a caller bug.
// A positive cache entry older than notFoundTTL (10 s), or contradicted by a cached profile, is a miss (ADR-0010
// D21 G5). Residual, accepted: a rename plus a reclaim within 10 s observed on another instance.
// Firestore: reads = uncached handles <= 10, writes 0.
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

// Forget implements Directory: evicts uid's cached profile and unread count on this instance (CLAUDE.md:
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
// other RPC, so this costs ~0 extra Firestore reads once a user's first request has warmed the cache.
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
