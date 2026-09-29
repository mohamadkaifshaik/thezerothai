package graph

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func (s *service) checkFlag(callerUID string) error {
	if !s.flags.Enabled(callerUID, graphFlagName) {
		return featureDisabledErr()
	}
	return nil
}

// Follow (ADR-0008 T7). Validation order: flag -> idempotency key format -> target id format -> self ->
// (via identity.Directory, cache-first) target missing/inactive -> repo transaction (blocked-by, blocks,
// private, replay, cap, quota — see repo_firestore.go's Follow doc comment for that precedence).
// Firestore: reads 4/2 (+1 on an overflowed caller), writes 5/5; replay reads 2/2, writes 0.
func (s *service) Follow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{}, selfActionErr("user_id")
	}

	profiles, err := s.directory.GetProfiles(ctx, []string{callerUID, targetUID})
	if err != nil {
		return Relationship{}, fmt.Errorf("graph: follow %s -> %s: %w", callerUID, targetUID, err)
	}
	target, ok := profiles[targetUID]
	if !ok {
		return Relationship{}, notFoundErr()
	}
	caller := profiles[callerUID]
	now := s.now()
	dailyLimit := s.followsLimit(s.isNewAccount(caller, now))

	rel, outcome, err := s.repo.Follow(ctx, callerUID, targetUID, target.IsPrivate, dailyLimit, now)
	if err != nil {
		return Relationship{}, s.mapFollowErr(callerUID, targetUID, err)
	}
	if outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
		s.directory.Forget(callerUID, targetUID)
		s.Followed(ctx, callerUID, targetUID, now)
	}
	return rel, nil
}

func (s *service) mapFollowErr(callerUID, targetUID string, err error) error {
	switch {
	case errors.Is(err, ErrNotFoundOrBlocked):
		return notFoundErr()
	case errors.Is(err, ErrCallerBlocksTarget):
		return targetBlockedErr()
	case errors.Is(err, ErrTargetPrivate):
		return featureDisabledErr()
	}
	var lim *LimitReachedError
	if errors.As(err, &lim) {
		return limitReachedErr(lim.Limit)
	}
	return fmt.Errorf("graph: follow %s -> %s: %w", callerUID, targetUID, err)
}

// Unfollow (ADR-0008 T7): a blind batch, idempotent. Not following (or a replayed/racing Unfollow) is
// NONE with 0 writes. Firestore: reads 0/0, writes 3/3 (0 on no-op), deletes 1/1.
func (s *service) Unfollow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	changed, err := s.repo.Unfollow(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, fmt.Errorf("graph: unfollow %s -> %s: %w", callerUID, targetUID, err)
	}
	if changed {
		s.cache.Invalidate(callerUID)
		s.directory.Forget(callerUID, targetUID)
	}
	return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
}

func (s *service) blockLimits() dailyLimits {
	return dailyLimits{Standard: s.blocksPerDay, NewAccount: s.newAccountBlocksPerDay, NewAccountWindow: s.newAccountWindow}
}

// Block (ADR-0008 T8). Firestore: reads 3/3, writes 5/3, deletes 2/0.
func (s *service) Block(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{}, selfActionErr("user_id")
	}

	result, err := s.repo.Block(ctx, callerUID, targetUID, s.blockLimits(), s.now())
	if err != nil {
		switch {
		case errors.Is(err, ErrNotFoundOrBlocked):
			return Relationship{}, notFoundErr()
		}
		var lim *LimitReachedError
		if errors.As(err, &lim) {
			return Relationship{}, limitReachedErr(lim.Limit)
		}
		return Relationship{}, fmt.Errorf("graph: block %s -> %s: %w", callerUID, targetUID, err)
	}
	if result.Outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
		s.cache.Invalidate(targetUID)
		s.directory.Forget(callerUID, targetUID)
		if result.BlockedByOverflowHit {
			// Logged here (post-commit), not inside the retryable transaction, so a transaction retry never
			// double-logs (ADR-0008 D2/handoff: "ERROR blockedby_cap_reached").
			slog.Default().Error("blockedby_cap_reached", "target_uid_hash", logger.HashUID(targetUID))
		}
	}
	return result.Relationship, nil
}

// Unblock (ADR-0008 T8). Firestore: reads 1/1, writes 2/2 (0 on no-op).
func (s *service) Unblock(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	rel, changed, err := s.repo.Unblock(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, fmt.Errorf("graph: unblock %s -> %s: %w", callerUID, targetUID, err)
	}
	if changed {
		s.cache.Invalidate(callerUID)
		s.cache.Invalidate(targetUID)
		s.directory.Forget(callerUID, targetUID)
	}
	return rel, nil
}

// Mute (ADR-0008 T8). Firestore: reads 2/2, writes 2/2 (0 on replay).
func (s *service) Mute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{}, selfActionErr("user_id")
	}

	rel, outcome, err := s.repo.Mute(ctx, callerUID, targetUID, s.blockLimits(), s.now())
	if err != nil {
		var lim *LimitReachedError
		if errors.As(err, &lim) {
			return Relationship{}, limitReachedErr(lim.Limit)
		}
		return Relationship{}, fmt.Errorf("graph: mute %s -> %s: %w", callerUID, targetUID, err)
	}
	if outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
	}
	return rel, nil
}

// Unmute (ADR-0008 T8). Firestore: reads 1/1, writes 1/1 (0 on no-op).
func (s *service) Unmute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-]")
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	rel, changed, err := s.repo.Unmute(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, fmt.Errorf("graph: unmute %s -> %s: %w", callerUID, targetUID, err)
	}
	if changed {
		s.cache.Invalidate(callerUID)
	}
	return rel, nil
}
