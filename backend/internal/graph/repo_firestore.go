// repo_firestore.go is the Firestore implementation of Repo (ADR-0003: graph/{uid}, follows/{a}_{b};
// ADR-0008 D2: blockedBy/blockedByOverflow). InitGraph is the one seam identity depends on
// (identity.GraphInitializer) to create the empty graph/{uid} doc inside CreateProfile's transaction; the
// rest of this file backs the full GraphService (ADR-0008).
package graph

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Unfollow's bounded retry on a lost lock race (D1).
const (
	unfollowMaxAttempts  = 6
	unfollowRetryBackoff = 25 * time.Millisecond // ceiling doubled per retry: 25..400 ms; full jitter picks [0, ceiling)
)

const (
	graphCollection   = "graph"
	followsCollection = "follows"
)

// Caps from ADR-0008 D2 (document-size budget: following 5,000 + blocked 2,000 + muted 2,000 + requested
// 500 + blockedBy 10,000 ~= 566 KB, safely under Firestore's 1 MiB doc limit).
const (
	maxFollowing = 5_000
	maxBlocked   = 2_000
	maxMuted     = 2_000
	maxBlockedBy = 10_000
)

// doc is the graph/{uid} shape (ADR-0003, ADR-0008 D2). Arrays are exempt from indexing.
// blockedByOverflow stays indexed (a tiny bool; it lets moderation query overflowed accounts, ADR-0008 D5).
type doc struct {
	Following         []string  `firestore:"following"`
	Blocked           []string  `firestore:"blocked"`
	Muted             []string  `firestore:"muted"`
	Requested         []string  `firestore:"requested"`
	BlockedBy         []string  `firestore:"blockedBy"`
	BlockedByOverflow bool      `firestore:"blockedByOverflow"`
	UpdatedAt         time.Time `firestore:"updatedAt"`
}

func toSet(vals []string) map[string]bool {
	if len(vals) == 0 {
		return map[string]bool{}
	}
	m := make(map[string]bool, len(vals))
	for _, v := range vals {
		m[v] = true
	}
	return m
}

func (d doc) toSnapshot() Snapshot {
	return Snapshot{
		Following:         toSet(d.Following),
		Blocked:           toSet(d.Blocked),
		Muted:             toSet(d.Muted),
		Requested:         toSet(d.Requested),
		BlockedBy:         toSet(d.BlockedBy),
		BlockedByOverflow: d.BlockedByOverflow,
	}
}

func (d doc) hasFollowing(uid string) bool { return containsStr(d.Following, uid) }
func (d doc) hasBlocked(uid string) bool   { return containsStr(d.Blocked, uid) }
func (d doc) hasMuted(uid string) bool     { return containsStr(d.Muted, uid) }
func (d doc) hasBlockedBy(uid string) bool { return containsStr(d.BlockedBy, uid) }

func containsStr(vals []string, target string) bool {
	for _, v := range vals {
		if v == target {
			return true
		}
	}
	return false
}

// followDoc is the follows/{followerId}_{followeeId} shape (ADR-0003), used only for list pages.
type followDoc struct {
	FollowerID string    `firestore:"followerId"`
	FolloweeID string    `firestore:"followeeId"`
	CreatedAt  time.Time `firestore:"createdAt"`
}

// FirestoreRepo implements Repo (and identity.GraphInitializer) against the shared Firestore client.
type FirestoreRepo struct {
	client   *firestore.Client
	quota    *quota.Store
	counters identity.Counters
	profiles ProfileReader

	// Test seams for Unfollow's retry loop; nil means production behaviour (real commit, jittered timer).
	commitBatch func(ctx context.Context, b *store.FirestoreBatch) error
	backoff     func(ctx context.Context, ceiling time.Duration) error // see store.RetryConfig
}

// NewFirestoreRepo builds a FirestoreRepo. Unchanged signature from the Phase 0 bootstrap so every existing
// call site (identity's GraphInitializer wiring, and every InitGraph-only test) keeps compiling. Call
// SetCounters once identity.Counters is available (required before any Follow/Unfollow/Block/Mute call).
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client, quota: quota.New(client)}
}

// SetCounters wires identity.Counters (users/{uid} followers/following count increments). The counter
// writes must land in the exact same transaction/batch as the edge change (ADR-0008 D3), which is why this
// lives on the repo rather than being called by service.go with its own separate batch.
func (r *FirestoreRepo) SetCounters(c identity.Counters) {
	r.counters = c
}

func (r *FirestoreRepo) graphRef(uid string) *firestore.DocumentRef {
	return r.client.Collection(graphCollection).Doc(uid)
}

