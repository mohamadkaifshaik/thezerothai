package lists

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func memberHash(listID, userID string) string {
	return idempotency.HashRequest(fmt.Sprintf("list_id=%s|user_id=%s", listID, userID))
}

func validateUserID(id string) error {
	if !ids.ValidUID(id) {
		return apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9-]")
	}
	return nil
}

// social is the owner's graph snapshot, cache-first (60 s staleness bound, ADR-0008 D8). A missing Graph is a wiring bug and
// fails closed rather than skipping the block checks.
func (s *service) social(ctx context.Context, uid string) (graph.Snapshot, error) {
	if s.d.Graph == nil {
		return graph.Snapshot{}, errors.New("lists: graph reader is not wired")
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return graph.Snapshot{}, fmt.Errorf("lists: load graph: %w", err)
	}
	return snap, nil
}

// targetVerdict decides whether uid may add target, from cache-first reads only (ADR-0030 D4). nil = allowed; ErrNotFound = the
// target is missing, not ACTIVE, blocks the owner or is blocked by the owner (one answer for every cause: no block oracle);
// ErrProtected = a protected account the owner does not follow. Adding yourself is always allowed. When the owner\'s blockedBy
// overflowed it cannot be trusted alone, so the target\'s own graph is consulted too (fail closed, as Follow).
func (s *service) targetVerdict(ctx context.Context, uid, target string, owner graph.Snapshot, tp identity.Profile, found bool) (refusal error, err error) {
	if target == uid {
		return nil, nil
	}
	if !found || tp.Status != identity.AccountStatusActive {
		return ErrNotFound, nil
	}
	if owner.Blocked[target] || owner.BlockedBy[target] {
		return ErrNotFound, nil
	}
	if owner.BlockedByOverflow {
		ts, err := s.social(ctx, target)
		if err != nil {
			return nil, err
		}
		if ts.Blocked[uid] {
			return ErrNotFound, nil
		}
	}
	if tp.IsPrivate && !owner.Following[target] {
		return ErrProtected, nil
	}
	return nil, nil
}

// AddMember implements Service (ADR-0030 D4, D7). Validation first (0 reads), then the owner\'s and the target\'s profiles
// (one cache-first call) and the owner\'s graph, then one repository transaction that applies the verdict after the idempotency
// lookup. The instance cache is filled from the written list.
func (s *service) AddMember(ctx context.Context, uid, key, listID, userID string) (View, error) {
	begin(ctx, "add")
	if err := validateKey(key); err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	if err := validateListID(listID); err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	if err := validateUserID(userID); err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	want := []string{uid}
	if userID != uid {
		want = append(want, userID)
	}
	profs, err := s.d.Directory.GetProfiles(ctx, want)
	if err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, fmt.Errorf("lists: load profiles: %w", err))
	}
	prof, ok := profs[uid]
	if !ok {
		return View{}, mapErr(ctx, "add", uid, listID, errNoProfile())
	}
	owner, err := s.social(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	tp, found := profs[userID]
	refusal, err := s.targetVerdict(ctx, uid, userID, owner, tp, found)
	if err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	limit := s.d.Limits.AddsPerDay
	if s.isNew(prof) {
		limit = s.d.Limits.NewAccountAddsPerDay
	}
	res, err := s.d.Repo.AddMember(ctx, AddMemberParams{
		UID: uid, ListID: listID, TargetID: userID, IdemKey: idempotency.Key(uid, rpcAddListMember, key),
		RequestHash: memberHash(listID, userID), Refusal: refusal,
		MaxMembers: s.d.Limits.MaxMembers, QuotaLimit: limit, BlockedBy: owner.BlockedBy,
	})
	if err != nil {
		return View{}, mapErr(ctx, "add", uid, listID, err)
	}
	s.afterMemberWrite(ctx, res)
	return View{Header: res.Header, Owner: prof}, nil
}

// RemoveMember implements Service. The owner\'s graph is loaded (cache-first) only when a member is actually removed, so a
// replay or a remove of a non-member never reads it; a failed load skips the lazy drop and never fails the removal.
func (s *service) RemoveMember(ctx context.Context, uid, key, listID, userID string) (View, error) {
	begin(ctx, "remove")
	if err := validateKey(key); err != nil {
		return View{}, mapErr(ctx, "remove", uid, listID, err)
	}
	if err := validateListID(listID); err != nil {
		return View{}, mapErr(ctx, "remove", uid, listID, err)
	}
	if err := validateUserID(userID); err != nil {
		return View{}, mapErr(ctx, "remove", uid, listID, err)
	}
	res, err := s.d.Repo.RemoveMember(ctx, RemoveMemberParams{
		UID: uid, ListID: listID, TargetID: userID, IdemKey: idempotency.Key(uid, rpcRemoveListMember, key),
		RequestHash: memberHash(listID, userID),
		BlockedBy: func(ctx context.Context) map[string]bool {
			snap, err := s.social(ctx, uid)
			if err != nil {
				slog.WarnContext(ctx, "lists_lazy_drop_skipped", "uid_hash", logger.HashUID(uid), "err", logger.RedactErr(err, uid, listID))
				return nil
			}
			return snap.BlockedBy
		},
	})
	if err != nil {
		return View{}, mapErr(ctx, "remove", uid, listID, err)
	}
	s.afterMemberWrite(ctx, res)
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return View{}, mapErr(ctx, "remove", uid, listID, err)
	}
	return View{Header: res.Header, Owner: prof}, nil
}

// afterMemberWrite notes the outcome and updates the instance cache from the data the transaction wrote (never a re-read). A
// replay leaves the cache alone (the list may have changed since); a private list is evicted, as UpdateList does.
func (s *service) afterMemberWrite(ctx context.Context, res MemberResult) {
	noteOutcome(ctx, res.Outcome)
	if res.Dropped > 0 {
		logger.SetRequestField(ctx, "dropped", res.Dropped)
	}
	if res.List == nil || res.Outcome == Replayed {
		return
	}
	if res.List.IsPrivate {
		s.cache.evict(res.List.ID)
	} else {
		s.cache.put(*res.List)
	}
}
