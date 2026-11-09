package beacons

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// beaconsCollection is beacons/{beaconId}; participantsSubcollection is beacons/{beaconId}/beaconParticipants/{uid}
	// (named uniquely because the lifecycle sweep scans subcollections as collection groups, R1); membershipsSubcollection is
	// users/{uid}/beaconMemberships/{beaconId}. Only beacons.FirestoreRepo touches them. Each has a row in
	// apiserver/lifecycle_collections_guard_test.go, the `beacons` eraser step and the `beacons` export section.
	beaconsCollection         = "beacons"
	participantsSubcollection = "beaconParticipants"
	membershipsSubcollection  = "beaconMemberships"
	usersCollection           = "users"

	// The idempotency doc id is hashed with these rpc names.
	rpcCreateBeacon = "CreateBeacon"
	rpcUpdateBeacon = "UpdateBeacon"
	rpcCancelBeacon = "CancelBeacon"

	// txTimeout bounds one beacon transaction (all attempts); maxTxRuns bounds the outer re-runs after the SDK's own
	// attempts lost the lock race. A beacon doc has one organiser writer, so contention is a double tap.
	txTimeout = 5 * time.Second
	maxTxRuns = 3
	txBackoff = 20 * time.Millisecond
)

// liveStatuses are the stored statuses a beacon may be listed or counted in.
var liveStatuses = []string{string(StatusOpen), string(StatusFull)}

// beaconDoc is beacons/{beaconId}.
type beaconDoc struct {
	OrganiserID   string    `firestore:"organiserId"`
	CommunityID   string    `firestore:"communityId"`
	Activity      string    `firestore:"activity"`
	Title         string    `firestore:"title"`
	Details       string    `firestore:"details"`
	Venue         string    `firestore:"venue"`
	StartAt       time.Time `firestore:"startAt"`
	EndAt         time.Time `firestore:"endAt"`
	DurationMin   int       `firestore:"durationMin"`
	OpenSpots     int       `firestore:"openSpots"`
	AcceptedCount int       `firestore:"acceptedCount"`
	Cost          string    `firestore:"cost"`
	ChatPref      string    `firestore:"chatPref"`
	Eligibility   string    `firestore:"eligibility"`
	Status        string    `firestore:"status"`
	Hidden        bool      `firestore:"hidden,omitempty"`
	CreatedAt     time.Time `firestore:"createdAt"`
	UpdatedAt     time.Time `firestore:"updatedAt"`
	ExpireAt      time.Time `firestore:"expireAt"`
}

func (d beaconDoc) beacon(id string) Beacon {
	return Beacon{
		ID: id, OrganiserID: d.OrganiserID, CommunityID: d.CommunityID, Activity: Activity(d.Activity), Title: d.Title,
		Details: d.Details, Venue: d.Venue, StartAt: d.StartAt, EndAt: d.EndAt, DurationMin: d.DurationMin,
		OpenSpots: d.OpenSpots, AcceptedCount: d.AcceptedCount, Cost: Cost(d.Cost), ChatPref: ChatPref(d.ChatPref),
		Status: Status(d.Status), Hidden: d.Hidden, CreatedAt: d.CreatedAt, UpdatedAt: d.UpdatedAt, ExpireAt: d.ExpireAt,
	}
}

// membershipDoc is users/{uid}/beaconMemberships/{beaconId}. It never holds another user's uid (R3).
type membershipDoc struct {
	BeaconID     string    `firestore:"beaconId"`
	Role         string    `firestore:"role"`
	State        string    `firestore:"state"`
	PendingUntil time.Time `firestore:"pendingUntil,omitempty"`
	CommunityID  string    `firestore:"communityId"`
	StartAt      time.Time `firestore:"startAt"`
	EndAt        time.Time `firestore:"endAt"`
}

func (m membershipDoc) membership(id string) Membership {
	if m.BeaconID == "" {
		m.BeaconID = id
	}
	return Membership(m)
}

// FirestoreRepo is the Firestore implementation of Repo, and the page source of the eraser and the exporter.
type FirestoreRepo struct {
	client *firestore.Client
	quotas *quota.Store
	idem   *idempotency.Store
	now    func() time.Time
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repository on the process's one Firestore client. quotas and idem are the shared stores; a
// repo built without them (the lifecycle tests) can still erase and export.
func NewFirestoreRepo(client *firestore.Client, quotas *quota.Store, idem *idempotency.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, quotas: quotas, idem: idem, now: time.Now}
}

