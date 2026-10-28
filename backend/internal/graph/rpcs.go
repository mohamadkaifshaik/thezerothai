package graph

import (
	"context"
	"errors"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func (s *service) checkFlag(callerUID string) error {
	if !s.flags.Enabled(callerUID, graphFlagName) {
		return flags.DisabledError()
	}
	return nil
}

// Follow (ADR-0008 T7, ADR-0025 D6). Validation order: flag -> idempotency key format -> target id format -> self ->
// repo transaction (target missing or not ACTIVE, blocked-by, blocks, already following, then the protected-target
// request path or the edge path; see repo_firestore.go's Follow doc comment for that precedence). The target's users doc
// is read inside the transaction, so only the caller's profile goes through identity.Directory (cache-first).
//
// Firestore: reads 4 cold / 3 warm (+1 on an overflowed caller): target users, caller graph and quotas in the
// transaction, plus the caller's profile (cold only; the account-status interceptor loads it on the request line).
// Writes: 5 for an edge (follows doc, caller graph, 2 counters, quota), 3 for a request to a protected target
// (followRequests Create, caller `requested`, quota), +1 delete when a leftover request to a now-public target is
// removed (AQ4); a replay (already following, or already requested) 0 writes. Planning value 4 (ADR-0008 A2).
// A request counts against the follows quota and returns FOLLOW_STATE_REQUESTED; FEATURE_PRIVATE_ACCOUNTS never gates it.
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

	profiles, err := s.directory.GetProfiles(ctx, []string{callerUID})
	if err != nil {
		return Relationship{}, s.internalErr("follow", err, callerUID, targetUID)
	}
	caller := profiles[callerUID]
	now := s.now()
	dailyLimit := s.followsLimit(s.isNewAccount(caller, now))
	// The D6 contention signal: the target's users doc is in every Follow's read set, so a hot target shows as
	// txn_attempts > 1 or UNAVAILABLE here. The hash identifies the target without naming it.
	logger.SetRequestField(ctx, fieldTargetHash, logger.HashUID(targetUID))

	rel, outcome, err := s.repo.Follow(ctx, callerUID, targetUID, dailyLimit, now)
	if err != nil {
		return Relationship{}, s.mapFollowErr(callerUID, targetUID, err)
	}
	setOutcome(ctx, outcome)
	requested := rel.FollowState == FollowStateRequested
	switch {
	case outcome == OutcomeReplay:
		logger.SetRequestField(ctx, fieldFollowOutcome, "replay")
	case requested:
		logger.SetRequestField(ctx, fieldFollowOutcome, "requested")
	default:
		logger.SetRequestField(ctx, fieldFollowOutcome, "edge")
	}
	// The caller now follows the target (or already did, on a replay): the target's cached "does the caller follow
	// me" answer on this instance is stale. The caller's own view of the opposite edge is untouched (ADR-0024 D7).
	s.cache.ForgetEdge(callerUID, targetUID)
	if outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
		if requested {
			// A request changes no counter and creates no edge: no directory Forget, no Followed, one FollowRequested.
			s.events.FollowRequested(ctx, callerUID, targetUID, now)
		} else {
			s.directory.Forget(callerUID, targetUID)
			s.events.Followed(ctx, callerUID, targetUID, now)
		}
		// ADR-0024 D8: the followed (or requested) user leaves this viewer's cached suggestions at once.
		s.dropSuggested(callerUID, targetUID)
	}
	return rel, nil
}

func (s *service) mapFollowErr(callerUID, targetUID string, err error) error {
	switch {
	case errors.Is(err, ErrNotFoundOrBlocked):
		return notFoundErr()
	case errors.Is(err, ErrCallerBlocksTarget):
		return targetBlockedErr()
	}
	var lim *LimitReachedError
	if errors.As(err, &lim) {
		return limitReachedErr(lim.Limit)
	}
	return s.internalErr("follow", err, callerUID, targetUID)
}

// Unfollow (ADR-0008 T7, ADR-0025 D7): two blind batches, idempotent. The edge batch runs first; on its failed
// precondition the withdraw batch deletes a pending follow request (WithdrawRequest). Both failing is NONE with 0
// writes (not following, nothing requested, or a replayed/racing Unfollow). Undo is never gated: withdrawing needs no
// FEATURE_PRIVATE_ACCOUNTS, only the module flag every graph RPC checks. Firestore: both batches read 0; an edge removal
// writes 3 and deletes 1, a withdraw writes 1 and deletes 1, a no-op 0; the request line logs 1 read (the caller's
// AccountStatusInterceptor profile read, cold after a Forget; ADR-0008 Amendment 2026-09-30 (2)).
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

	now := s.now()
	changed, err := s.repo.Unfollow(ctx, callerUID, targetUID, now)
	if err != nil {
		return Relationship{}, s.internalErr("unfollow", err, callerUID, targetUID)
	}
	withdrawn := false
	if !changed {
		withdrawn, err = s.repo.WithdrawRequest(ctx, callerUID, targetUID, now)
		if err != nil {
			return Relationship{}, s.internalErr("unfollow", err, callerUID, targetUID)
		}
		if withdrawn {
			logger.SetRequestField(ctx, fieldWithdraw, "request")
		} else {
			logger.SetRequestField(ctx, fieldWithdraw, "none")
		}
	}
	setChanged(ctx, changed || withdrawn)
	// The caller's edge to the target is gone (or never was, on a no-op): drop the target's cached answer for it.
	s.cache.ForgetEdge(callerUID, targetUID)
	if changed || withdrawn {
		s.cache.Invalidate(callerUID)
	}
	if changed {
		s.directory.Forget(callerUID, targetUID) // counters moved; a withdraw moves none
	}
	return Relationship{UserID: targetUID, FollowState: FollowStateNone}, nil
}

func (s *service) blockLimits() dailyLimits {
	return dailyLimits{Standard: s.blocksPerDay, NewAccount: s.newAccountBlocksPerDay, NewAccountWindow: s.newAccountWindow}
}

// Block (ADR-0008 T8, ADR-0025 D7). Firestore: reads 3/3, writes 5/3, deletes 2/0, plus at most 2 deletes for pending
// follow requests in either direction (so at most 4): +0 reads, +0 writes.
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
	logger.SetRequestField(ctx, fieldRequestsGone, result.RequestsGone)
	// A Block deletes both follow edges: drop the cached answer for each direction (ADR-0024 D7).
	s.cache.ForgetEdge(callerUID, targetUID)
	s.cache.ForgetEdge(targetUID, callerUID)
	if result.Outcome == OutcomeCreated {
		s.cache.Invalidate(callerUID)
		s.cache.Invalidate(targetUID)
		s.directory.Forget(callerUID, targetUID)
		// ADR-0024 D8: neither side may be suggested to the other from this instance's cache any more.
		s.dropSuggested(callerUID, targetUID)
		s.dropSuggested(targetUID, callerUID)
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
		s.dropSuggested(callerUID, targetUID) // ADR-0024 D8: a muted user is never suggested
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
