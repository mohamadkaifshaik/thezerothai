package graph

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
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
// Firestore: reads 4 cold / 2 warm (+1 on an overflowed caller), writes 5; replay reads 4 cold / 2 warm, writes 0
// (ADR-0008 A2; cold = caller and target profiles both miss the identity cache, which a preceding Follow's Forget makes the norm).
func (s *service) Follow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "follow")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return Relationship{}, selfActionErr("user_id")
	}

	profiles, err := s.directory.GetProfiles(ctx, []string{callerUID, targetUID})
	if err != nil {
		return Relationship{}, s.internalErr("follow", err, callerUID, targetUID)
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
	setOutcome(ctx, outcome)
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
	return s.internalErr("follow", err, callerUID, targetUID)
}

// Unfollow (ADR-0008 T7): a blind batch, idempotent. Not following (or a replayed/racing Unfollow) is
// NONE with 0 writes. Firestore: the batch reads 0, writes 3 (0 on no-op), deletes 1; the request line logs 1 read
// (the caller's AccountStatusInterceptor profile read, cold after a Forget; ADR-0008 Amendment 2026-09-30 (2)).
func (s *service) Unfollow(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "unfollow")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	changed, err := s.repo.Unfollow(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, s.internalErr("unfollow", err, callerUID, targetUID)
	}
	setChanged(ctx, changed)
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
func (s *service) Block(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "block")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
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
		return Relationship{}, s.internalErr("block", err, callerUID, targetUID)
	}
	setOutcome(ctx, result.Outcome)
	logger.SetRequestField(ctx, fieldEdgesGone, b2i(result.CallerWasFollowing)+b2i(result.TargetWasFollowing))
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
func (s *service) Unblock(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "unblock")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	rel, changed, err := s.repo.Unblock(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, s.internalErr("unblock", err, callerUID, targetUID)
	}
	setChanged(ctx, changed)
	if changed {
		s.cache.Invalidate(callerUID)
		s.cache.Invalidate(targetUID)
		s.directory.Forget(callerUID, targetUID)
	}
	return rel, nil
}

// Mute (ADR-0008 T8, A1). Firestore: reads 3 (caller graph, target graph existence, quotas), writes 2 (0 on replay);
// target without a graph doc => NOT_FOUND after 2 reads, 0 writes (same rule as Block; no blockedBy branching).
func (s *service) Mute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "mute")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return Relationship{}, selfActionErr("user_id")
	}

	rel, outcome, err := s.repo.Mute(ctx, callerUID, targetUID, s.blockLimits(), s.now())
	if err != nil {
		if errors.Is(err, ErrNotFoundOrBlocked) {
			return Relationship{}, notFoundErr()
		}
		var lim *LimitReachedError
		if errors.As(err, &lim) {
			return Relationship{}, limitReachedErr(lim.Limit)
		}
		return Relationship{}, s.internalErr("mute", err, callerUID, targetUID)
	}
	setOutcome(ctx, outcome)
	if outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
	}
	return rel, nil
}

// Unmute (ADR-0008 T8). Firestore: reads 1/1, writes 1/1 (0 on no-op).
func (s *service) Unmute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (_ Relationship, err error) {
	defer begin(ctx, "unmute")(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	if idempotencyKeyIssue(idempotencyKey) {
		return Relationship{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 chars of [A-Za-z0-9_-]")
	}
	if targetUserIDIssue(targetUID) {
		return Relationship{}, apierr.Validation("user_id", ids.UIDMessage)
	}
	if callerUID == targetUID {
		return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
	}

	rel, changed, err := s.repo.Unmute(ctx, callerUID, targetUID, s.now())
	if err != nil {
		return Relationship{}, s.internalErr("unmute", err, callerUID, targetUID)
	}
	setChanged(ctx, changed)
	if changed {
		s.cache.Invalidate(callerUID)
	}
	return rel, nil
}
