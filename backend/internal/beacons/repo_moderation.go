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
	return r.operatorUpdate(ctx, beaconID, now, func(d *beaconDoc) []firestore.Update {
		if d.Hidden == hidden {
			return nil
		}
		var hv any = firestore.Delete
		if hidden {
			hv = true
		}
		return []firestore.Update{{Path: "hidden", Value: hv}}
	})
}

// operatorUpdate is the one transaction of the opsctl levers: read the beacon (ErrNotFound when it is gone), ask change
// for the field-level writes, and only when there are any write them with updatedAt (never a Set, so a beacon deleted
// in between stays deleted and no other field is touched). changed reports whether anything was written.
func (r *FirestoreRepo) operatorUpdate(ctx context.Context, beaconID string, now time.Time, change func(d *beaconDoc) []firestore.Update) (bool, error) {
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
		updates := change(&d)
		if len(updates) == 0 {
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.ref(beaconID), append(updates, firestore.Update{Path: "updatedAt", Value: now.UTC()}))
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
	// Counts answers the five aggregate counts over beacons/ and the two over every beaconParticipants subcollection
	// through count aggregations: no document is read, whatever the collections hold. The counters are independent: a
	// hidden OPEN beacon is in both Open and Hidden; ENDED is derived at read time and never stored, so a finished plan
	// stays in Open or Full until its TTL sweep and is also in Ended (endAt before the repo clock, whatever its status,
	// cancelled included). Requested and Accepted count participant rows in that state on any beacon (live, ended or
	// cancelled) until the rows' own TTL sweep.
	Counts(ctx context.Context) (Counts, error)
}

// Counts is one Stats.Counts answer.
type Counts struct {
	Open, Full, Cancelled, Hidden, Ended int64
	// Requested is the number of beaconParticipants rows in state REQUESTED (open join requests) and Accepted the
	// number in state ACCEPTED (seats taken), across every beacon.
	Requested, Accepted int64
}

var _ Stats = (*FirestoreRepo)(nil)

// Counts implements Stats: seven count aggregations, each over one single-field filter. The five over beacons/
// (`status` or `hidden` equality, `endAt` range) use the automatic collection-scope indexes. The two participant counts
// are collection-group queries on beaconParticipants (`state` equality), which need the COLLECTION_GROUP single-field
// index declared as the beaconParticipants.state fieldOverride in firebase/firestore.indexes.json: until it is deployed
// they fail with FAILED_PRECONDITION and Counts returns that error (the emulator enforces no index).
func (r *FirestoreRepo) Counts(ctx context.Context) (Counts, error) {
	if r == nil || r.client == nil {
		return Counts{}, fmt.Errorf("beacons: repo is not wired")
	}
	col := r.client.Collection(beaconsCollection)
	parts := r.client.CollectionGroup(participantsSubcollection)
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
		{"ended", col.Where("endAt", "<", r.now().UTC()), &out.Ended},
		{"participants requested", parts.Where("state", "==", PStateRequested), &out.Requested},
		{"participants accepted", parts.Where("state", "==", PStateAccepted), &out.Accepted},
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

// AreaClearer is the operator lever for a bad plan area (`opsctl beacon clear-area`, location design 5.6): abuse or a
// wrong place shown in Nearby. *FirestoreRepo implements it, so the beacons module stays the only writer of beacons/.
type AreaClearer interface {
	// ClearArea removes areaId, cityId and nearAreaIds from one beacon. changed is false when it had no area (nothing
	// written). ErrNotFound for a missing beacon.
	ClearArea(ctx context.Context, beaconID string, now time.Time) (changed bool, err error)
}

var _ AreaClearer = (*FirestoreRepo)(nil)

// ClearArea implements AreaClearer: one transaction that reads the beacon (ErrNotFound when it is gone) and, only when
// it has an area, deletes the three area fields and stamps updatedAt through a field-level Update (never a Set, so a
// beacon deleted in between stays deleted and nothing else changes). Idempotent: a repeat writes nothing. The plan drops
// out of Nearby from the next query; the organiser may set an area again (UpdateBeacon).
func (r *FirestoreRepo) ClearArea(ctx context.Context, beaconID string, now time.Time) (bool, error) {
	return r.operatorUpdate(ctx, beaconID, now, func(d *beaconDoc) []firestore.Update { return areaUpdates(d, AreaFields{}) })
}