func (r *FirestoreRepo) col() *firestore.CollectionRef { return r.client.Collection(beaconsCollection) }

func (r *FirestoreRepo) ref(id string) *firestore.DocumentRef { return r.col().Doc(id) }

// membershipRef is users/{uid}/beaconMemberships/{beaconId}.
func (r *FirestoreRepo) membershipRef(uid, beaconID string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(membershipsSubcollection).Doc(beaconID)
}

func (r *FirestoreRepo) ready() error {
	if r == nil || r.client == nil || r.quotas == nil || r.idem == nil {
		return errors.New("beacons: repo is not fully wired")
	}
	return nil
}

// run is one beacon transaction with bounded re-runs. A same-key request that committed first leaves AlreadyExists on
// this one's idempotency Create; the transaction is run once more, finds the record and replays it.
func (r *FirestoreRepo) run(ctx context.Context, fn store.TxnFunc) (int, error) {
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, fn)
	if status.Code(err) == codes.AlreadyExists {
		again, err2 := store.RunTransactionRetry(ctx, r.client, cfg, fn)
		return attempts + again, err2
	}
	return attempts, err
}

// putIdem appends the TTL'd idempotency document of rpc, holding the beacon id only (a record outlives the beacon by up
// to 48 h, so it must not keep its text), to b.
func (r *FirestoreRepo) putIdem(b store.Batch, uid, key, rpc, hash, beaconID string) {
	r.putIdemResult(b, uid, key, rpc, hash, map[string]string{"id": beaconID})
}

// putIdemResult is putIdem with an explicit result map (the participation writes also keep the target uid).
func (r *FirestoreRepo) putIdemResult(b store.Batch, uid, key, rpc, hash string, result map[string]string) {
	r.idem.Put(b, key, idempotency.Record{
		UID: uid, RPC: rpc, RequestHash: hash, Result: result, ExpireAt: r.now().UTC().Add(idempotency.TTL),
	})
}

// lookup reads the idempotency document in tx. found with a nil error is a replay; found with ErrKeyReused is a record
// that belongs to another request body; not found means the caller proceeds.
func (r *FirestoreRepo) lookup(ctx context.Context, tx *firestore.Transaction, key, hash string) (rec idempotency.Record, found bool, err error) {
	rec, err = r.idem.Get(ctx, tx, key)
	switch {
	case err == nil:
		if rec.RequestHash != hash {
			return rec, true, ErrKeyReused
		}
		return rec, true, nil
	case errors.Is(err, idempotency.ErrNotFound):
		return rec, false, nil
	default:
		return rec, false, fmt.Errorf("beacons: idempotency lookup: %w", err)
	}
}

// replay answers a replay from the beacon as it is now (1 fresh read in tx): a beacon deleted since is ErrNotFound.
func (r *FirestoreRepo) replay(ctx context.Context, tx *firestore.Transaction, uid string, rec idempotency.Record) (Beacon, error) {
	id := rec.Result["id"]
	if id == "" {
		return Beacon{}, ErrNotFound
	}
	d, err := r.getOwned(ctx, tx, uid, id)
	if err != nil {
		return Beacon{}, err
	}
	return d.beacon(id), nil
}

// getOwned reads beacons/{id} inside tx: ErrNotFound when missing, ErrNotOrganiser when organised by someone else
// (the service has already proved the caller may see the beacon, so this leaks nothing).
func (r *FirestoreRepo) getOwned(ctx context.Context, tx *firestore.Transaction, uid, id string) (beaconDoc, error) {
	snap, err := tx.Get(r.ref(id))
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return beaconDoc{}, ErrNotFound
		}
		return beaconDoc{}, fmt.Errorf("beacons: get beacon: %w", err)
	}
	var d beaconDoc
	if err := snap.DataTo(&d); err != nil {
		return beaconDoc{}, fmt.Errorf("beacons: decode beacon: %w", err)
	}
	if d.OrganiserID != uid {
		return beaconDoc{}, ErrNotOrganiser
	}
	return d, nil
}

