package graph

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// errNotBuiltYet's message is deliberately generic (mirrors identity/server.go's errUnimplementedPhase1
// rationale): sent verbatim to the client, so it must never leak which ticket hasn't landed yet.
var errNotBuiltYet = errors.New("not implemented yet")

// unimplemented is the placeholder every GraphService RPC returns once past the flag guard, until its own
// ticket (T7-T10) replaces it. Never reached when FEATURE_GRAPH is off for the caller (checked first, 0
// reads either way).
func unimplemented() error {
	return connect.NewError(connect.CodeUnimplemented, errNotBuiltYet)
}

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

func (s *service) Block(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Unblock(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Mute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) Unmute(ctx context.Context, callerUID, idempotencyKey, targetUID string) (Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Relationship{}, err
	}
	return Relationship{}, unimplemented()
}

func (s *service) GetRelationships(ctx context.Context, callerUID string, targetUIDs []string) ([]Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return nil, err
	}
	return nil, unimplemented()
}

func (s *service) ListFollowers(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListFollowing(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListBlockedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}

func (s *service) ListMutedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	return Page{}, unimplemented()
}
