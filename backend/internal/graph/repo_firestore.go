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
	client *firestore.Client
	quota  *quota.Store
}

// NewFirestoreRepo builds a FirestoreRepo. Unchanged signature from the Phase 0 bootstrap so every existing
// call site (identity's GraphInitializer wiring) keeps compiling.
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client, quota: quota.New(client)}
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
