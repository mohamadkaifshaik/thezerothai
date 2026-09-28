// repo_firestore.go is the Firestore implementation of Repo (ADR-0003: graph/{uid}, follows/{a}_{b};
// ADR-0008 D2: blockedBy/blockedByOverflow). InitGraph is the one seam identity depends on
// (identity.GraphInitializer) to create the empty graph/{uid} doc inside CreateProfile's transaction; the
// rest of this file backs the full GraphService (ADR-0008).
package graph

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
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

func (r *FirestoreRepo) followRef(followerUID, followeeUID string) *firestore.DocumentRef {
	return r.client.Collection(followsCollection).Doc(followerUID + "_" + followeeUID)
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
// transaction").
func (r *FirestoreRepo) getGraphTx(ctx context.Context, tx *firestore.Transaction, uid string) (doc, error) {
	snap, err := tx.Get(r.graphRef(uid))
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
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)

		callerDoc, err := r.getGraphTx(ctx, tx, callerUID)
		if err != nil {
			return err
		}

		blockedByTarget := callerDoc.hasBlockedBy(targetUID)
		if !blockedByTarget && callerDoc.BlockedByOverflow {
			targetDoc, err := r.getGraphTx(ctx, tx, targetUID)
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
		b.Create(r.followRef(callerUID, targetUID), followDoc{FollowerID: callerUID, FolloweeID: targetUID, CreatedAt: now})
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
func (r *FirestoreRepo) Unfollow(ctx context.Context, callerUID, targetUID string, now time.Time) (bool, error) {
	counter := budget.FromContext(ctx)
	b := store.NewFirestoreBatch(r.client, counter)
	b.Delete(r.followRef(callerUID, targetUID), firestore.Exists)
	b.Update(r.graphRef(callerUID), []firestore.Update{
		{Path: "following", Value: firestore.ArrayRemove(targetUID)},
		{Path: "updatedAt", Value: now},
	})
	r.counters.AddFollowingCount(b, callerUID, -1)
	r.counters.AddFollowersCount(b, targetUID, -1)

	if err := b.Commit(ctx); err != nil {
		if isPreconditionFailed(err) {
			return false, nil
		}
		return false, fmt.Errorf("graph: unfollow %s -> %s: %w", callerUID, targetUID, err)
	}
	return true, nil
}

// isPreconditionFailed reports whether err is the Firestore error for a failed batch precondition (e.g.
// Exists on a doc that doesn't exist) — Firestore surfaces this as NotFound or FailedPrecondition depending
// on the SDK/emulator version, so both are treated as "the precondition wasn't met" (ADR-0008 T7/D10: a
// no-op, not a real error).
func isPreconditionFailed(err error) bool {
	code := status.Code(err)
	return code == codes.NotFound || code == codes.FailedPrecondition
}
