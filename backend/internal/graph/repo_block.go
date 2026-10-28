package graph

import (
	"context"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// blockLimits/muteLimits bundle the standard/new-account quota tier plus the window, so Block/Mute's
// signatures don't grow a 5th/6th plain int64 parameter each.
type dailyLimits struct {
	Standard         int64
	NewAccount       int64
	NewAccountWindow time.Duration
}

// BlockResult is Block's outcome, including whether the target's blockedBy overflowed at the cap (ADR-0008
// D2) — service.go logs that once, after a successful commit (never inside the retryable transaction).
type BlockResult struct {
	Relationship         Relationship
	Outcome              MutationOutcome
	CallerWasFollowing   bool // caller -> target edge existed and was removed
	TargetWasFollowing   bool // target -> caller edge existed and was removed
	BlockedByOverflowHit bool
	RequestsGone         int // pending follow requests deleted: caller -> target and target -> caller (ADR-0025 D7), 0 to 2
}

// Block runs the whole Block transaction (ADR-0008 T8/D2/D9). Reads: caller graph + target graph + quotas
// (3, always — the target graph doubles as the "unknown user" existence check, ADR-0008 D9). Writes on a
// real block: caller graph, target graph, quotas, plus up to 2 combined-per-doc counter updates (worst 5);
// deletes: up to 2 follows docs (mutual follow). Typical (no prior edges): 3 writes, 0 deletes. ADR-0025 D7: a pending
// follow request in either direction (target in the caller's `requested`, caller in the target's) is deleted too, with
// a plain Delete (no Exists: drift cannot fail a Block) and its array entry removed in the graph writes already made: +0
// reads, +0 writes, at most +2 deletes (so at most 4 deletes with a mutual follow).
func (r *FirestoreRepo) Block(ctx context.Context, callerUID, targetUID string, limits dailyLimits, now time.Time) (BlockResult, error) {
	var result BlockResult
	err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)

		callerDoc, callerCreatedAt, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}
		targetDoc, targetExists, err := r.getGraphTxExists(ctx, tx, targetUID)
		if err != nil {
			return err
		}
		if !targetExists {
			return ErrNotFoundOrBlocked
		}

		rec, err := r.quota.Get(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		if callerDoc.hasBlocked(targetUID) {
			result = BlockResult{
				Outcome:      OutcomeReplay,
				Relationship: Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Blocking: true, Muting: callerDoc.hasMuted(targetUID)},
			}
			return nil
		}
		if len(callerDoc.Blocked) >= maxBlocked {
			return &LimitReachedError{Limit: "blocked"}
		}

		dailyLimit := resolvedDailyLimit(callerCreatedAt, now, limits.NewAccountWindow, limits.Standard, limits.NewAccount)
		b := store.NewFirestoreTxBatch(tx, counter)
		if err := quota.CheckAndReserve(b, r.quota.Ref(callerUID), rec, quota.Blocks, dailyLimit); err != nil {
			return err
		}

		callerWasFollowing := callerDoc.hasFollowing(targetUID) // caller -> target edge
		targetWasFollowing := targetDoc.hasFollowing(callerUID) // target -> caller edge
		blockedByOverflow := len(targetDoc.BlockedBy) >= maxBlockedBy

		callerRequested := callerDoc.hasRequested(targetUID) // caller -> target request
		targetRequested := targetDoc.hasRequested(callerUID) // target -> caller request

		callerUpdates := []firestore.Update{
			{Path: "blocked", Value: firestore.ArrayUnion(targetUID)},
			{Path: "updatedAt", Value: now},
		}
		if callerWasFollowing {
			callerUpdates = append(callerUpdates, firestore.Update{Path: "following", Value: firestore.ArrayRemove(targetUID)})
		}
		if callerRequested {
			callerUpdates = append(callerUpdates, firestore.Update{Path: "requested", Value: firestore.ArrayRemove(targetUID)})
		}
		b.Update(r.graphRef(callerUID), callerUpdates)

		targetUpdates := []firestore.Update{{Path: "updatedAt", Value: now}}
		if blockedByOverflow {
			targetUpdates = append(targetUpdates, firestore.Update{Path: "blockedByOverflow", Value: true})
		} else {
			targetUpdates = append(targetUpdates, firestore.Update{Path: "blockedBy", Value: firestore.ArrayUnion(callerUID)})
		}
		if targetWasFollowing {
			targetUpdates = append(targetUpdates, firestore.Update{Path: "following", Value: firestore.ArrayRemove(callerUID)})
		}
		if targetRequested {
			targetUpdates = append(targetUpdates, firestore.Update{Path: "requested", Value: firestore.ArrayRemove(callerUID)})
		}
		b.Update(r.graphRef(targetUID), targetUpdates)

		if callerWasFollowing {
			ref, err := r.followRef(callerUID, targetUID)
			if err != nil {
				return err
			}
			b.Delete(ref, firestore.Exists)
		}
		if targetWasFollowing {
			ref, err := r.followRef(targetUID, callerUID)
			if err != nil {
				return err
			}
			b.Delete(ref, firestore.Exists)
		}
		requestsGone := 0
		if callerRequested {
			ref, err := r.requestRef(callerUID, targetUID)
			if err != nil {
				return err
			}
			b.Delete(ref)
			requestsGone++
		}
		if targetRequested {
			ref, err := r.requestRef(targetUID, callerUID)
			if err != nil {
				return err
			}
			b.Delete(ref)
			requestsGone++
		}

		// Counter decrements, combined per doc (ADR-0008 D3): at most one Update() per user doc.
		callerFollowingDelta, callerFollowersDelta := int64(0), int64(0)
		targetFollowingDelta, targetFollowersDelta := int64(0), int64(0)
		if callerWasFollowing {
			callerFollowingDelta--
			targetFollowersDelta--
		}
		if targetWasFollowing {
			targetFollowingDelta--
			callerFollowersDelta--
		}
		if callerFollowingDelta != 0 || callerFollowersDelta != 0 {
			r.counters.AddCounts(b, callerUID, callerFollowingDelta, callerFollowersDelta)
		}
		if targetFollowingDelta != 0 || targetFollowersDelta != 0 {
			r.counters.AddCounts(b, targetUID, targetFollowingDelta, targetFollowersDelta)
		}
		if b.Err() != nil {
			return b.Err()
		}

		result = BlockResult{
			Outcome:              OutcomeCreated,
			Relationship:         Relationship{UserID: targetUID, FollowState: FollowStateNone, Blocking: true, Muting: callerDoc.hasMuted(targetUID)},
			CallerWasFollowing:   callerWasFollowing,
			TargetWasFollowing:   targetWasFollowing,
			BlockedByOverflowHit: blockedByOverflow,
			RequestsGone:         requestsGone,
		}
		return nil
	})
	if err != nil {
		return BlockResult{}, err
	}
	return result, nil
}