// edgeID is the ONLY place a follows doc id is built: `{followerId}_{followeeId}`. It refuses a uid containing
// the `_` separator, which would make `a_b_c` ambiguous between a_b -> c and a -> b_c (ADR-0008 A3). Uid
// validation (authn caller check, ids.ValidUID on targets) rejects `_` long before this, so an error here
// means a validation bug and surfaces as INTERNAL.
func edgeID(followerUID, followeeUID string) (string, error) {
	if strings.Contains(followerUID, "_") || strings.Contains(followeeUID, "_") {
		return "", errors.New("graph: uid contains reserved '_' (edge id would be ambiguous)")
	}
	return followerUID + "_" + followeeUID, nil
}

func (r *FirestoreRepo) followRef(followerUID, followeeUID string) (*firestore.DocumentRef, error) {
	id, err := edgeID(followerUID, followeeUID)
	if err != nil {
		return nil, err
	}
	return r.client.Collection(followsCollection).Doc(id), nil
}

// InitGraph appends a Create() of an empty graph/{uid} doc to b. Idempotent: if the doc already exists, the
// Create() fails the whole atomic write — an existing graph doc must never be silently reset.
func (r *FirestoreRepo) InitGraph(b store.Batch, uid string, now time.Time) {
	b.Create(r.graphRef(uid), doc{
		Following: []string{},
		Blocked:   []string{},
		Muted:     []string{},
		Requested: []string{},
		BlockedBy: []string{},
		UpdatedAt: now,
	})
}

// getGraph reads graph/{uid} outside a transaction (used by GetSnapshot on a cache miss, and by Reader
// callers who accept the 60s staleness budget, ADR-0008 D8). A missing doc decodes as an empty Snapshot,
// not an error — defensive: every ACTIVE profile has one from CreateProfile, but a missing doc must never
// crash a request.
func (r *FirestoreRepo) getGraph(ctx context.Context, uid string) (doc, error) {
	snap, err := r.graphRef(uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, nil
		}
		return doc{}, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, nil
}

// getGraphTx is getGraph's transactional counterpart (ADR-0008 D8: "mutations read fresh inside their
// transaction"). It also returns the doc's Firestore CreateTime (zero if the doc doesn't exist): since
// InitGraph creates graph/{uid} atomically with users/{uid} in CreateProfile's own transaction, this is a
// free (already-fetched) proxy for account age — Block and Mute use it to pick the new-account quota tier
// without needing a separate identity.Directory read (unlike Follow, whose documented budget already
// includes a Directory lookup for the target's isPrivate flag).
func (r *FirestoreRepo) getGraphTx(ctx context.Context, tx *firestore.Transaction, uid string) (doc, time.Time, error) {
	snap, err := tx.Get(r.graphRef(uid))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, time.Time{}, nil
		}
		return doc{}, time.Time{}, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, time.Time{}, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, snap.CreateTime, nil
}

// getGraphTxExists is getGraphTx plus an explicit existence flag, used where "the graph doc doesn't exist"
// itself means "unknown user" (Block/Mute, which — unlike Follow — don't otherwise consult
// identity.Directory, so this is their only existence signal; ADR-0008 D9's "unknown user => NOT_FOUND" for
// Block costs 0 extra reads this way).
func (r *FirestoreRepo) getGraphTxExists(ctx context.Context, tx *firestore.Transaction, uid string) (doc, bool, error) {
	snap, err := tx.Get(r.graphRef(uid))
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return doc{}, false, nil
		}
		return doc{}, false, fmt.Errorf("graph: get %s: %w", uid, err)
	}
	var d doc
	if err := snap.DataTo(&d); err != nil {
		return doc{}, false, fmt.Errorf("graph: decode %s: %w", uid, err)
	}
	return d, true, nil
}

// resolvedDailyLimit picks the new-account or standard daily limit from a graph doc's creation time
// (Block/Mute; see getGraphTx's doc comment). A zero createdAt (defensive: a missing doc) is never treated
// as a new account.
func resolvedDailyLimit(createdAt, now time.Time, window time.Duration, standard, newAccountLimit int64) int64 {
	if createdAt.IsZero() || now.Sub(createdAt) >= window {
		return standard
	}
	return newAccountLimit
}

func followStateOf(d doc, uid string) FollowState {
	if d.hasFollowing(uid) {
		return FollowStateFollowing
	}
	return FollowStateNone
}

// GetSnapshot implements Repo for Reader.Snapshot's cache-miss path: 1 read.
func (r *FirestoreRepo) GetSnapshot(ctx context.Context, uid string) (Snapshot, error) {
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Snapshot{}, err
	}
	return d.toSnapshot(), nil
}

