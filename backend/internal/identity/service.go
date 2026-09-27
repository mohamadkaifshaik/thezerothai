package identity

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// service is the default Service implementation: business rules + validation over a Repo, backed by an
// instance Cache. It holds no Firestore-specific knowledge (that's repo_firestore.go).
type service struct {
	repo                 Repo
	cache                *Cache
	handleChangeCooldown time.Duration
	now                  func() time.Time
}

// New builds the identity Service.
func New(repo Repo, c *Cache, handleChangeCooldown time.Duration) Service {
	return &service{repo: repo, cache: c, handleChangeCooldown: handleChangeCooldown, now: time.Now}
}

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
		return Profile{}, fmt.Errorf("identity: get profile %s: %w", uid, err)
	}
	s.cache.SetProfile(p)
	return p, nil
}

// CreateProfile: worst case reads 2, writes 3 (ADR-0003; see repo_firestore.go). Idempotent by uid: a
// replay (profile already exists) is a pure read, no writes.
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
	profile, _, err := s.repo.CreateProfile(ctx, uid, handle, handleLower, normalizeDisplayName(displayName), s.now().UTC())
	if err != nil {
		if errors.Is(err, ErrHandleTaken) {
			return Profile{}, apierr.New(connect.CodeAlreadyExists, commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN, "handle is taken")
		}
		return Profile{}, fmt.Errorf("identity: create profile %s: %w", uid, err)
	}
	s.cache.SetProfile(profile)
	return profile, nil
}

// CheckHandleAvailability: 1 read, 0 writes (cache hit on the handle map: 0 reads).
func (s *service) CheckHandleAvailability(ctx context.Context, handle string) (bool, string, error) {
	if reason := handleFormatIssue(handle); reason != "" {
		return false, reason, nil
	}
	lower := strings.ToLower(handle)
	if _, ok := s.cache.GetHandleUID(lower); ok {
		return false, "", nil
	}
	_, err := s.repo.ResolveHandle(ctx, lower)
	switch {
	case err == nil:
		return false, "", nil
	case errors.Is(err, ErrNotFound):
		return true, "", nil
	default:
		return false, "", fmt.Errorf("identity: check handle availability %q: %w", handle, err)
	}
}

// GetMe: reads 2 worst case (profile + unread count, both cache misses), 1 typical (ADR-0003/proto).
func (s *service) GetMe(ctx context.Context, uid string) (MeResult, error) {
	profile, err := s.getProfileCached(ctx, uid)
	if err != nil {
		return MeResult{}, err
	}
	if n, ok := s.cache.GetUnreadCount(uid); ok {
		return MeResult{Profile: profile, UnreadNotificationCount: n}, nil
	}
	n, err := s.repo.UnreadNotificationCount(ctx, uid, profile.NotificationsSeenAt)
	if err != nil {
		return MeResult{}, fmt.Errorf("identity: get me %s: %w", uid, err)
	}
	s.cache.SetUnreadCount(uid, n)
	return MeResult{Profile: profile, UnreadNotificationCount: n}, nil
}

// GetProfile: reads up to 2 (handle resolve + profile; both cacheable). TODO(Phase 1): once the graph
// module exists, add the blocked-by check here and return NOT_FOUND instead of the profile (ADR-0003:
// "no existence leak") — tracked, not implemented, because graph.Service doesn't exist in this
// bootstrap yet (see backend/internal/graph).
func (s *service) GetProfile(ctx context.Context, _ string, target ProfileTarget) (Profile, error) {
	uid := target.UserID
	if uid == "" {
		if target.Handle == "" {
			return Profile{}, apierr.Validation("target", "user_id or handle is required")
		}
	} else if userIDIssue(uid) {
		return Profile{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if uid == "" {
		lower := strings.ToLower(target.Handle)
		if cached, ok := s.cache.GetHandleUID(lower); ok {
			uid = cached
		} else {
			resolved, err := s.repo.ResolveHandle(ctx, lower)
			if err != nil {
				if errors.Is(err, ErrNotFound) {
					return Profile{}, notFoundErr()
				}
				return Profile{}, fmt.Errorf("identity: resolve handle %q: %w", target.Handle, err)
			}
			uid = resolved
		}
	}
	return s.getProfileCached(ctx, uid)
}

// UpdateProfile: reads 1, writes 1 in Phase 0 (avatar_media_id verification needs the media module,
// which doesn't exist yet — a non-empty value is rejected with ERROR_REASON_MEDIA_NOT_READY rather than
// silently accepted; documented Phase 0 limitation vs. the proto's "reads 2/1" once media lands).
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
	if params.AvatarMediaID != nil && *params.AvatarMediaID != "" {
		return Profile{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY, "avatar uploads are not available yet")
	}

	now := s.now().UTC()
	profile, err := s.repo.UpdateProfile(ctx, uid, func(p *Profile) {
		if params.DisplayName != nil {
			p.DisplayName = normalizeDisplayName(*params.DisplayName)
		}
		if params.Bio != nil {
			p.Bio = strings.TrimSpace(*params.Bio)
		}
		if params.AvatarMediaID != nil && *params.AvatarMediaID == "" {
			p.AvatarURL = ""
			p.AvatarThumbURL = ""
		}
		if params.IsPrivate != nil {
			p.IsPrivate = *params.IsPrivate
		}
		p.UpdatedAt = now
	})
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return Profile{}, notFoundErr()
		}
		return Profile{}, fmt.Errorf("identity: update profile %s: %w", uid, err)
	}
	s.cache.SetProfile(profile)
	// TODO(Phase 1): if DisplayName/AvatarURL changed, publish `profile-snapshot-refresh`; if IsPrivate
	// changed, publish the visibility job (ADR-0003). Both require the posts module to exist.
	return profile, nil
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
			return Profile{}, apierr.New(connect.CodeAlreadyExists, commonv1.ErrorReason_ERROR_REASON_HANDLE_TAKEN, "handle is taken")
		case errors.Is(err, ErrNotFound):
			return Profile{}, notFoundErr()
		default:
			return Profile{}, fmt.Errorf("identity: change handle %s: %w", uid, err)
		}
	}
	s.cache.SetProfile(profile)
	if oldHandleLower != "" {
		s.cache.InvalidateHandle(oldHandleLower)
	}
	// TODO(Phase 1): publish `profile-snapshot-refresh` (ADR-0003).
	return profile, nil
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
