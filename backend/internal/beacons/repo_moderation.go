package beacons

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Moderator is the operator-side seam of the platform hide: `opsctl beacon hide|restore` is its only caller, there is
// no moderator RPC at v1. *FirestoreRepo implements it, so the beacons module stays the only writer of beacons/{beaconId}.
type Moderator interface {
	// SetHidden sets or clears the platform `hidden` flag of one beacon. changed is false when the beacon already was in
	// that state (nothing written). ErrNotFound for a missing beacon.
	SetHidden(ctx context.Context, beaconID string, hidden bool, now time.Time) (changed bool, err error)
	// Get reads the beacon outside a transaction, for `--dry-run`.
	Get(ctx context.Context, id string) (Beacon, error)
}

var _ Moderator = (*FirestoreRepo)(nil)

// SetHidden implements Moderator: one transaction that reads the beacon (ErrNotFound when it is gone) and, only when
// the flag differs, writes `hidden` and `updatedAt` through a field-level Update. It is never a Set, so a beacon deleted
// between the read and the commit stays deleted, and no other field (seats, status, text) can be touched or reverted.
// Restore removes the field (`firestore.Delete`), so storage keeps its "absent means false" shape. Idempotent: a repeat
// writes nothing. A hidden beacon is NOT_FOUND to everyone but its organiser on every read (R18: invisible, not frozen).
func (r *FirestoreRepo) SetHidden(ctx context.Context, beaconID string, hidden bool, now time.Time) (bool, error) {
	if r == nil || r.client == nil {
		return false, fmt.Errorf("beacons: repo is not wired")
	}
	changed := false
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		changed = false
		snap, err := tx.Get(r.ref(beaconID))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return logger.RedactErr(fmt.Errorf("beacons: get beacon: %w", err), beaconID)
		}
		var d beaconDoc
		if err := snap.DataTo(&d); err != nil {
			return logger.RedactErr(fmt.Errorf("beacons: decode beacon: %w", err), beaconID)
		}
		if d.Hidden == hidden {
			return nil
		}
		var hv any = firestore.Delete
		if hidden {
			hv = true
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.ref(beaconID), []firestore.Update{{Path: "hidden", Value: hv}, {Path: "updatedAt", Value: now.UTC()}})
		if err := b.Err(); err != nil {
			return err
		}
		changed = true
		return nil
	})
	if err != nil {
		return false, err
	}
	return changed, nil
}

// Stats is the operator-side read of the pilot (`opsctl beacon counts`, docs/beacons-plan.md PR 8): aggregate counts
// only, nothing per beacon or per user. *FirestoreRepo implements it.
type Stats interface {
	// Counts answers the four aggregate counts over beacons/ through count aggregations: no document is read, whatever
	// the collection holds. Open and Hidden are independent (a hidden OPEN beacon is in both).
	Counts(ctx context.Context) (Counts, error)
}

// Counts is one Stats.Counts answer.
type Counts struct {
	Open, Full, Cancelled, Hidden int64
}

var _ Stats = (*FirestoreRepo)(nil)

// Counts implements Stats: four count aggregations, each over one single-field equality filter (`status` or `hidden`),
// so no composite index or collection-group exemption is needed. Participant-level counts would need a collection-group
// index on beaconParticipants.state (a gate file), so they are not here.
func (r *FirestoreRepo) Counts(ctx context.Context) (Counts, error) {
	if r == nil || r.client == nil {
		return Counts{}, fmt.Errorf("beacons: repo is not wired")
	}
	col := r.client.Collection(beaconsCollection)
	var out Counts
	for _, c := range []struct {
		name  string
		query firestore.Query
		dst   *int64
	}{
		{"open", col.Where("status", "==", string(StatusOpen)), &out.Open},
		{"full", col.Where("status", "==", string(StatusFull)), &out.Full},
		{"cancelled", col.Where("status", "==", string(StatusCancelled)), &out.Cancelled},
		{"hidden", col.Where("hidden", "==", true), &out.Hidden},
	} {
		res, err := c.query.NewAggregationQuery().WithCount("n").Get(ctx)
		if err != nil {
			return Counts{}, fmt.Errorf("beacons: count %s: %w", c.name, err)
		}
		var n struct {
			N int64 `firestore:"n"`
		}
		if err := res.DataTo(&n); err != nil {
			return Counts{}, fmt.Errorf("beacons: count %s decode: %w", c.name, err)
		}
		*c.dst = n.N
	}
	return out, nil
}