// Follow runs the whole Follow transaction (ADR-0008 T7/D2/D9). Precedence, matching the proto/ADR order:
// blocked-by (incl. the D2 overflow fallback) -> caller-blocks-target -> target-private -> replay ->
// following-cap -> quota. Reads: caller graph + quotas always (2), +1 target graph only for an overflowed
// caller. Writes on success: follows doc, caller graph update, 2 counter increments, quota reservation (5);
// 0 on replay.
func (r *FirestoreRepo) Follow(ctx context.Context, callerUID, targetUID string, targetIsPrivate bool, dailyLimit int64, now time.Time) (Relationship, MutationOutcome, error) {
	var rel Relationship
	outcome := OutcomeCreated
	err := r.runTx(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)

		callerDoc, _, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		blockedByTarget := callerDoc.hasBlockedBy(targetUID)
		if !blockedByTarget && callerDoc.BlockedByOverflow {
			targetDoc, _, err := r.getGraphTx(ctx, tx, targetUID)
			if err != nil {
				return err
			}
			blockedByTarget = targetDoc.hasBlocked(callerUID)
		}
		if blockedByTarget {
			return ErrNotFoundOrBlocked
		}
		if callerDoc.hasBlocked(targetUID) {
			return ErrCallerBlocksTarget
		}

		rec, err := r.quota.Get(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		if targetIsPrivate {
			return ErrTargetPrivate
		}

		if callerDoc.hasFollowing(targetUID) {
			outcome = OutcomeReplay
			rel = Relationship{UserID: targetUID, FollowState: FollowStateFollowing, Muting: callerDoc.hasMuted(targetUID)}
			return nil
		}
		if len(callerDoc.Following) >= maxFollowing {
			return &LimitReachedError{Limit: "following"}
		}

		b := store.NewFirestoreTxBatch(tx, counter)
		if err := quota.CheckAndReserve(b, r.quota.Ref(callerUID), rec, quota.Follows, dailyLimit); err != nil {
			return err
		}
		edgeRef, err := r.followRef(callerUID, targetUID)
		if err != nil {
			return err
		}
		b.Create(edgeRef, followDoc{FollowerID: callerUID, FolloweeID: targetUID, CreatedAt: now})
		b.Update(r.graphRef(callerUID), []firestore.Update{
			{Path: "following", Value: firestore.ArrayUnion(targetUID)},
			{Path: "updatedAt", Value: now},
		})
		r.counters.AddFollowingCount(b, callerUID, 1)
		r.counters.AddFollowersCount(b, targetUID, 1)
		if b.Err() != nil {
			return b.Err()
		}

		outcome = OutcomeCreated
		rel = Relationship{UserID: targetUID, FollowState: FollowStateFollowing, Muting: callerDoc.hasMuted(targetUID)}
		return nil
	})
	if err != nil {
		return Relationship{}, "", err
	}
	return rel, outcome, nil
}

// Unfollow is a blind batch (ADR-0008 T7/D3): delete the follows doc with an Exists precondition, so a
// replay (already unfollowed, or never followed) fails the whole batch atomically and costs 0 writes — the
// precondition also makes this safe to race against Block, which deletes the same edge with the same
// precondition (ADR-0008 D3 invariant #1: "follows/{a}_{b} exists <=> b in graph/{a}.following").
//
// ADR-0009 invariant: for an ACTIVE caller, the edge exists <=> the target is in the caller's following
// <=> both users docs exist. So a failed precondition means there is nothing to undo, and Unfollow returns
// (false, nil) without revealing why (never followed, already unfollowed, or target gone).
func (r *FirestoreRepo) Unfollow(ctx context.Context, callerUID, targetUID string, now time.Time) (bool, error) {
	// D1: unlike RunTransaction, a bare batch commit is not retried by the SDK when it loses a lock race with a
	// Follow/Block transaction on the same docs (Aborted). Retry a bounded number of times with a short
	// backoff; the budget is unchanged (0R/3W/1D) because a failed attempt writes nothing and each attempt
	// counts into its own scratch counter that is only folded into the request counter on success.
	edgeRef, err := r.followRef(callerUID, targetUID)
	if err != nil {
		return false, err
	}
	res, err := store.CommitWithRetry(ctx,
		func(c *budget.Counter) *store.FirestoreBatch { return store.NewFirestoreBatch(r.client, c) },
		store.RetryConfig{MaxAttempts: unfollowMaxAttempts, Backoff: unfollowRetryBackoff, Commit: r.commitBatch, Sleep: r.backoff},
		func(b store.Batch) {
			b.Delete(edgeRef, firestore.Exists)
			b.Update(r.graphRef(callerUID), []firestore.Update{
				{Path: "following", Value: firestore.ArrayRemove(targetUID)},
				{Path: "updatedAt", Value: now},
			})
			r.counters.AddFollowingCount(b, callerUID, -1)
			r.counters.AddFollowersCount(b, targetUID, -1)
		})
	noteTxnAttempts(ctx, res.Attempts)
	switch {
	case errors.Is(err, store.ErrContended):
		return false, fmt.Errorf("%w: %v", ErrContention, err)
	case err != nil:
		return false, fmt.Errorf("graph: unfollow: %w", err)
	}
	// !Committed with nil error: a failed Exists precondition is a no-op that performs (and bills) no writes.
	// ADR-0009: for an ACTIVE caller, edge <=> following entry <=> both users docs exist, so this is a
	// correct no-op; (false, nil) deliberately does not reveal which case it was.
	return res.Committed, nil
}