// Unblock (ADR-0008 T8/D9): fresh read of the caller graph; not blocking => 0 writes. Never quota-gated.
// Does not restore follows (so FollowState is always NONE on success — a block always removed any prior
// edge in both directions, and Unblock never restores it). Reads 1, writes 2 (0 on no-op).
func (r *FirestoreRepo) Unblock(ctx context.Context, callerUID, targetUID string, now time.Time) (Relationship, bool, error) {
	var rel Relationship
	changed := false
	err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		callerDoc, _, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}
		if !callerDoc.hasBlocked(targetUID) {
			rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Muting: callerDoc.hasMuted(targetUID)}
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.graphRef(callerUID), []firestore.Update{
			{Path: "blocked", Value: firestore.ArrayRemove(targetUID)},
			{Path: "updatedAt", Value: now},
		})
		b.Update(r.graphRef(targetUID), []firestore.Update{
			{Path: "blockedBy", Value: firestore.ArrayRemove(callerUID)},
		})
		if b.Err() != nil {
			return b.Err()
		}
		changed = true
		rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Muting: callerDoc.hasMuted(targetUID)}
		return nil
	})
	if err != nil {
		return Relationship{}, false, err
	}
	return rel, changed, nil
}

// Mute (ADR-0008 T8/D9, A1): transaction reads caller graph, then target graph (existence only), then quotas;
// writes caller graph (muted +=) + quota reservation. Same rule and order as Block: a target with no
// graph/{target} doc => ErrNotFoundOrBlocked (NOT_FOUND) before the quota read, 0 writes. The target doc's
// CONTENT is never inspected (in particular not blockedBy), so muting someone who blocked you is OK and
// indistinguishable from muting a stranger (D9; no oracle, no timing difference). Cap 2,000 muted =>
// LIMIT_REACHED. Replay (already muting) => 0 writes. Reads 3 (2 on NOT_FOUND), writes 2 (0 on replay).
func (r *FirestoreRepo) Mute(ctx context.Context, callerUID, targetUID string, limits dailyLimits, now time.Time) (Relationship, MutationOutcome, error) {
	var rel Relationship
	outcome := OutcomeCreated
	err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		callerDoc, createdAt, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}
		_, targetExists, err := r.getGraphTxExists(ctx, tx, targetUID)
		if err != nil {
			return err
		}
		if !targetExists {
			return ErrNotFoundOrBlocked
		}
		rec, err := r.quota.Get(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		if callerDoc.hasMuted(targetUID) {
			outcome = OutcomeReplay
			rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Blocking: callerDoc.hasBlocked(targetUID), Muting: true}
			return nil
		}
		if len(callerDoc.Muted) >= maxMuted {
			return &LimitReachedError{Limit: "muted"}
		}

		dailyLimit := resolvedDailyLimit(createdAt, now, limits.NewAccountWindow, limits.Standard, limits.NewAccount)
		b := store.NewFirestoreTxBatch(tx, counter)
		if err := quota.CheckAndReserve(b, r.quota.Ref(callerUID), rec, quota.Blocks, dailyLimit); err != nil {
			return err
		}
		b.Update(r.graphRef(callerUID), []firestore.Update{
			{Path: "muted", Value: firestore.ArrayUnion(targetUID)},
			{Path: "updatedAt", Value: now},
		})
		if b.Err() != nil {
			return b.Err()
		}

		outcome = OutcomeCreated
		rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Blocking: callerDoc.hasBlocked(targetUID), Muting: true}
		return nil
	})
	if err != nil {
		return Relationship{}, "", err
	}
	return rel, outcome, nil
}

// Unmute (ADR-0008 T8/D9): fresh read of the caller graph; not muting => 0 writes. Never quota-gated.
// Reads 1, writes 1 (0 on no-op).
func (r *FirestoreRepo) Unmute(ctx context.Context, callerUID, targetUID string, now time.Time) (Relationship, bool, error) {
	var rel Relationship
	changed := false
	err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		callerDoc, _, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}
		if !callerDoc.hasMuted(targetUID) {
			rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Blocking: callerDoc.hasBlocked(targetUID)}
			return nil
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.graphRef(callerUID), []firestore.Update{
			{Path: "muted", Value: firestore.ArrayRemove(targetUID)},
			{Path: "updatedAt", Value: now},
		})
		if b.Err() != nil {
			return b.Err()
		}
		changed = true
		rel = Relationship{UserID: targetUID, FollowState: followStateOf(callerDoc, targetUID), Blocking: callerDoc.hasBlocked(targetUID)}
		return nil
	})
	if err != nil {
		return Relationship{}, false, err
	}
	return rel, changed, nil
}
