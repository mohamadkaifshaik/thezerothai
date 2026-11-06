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