// countLive counts uid's OPEN or FULL beacons whose endAt is ahead of now, inside tx, stopping at limit (R2: an ended
// beacon keeps its stored status, so endAt decides). Composite index (organiserId, status, endAt).
func (r *FirestoreRepo) countLive(ctx context.Context, tx *firestore.Transaction, uid string, limit int, now time.Time) (int64, error) {
	q := r.col().Where("organiserId", "==", uid).Where("status", "in", liveStatuses).Where("endAt", ">", now).Limit(limit)
	res, err := q.NewAggregationQuery().WithCount("n").Transaction(tx).Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("beacons: count live: %w", err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("beacons: count decode: %w", err)
	}
	return out.N, nil
}

// Create implements Repo: one transaction. Reads, fresh and in this order: idempotency/{hash} (a replay returns here),
// quotas/{uid}, count() of the organiser's live beacons. Writes: Create the beacon, Set the organiser's membership row,
// Create the idempotency document, and quotas/{uid} rewritten unchanged so two racing creates conflict and the cap stays
// exact. At the cap nothing is written.
func (r *FirestoreRepo) Create(ctx context.Context, p CreateParams) (CreateResult, error) {
	if err := r.ready(); err != nil {
		return CreateResult{}, err
	}
	var res CreateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = CreateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				b, rerr := r.replay(ctx, tx, p.UID, rec)
				if rerr != nil {
					return rerr
				}
				res = CreateResult{Outcome: Replayed, Beacon: b}
			}
			return err
		}
		qrec, err := r.quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("beacons: create lock read: %w", err)
		}
		now := r.now().UTC()
		n, err := r.countLive(ctx, tx, p.UID, p.MaxOpenPerUser, now)
		if err != nil {
			return err
		}
		if n >= int64(p.MaxOpenPerUser) {
			return ErrOpenLimit
		}
		b := store.NewFirestoreTxBatch(tx)
		quota.Touch(b, r.quotas.Ref(p.UID), qrec) // counts nothing; it makes racing creates conflict (above)
		in := p.Beacon
		doc := beaconDoc{
			OrganiserID: p.UID, CommunityID: in.CommunityID, Activity: string(in.Activity), Title: in.Title, Details: in.Details,
			Venue: in.Venue, StartAt: in.StartAt.UTC(), EndAt: in.EndAt.UTC(), DurationMin: in.DurationMin, OpenSpots: in.OpenSpots,
			AcceptedCount: 0, Cost: string(in.Cost), ChatPref: string(in.ChatPref), Eligibility: EligibilityEveryone,
			Status: string(StatusOpen), CreatedAt: now, UpdatedAt: now, ExpireAt: in.StartAt.UTC().Add(ExpireAfterStart),
		}
		b.Create(r.ref(p.ID), doc)
		b.Set(r.membershipRef(p.UID, p.ID), membershipDoc{
			BeaconID: p.ID, Role: RoleOrganiser, State: string(StatusOpen), CommunityID: in.CommunityID, StartAt: doc.StartAt, EndAt: doc.EndAt,
		})
		r.putIdem(b, p.UID, p.IdemKey, rpcCreateBeacon, p.RequestHash, p.ID)
		if err := b.Err(); err != nil {
			return err
		}
		res = CreateResult{Outcome: Written, Beacon: doc.beacon(p.ID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}

// liveStatus is the stored status for accepted and open_spots: FULL when every seat is taken, else OPEN.
func liveStatus(accepted, openSpots int) Status {
	if accepted >= openSpots {
		return StatusFull
	}
	return StatusOpen
}

// Update implements Repo: one transaction. Reads, fresh: idempotency (a replay returns), the beacon (owner-checked). A
// CANCELLED or ENDED beacon (at p.Now) refuses with ErrCancelled / ErrEnded and writes nothing. The set fields that differ
// are written field-level (never a Set, so a deleted beacon stays deleted); open_spots below accepted_count is VALIDATION
// "open_spots"; the stored status follows accepted_count against the new open_spots. Nothing to change writes only the
// idempotency document.
func (r *FirestoreRepo) Update(ctx context.Context, p UpdateParams) (UpdateResult, error) {
	if err := r.ready(); err != nil {
		return UpdateResult{}, err
	}
	var res UpdateResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = UpdateResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				b, rerr := r.replay(ctx, tx, p.UID, rec)
				if rerr != nil {
					return rerr
				}
				res = UpdateResult{Outcome: Replayed, Beacon: b}
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.BeaconID)
		if err != nil {
			return err
		}
		switch d.beacon(p.BeaconID).EffectiveStatus(p.Now) {
		case StatusCancelled:
			return ErrCancelled
		case StatusEnded:
			return ErrEnded
		}
		var updates []firestore.Update
		if p.Title != nil && *p.Title != d.Title {
			updates = append(updates, firestore.Update{Path: "title", Value: *p.Title})
			d.Title = *p.Title
		}
		if p.Details != nil && *p.Details != d.Details {
			updates = append(updates, firestore.Update{Path: "details", Value: *p.Details})
			d.Details = *p.Details
		}
		if p.Venue != nil && *p.Venue != d.Venue {
			updates = append(updates, firestore.Update{Path: "venue", Value: *p.Venue})
			d.Venue = *p.Venue
		}
		if p.OpenSpots != nil {
			if *p.OpenSpots < d.AcceptedCount {
				return apierr.Validation("open_spots", "open_spots cannot be below accepted_count")
			}
			if *p.OpenSpots != d.OpenSpots {
				updates = append(updates, firestore.Update{Path: "openSpots", Value: *p.OpenSpots})
				d.OpenSpots = *p.OpenSpots
			}
			if s := string(liveStatus(d.AcceptedCount, d.OpenSpots)); s != d.Status {
				updates = append(updates, firestore.Update{Path: "status", Value: s})
				d.Status = s
			}
		}
		b := store.NewFirestoreTxBatch(tx)
		outcome := Unchanged
		if len(updates) > 0 {
			d.UpdatedAt = p.Now.UTC() // the service's clock, the same one that decided ENDED
			updates = append(updates, firestore.Update{Path: "updatedAt", Value: d.UpdatedAt})
			b.Update(r.ref(p.BeaconID), updates)
			outcome = Written
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcUpdateBeacon, p.RequestHash, p.BeaconID)
		if err := b.Err(); err != nil {
			return err
		}
		res = UpdateResult{Outcome: outcome, Beacon: d.beacon(p.BeaconID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}

// Cancel implements Repo: one transaction. Reads, fresh: idempotency (a replay returns), the beacon (owner-checked). An
// already CANCELLED beacon is success with the idempotency document only; an ENDED one (at p.Now) is ErrEnded and writes
// nothing; otherwise the status and the organiser's membership state become cancelled, and p.Stage (when set) adds its
// writes to the same commit.
func (r *FirestoreRepo) Cancel(ctx context.Context, p CancelParams) (CancelResult, error) {
	if err := r.ready(); err != nil {
		return CancelResult{}, err
	}
	var res CancelResult
	attempts, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		res = CancelResult{}
		rec, found, err := r.lookup(ctx, tx, p.IdemKey, p.RequestHash)
		if found || err != nil {
			if err == nil {
				b, rerr := r.replay(ctx, tx, p.UID, rec)
				if rerr != nil {
					return rerr
				}
				res = CancelResult{Outcome: Replayed, Beacon: b}
			}
			return err
		}
		d, err := r.getOwned(ctx, tx, p.UID, p.BeaconID)
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		switch d.beacon(p.BeaconID).EffectiveStatus(p.Now) {
		case StatusCancelled:
			r.putIdem(b, p.UID, p.IdemKey, rpcCancelBeacon, p.RequestHash, p.BeaconID)
			if err := b.Err(); err != nil {
				return err
			}
			res = CancelResult{Outcome: Unchanged, Beacon: d.beacon(p.BeaconID)}
			return nil
		case StatusEnded:
			return ErrEnded
		}
		now := p.Now.UTC() // the service's clock, the same one that decided ENDED
		d.Status, d.UpdatedAt = string(StatusCancelled), now
		b.Update(r.ref(p.BeaconID), []firestore.Update{
			{Path: "status", Value: d.Status},
			{Path: "updatedAt", Value: now},
		})
		b.Set(r.membershipRef(p.UID, p.BeaconID), map[string]any{"state": d.Status}, firestore.MergeAll)
		if p.Stage != nil {
			p.Stage(b, d.beacon(p.BeaconID)) // the cancellation outbox item (B07): after every read, in this commit
		}
		r.putIdem(b, p.UID, p.IdemKey, rpcCancelBeacon, p.RequestHash, p.BeaconID)
		if err := b.Err(); err != nil {
			return err
		}
		res = CancelResult{Outcome: Written, Beacon: d.beacon(p.BeaconID)}
		return nil
	})
	store.NoteTxnAttempts(ctx, "beacons_txn_contention", attempts)
	return res, err
}