// runTx is client.RunTransaction plus the ADR-0008 D3 contention signal: it counts how many times the
// callback ran (the SDK retries Aborted transactions internally) and records txn_attempts on the request
// log line. More than txnWarnAttempts attempts also emits one WARN, the measurement that decides the
// sharded-counter ADR. A callback re-run costs reads again, but budget.Counter is unchanged by this wrapper.
func (r *FirestoreRepo) runTx(ctx context.Context, fn func(context.Context, *firestore.Transaction) error) error {
	attempts := 0
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		attempts++
		return fn(ctx, tx)
	})
	noteTxnAttempts(ctx, attempts)
	return err
}

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
}

// Block runs the whole Block transaction (ADR-0008 T8/D2/D9). Reads: caller graph + target graph + quotas
// (3, always — the target graph doubles as the "unknown user" existence check, ADR-0008 D9). Writes on a
// real block: caller graph, target graph, quotas, plus up to 2 combined-per-doc counter updates (worst 5);
// deletes: up to 2 follows docs (mutual follow). Typical (no prior edges): 3 writes, 0 deletes.
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

		callerUpdates := []firestore.Update{
			{Path: "blocked", Value: firestore.ArrayUnion(targetUID)},
			{Path: "updatedAt", Value: now},
		}
		if callerWasFollowing {
			callerUpdates = append(callerUpdates, firestore.Update{Path: "following", Value: firestore.ArrayRemove(targetUID)})
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

// Lists is one read of graph/{uid} for the own-list RPCs: the ordered arrays plus the Snapshot of the same doc.
type Lists struct {
	Snapshot Snapshot
	// Blocked and Muted are in insertion order (ArrayUnion appends), oldest first.
	Blocked []string
	Muted   []string
}

// GetLists implements Repo: 1 read.
func (r *FirestoreRepo) GetLists(ctx context.Context, uid string) (Lists, error) {
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Lists{}, err
	}
	return Lists{Snapshot: d.toSnapshot(), Blocked: d.Blocked, Muted: d.Muted}, nil
}

// Edge is one follows/{followerId}_{followeeId} document.
type Edge struct {
	DocID      string
	FollowerID string
	FolloweeID string
	CreatedAt  time.Time
}

// otherUID is the counterpart of the listed user: the follower when listing followers, else the followee.
func (e Edge) otherUID(followers bool) string {
	if followers {
		return e.FollowerID
	}
	return e.FolloweeID
}

// EdgeQuery selects one page of follow edges. Limit must already be clamped by the caller.
type EdgeQuery struct {
	UID       string
	Followers bool // true: edges where followeeId == UID; false: where followerId == UID
	Limit     int
	After     *cursor.Cursor // nil = first page
}

// ListEdges implements Repo: `follows where <field> == uid order by createdAt desc, __name__ desc limit N`
// (existing composite indexes). Reads: len(result), minimum 1 (Firestore bills an empty query as one read).
func (r *FirestoreRepo) ListEdges(ctx context.Context, q EdgeQuery) ([]Edge, error) {
	field := "followerId"
	if q.Followers {
		field = "followeeId"
	}
	query := r.client.Collection(followsCollection).
		Where(field, "==", q.UID).
		OrderBy("createdAt", firestore.Desc).
		OrderBy(firestore.DocumentID, firestore.Desc).
		Limit(q.Limit)
	if q.After != nil {
		query = query.StartAfter(q.After.CreatedAt, r.client.Collection(followsCollection).Doc(q.After.DocID))
	}
	docs, err := query.Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("graph: list edges %s: %w", q.UID, err)
	}
	out := make([]Edge, 0, len(docs))
	for _, d := range docs {
		var f followDoc
		if err := d.DataTo(&f); err != nil {
			return nil, fmt.Errorf("graph: decode follow %s: %w", d.Ref.ID, err)
		}
		out = append(out, Edge{DocID: d.Ref.ID, FollowerID: f.FollowerID, FolloweeID: f.FolloweeID, CreatedAt: f.CreatedAt})
	}
	return out, nil
}
