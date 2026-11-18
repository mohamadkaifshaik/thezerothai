package keys

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// keyDevicesCollection is users/{uid}/keyDevices/{deviceId}; keyPackagesCollection is
	// users/{uid}/keyDevices/{deviceId}/keyPackages/{id}. Distinctive names so the collection-group scans of the
	// lifecycle guard and sweep cannot collide. Only FirestoreRepo touches them.
	keyDevicesCollection  = "keyDevices"
	keyPackagesCollection = "keyPackages"
	usersCollection       = "users"

	// packageIDHexLen is the length of a pool document id: the first 32 hex characters of SHA-256 of the package bytes.
	packageIDHexLen = 32
	// removePageSize is how many pool documents one Remove batch deletes.
	removePageSize = 100
	// removeRounds bounds how often Remove sweeps again because an Upload refilled the pool before its final transaction.
	removeRounds = 5

	// txTimeout bounds one transaction (all attempts); maxTxRuns bounds the outer re-runs. One user's devices are
	// written by that user, so contention is a double tap or two devices racing for the last slot.
	txTimeout = 5 * time.Second
	maxTxRuns = 3
	txBackoff = 20 * time.Millisecond
)

// deviceDoc is users/{uid}/keyDevices/{deviceId}. LastResort is absent (omitempty) while there is none.
type deviceDoc struct {
	SignatureKey []byte    `firestore:"signatureKey"`
	CreatedAt    time.Time `firestore:"createdAt"`
	LastSeenAt   time.Time `firestore:"lastSeenAt"`
	LastResort   []byte    `firestore:"lastResort,omitempty"`
	// PoolCount is the number of pool documents. Invariant: it is changed only inside the Upload, Remove and Claim
	// transactions, as a delta, never recounted (a recount would break Upload's bound of 100 reads); the eraser
	// deletes by listing documents, never by this counter.
	PoolCount int `firestore:"poolCount"`
}

func (d deviceDoc) device(id string) Device {
	return Device{
		ID: id, SignatureKey: cloneBytes(d.SignatureKey), CreatedAt: d.CreatedAt, LastSeenAt: d.LastSeenAt,
		PoolCount: d.PoolCount, HasLastResort: len(d.LastResort) > 0,
	}
}

// packageDoc is users/{uid}/keyDevices/{deviceId}/keyPackages/{id}.
type packageDoc struct {
	Data      []byte    `firestore:"data"`
	CreatedAt time.Time `firestore:"createdAt"`
}

// packageID is the pool document id of a key package.
func packageID(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])[:packageIDHexLen]
}

// FirestoreRepo is the Firestore implementation of Repo.
type FirestoreRepo struct {
	client *firestore.Client
	// afterPoolSweep, set only by tests, runs in Remove between the pool sweep and the final transaction.
	afterPoolSweep func()
	// beforePageDelete, set only by tests, runs in the pool sweep between a page query and that page's batch.
	beforePageDelete func()
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repository on the process's one Firestore client.
func NewFirestoreRepo(client *firestore.Client) *FirestoreRepo {
	return &FirestoreRepo{client: client}
}

func (r *FirestoreRepo) devices(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(keyDevicesCollection)
}

func (r *FirestoreRepo) deviceRef(uid, id string) *firestore.DocumentRef {
	return r.devices(uid).Doc(id)
}

func (r *FirestoreRepo) poolCol(uid, id string) *firestore.CollectionRef {
	return r.deviceRef(uid, id).Collection(keyPackagesCollection)
}

// run is one transaction with bounded re-runs, contention noted as keys_txn_contention. Errors carry no uid or device id.
func (r *FirestoreRepo) run(ctx context.Context, uid, deviceID string, fn store.TxnFunc) error {
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, fn)
	store.NoteTxnAttempts(ctx, "keys_txn_contention", attempts)
	return logger.RedactErr(err, uid, deviceID)
}

// refreshDue reports whether a stored last-seen time is old enough to move (strictly more than seenRefreshInterval).
func refreshDue(lastSeen, now time.Time) bool { return now.Sub(lastSeen) > seenRefreshInterval }

// Register implements Repo. Reads: the device document and, for a new id, a query of at most MaxDevicesPerUser+1
// devices. Writes: one (create, or a last-seen update; nothing when the refresh is not due).
func (r *FirestoreRepo) Register(ctx context.Context, uid string, d Device, now time.Time) (Device, error) {
	now = now.UTC()
	var out Device
	err := r.run(ctx, uid, d.ID, func(_ context.Context, tx *firestore.Transaction) error {
		out = Device{}
		ref := r.deviceRef(uid, d.ID)
		snap, err := tx.Get(ref)
		switch {
		case err == nil:
			var cur deviceDoc
			if err := snap.DataTo(&cur); err != nil {
				return fmt.Errorf("keys: decode device: %w", err)
			}
			if !bytes.Equal(cur.SignatureKey, d.SignatureKey) {
				return ErrKeyMismatch
			}
			if refreshDue(cur.LastSeenAt, now) {
				b := store.NewFirestoreTxBatch(tx)
				b.Update(ref, []firestore.Update{{Path: "lastSeenAt", Value: now}})
				if err := b.Err(); err != nil {
					return err
				}
				cur.LastSeenAt = now
			}
			out = cur.device(d.ID)
			return nil
		case status.Code(err) != codes.NotFound:
			return fmt.Errorf("keys: get device: %w", err)
		}
		existing, err := tx.Documents(r.devices(uid).Limit(MaxDevicesPerUser + 1)).GetAll()
		if err != nil {
			return fmt.Errorf("keys: count devices: %w", err)
		}
		if len(existing) >= MaxDevicesPerUser {
			return ErrDeviceLimit
		}
		doc := deviceDoc{SignatureKey: cloneBytes(d.SignatureKey), CreatedAt: now, LastSeenAt: now}
		b := store.NewFirestoreTxBatch(tx)
		b.Create(ref, doc)
		if err := b.Err(); err != nil {
			return err
		}
		out = doc.device(d.ID)
		return nil
	})
	if err != nil {
		return Device{}, err
	}
	return out, nil
}

// List implements Repo: one query, Limit MaxDevicesPerUser, oldest first.
func (r *FirestoreRepo) List(ctx context.Context, uid string) ([]Device, error) {
	snaps, err := r.devices(uid).OrderBy("createdAt", firestore.Asc).Limit(MaxDevicesPerUser).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("keys: list devices: %w", err), uid)
	}
	out := make([]Device, 0, len(snaps))
	for _, s := range snaps {
		var d deviceDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("keys: decode device: %w", err), uid)
		}
		out = append(out, d.device(s.Ref.ID))
	}
	return out, nil
}

// Remove implements Repo. Each round deletes the whole pool in pages of removePageSize (each a query with Limit, the loop
// bounded by MaxPoolSize), then runs one transaction that reads the device document and pool.Limit(1) and deletes the
// device only when the pool is empty. An Upload that committed in between left pool documents, so the round repeats; one
// that tries to commit after conflicts on its device read and then answers ErrNotFound. After removeRounds rounds with a
// pool that keeps refilling, Remove gives up with an Aborted-class error (store.IsContention, the service answers
// UNAVAILABLE with retry). A missing device is success: with no pool nothing is written, with orphan pool documents
// (data from before this fix, or a crash mid-remove) they are deleted too. Writes: one delete per pool document, plus
// one device delete; reads: one page query per page (at least one) and, per round, the device read and a 1-document pool
// query.
//
// The poolCount invariant: poolCount equals the number of pool documents and is changed only inside the Upload, Remove
// and Claim transactions; the eraser deletes by listing documents, never by the counter.
func (r *FirestoreRepo) Remove(ctx context.Context, uid, deviceID string) error {
	for round := 0; round < removeRounds; round++ {
		if err := r.sweepPool(ctx, uid, deviceID); err != nil {
			return err
		}
		if r.afterPoolSweep != nil {
			r.afterPoolSweep()
		}
		done := false
		err := r.run(ctx, uid, deviceID, func(_ context.Context, tx *firestore.Transaction) error {
			done = false
			ref := r.deviceRef(uid, deviceID)
			snap, err := tx.Get(ref)
			exists := err == nil
			if err != nil && status.Code(err) != codes.NotFound {
				return fmt.Errorf("keys: get device: %w", err)
			}
			left, err := tx.Documents(r.poolCol(uid, deviceID).Select().Limit(1)).GetAll()
			if err != nil {
				return fmt.Errorf("keys: check pool: %w", err)
			}
			if len(left) > 0 {
				return nil // refilled by an Upload that committed meanwhile: sweep again
			}
			done = true
			if !exists {
				return nil
			}
			b := store.NewFirestoreTxBatch(tx)
			b.Delete(snap.Ref)
			return b.Err()
		})
		if err != nil {
			return err
		}
		if done {
			return nil
		}
	}
	return logger.RedactErr(fmt.Errorf("keys: remove: pool kept refilling: %w", status.Error(codes.Aborted, "pool refilled during remove")), uid, deviceID)
}

// sweepPool deletes every pool document of the device in batches of removePageSize.
func (r *FirestoreRepo) sweepPool(ctx context.Context, uid, deviceID string) error {
	for i := 0; i < MaxPoolSize; i++ {
		snaps, err := r.poolCol(uid, deviceID).Select().Limit(removePageSize).Documents(ctx).GetAll()
		if err != nil {
			return logger.RedactErr(fmt.Errorf("keys: list pool: %w", err), uid, deviceID)
		}
		if len(snaps) == 0 {
			return nil
		}
		if r.beforePageDelete != nil {
			r.beforePageDelete()
		}
		// One atomic batch per page: the deletes (each requiring its document to still exist) and, while the device
		// exists, poolCount -= len(page), so the counter stays true if the sweep stops half way. A failed precondition
		// means the device is gone (orphans: plain deletes, no counter) or a Claim took a listed document after the page
		// query (the counter must not be decremented for it twice): re-list and try again, within the loop bound.
		err = r.deletePage(ctx, uid, deviceID, snaps, true)
		if err == nil {
			continue
		}
		if !store.IsPreconditionFailed(err) {
			return logger.RedactErr(fmt.Errorf("keys: delete pool: %w", err), uid, deviceID)
		}
		_, gerr := r.deviceRef(uid, deviceID).Get(ctx)
		if gerr == nil {
			continue // a listed document vanished under a live device: re-list
		}
		if status.Code(gerr) != codes.NotFound {
			return logger.RedactErr(fmt.Errorf("keys: get device: %w", gerr), uid, deviceID)
		}
		if err := r.deletePage(ctx, uid, deviceID, snaps, false); err != nil {
			return logger.RedactErr(fmt.Errorf("keys: delete orphan pool: %w", err), uid, deviceID)
		}
	}
	return nil
}

// deletePage deletes the page's documents in one batch (at most removePageSize + 1 writes). withCounter makes every delete
// require its document to exist and adds the device's poolCount decrement; the batch then fails as a whole, with a
// precondition error, when a listed document is gone or the device document does not exist. Without it the deletes are
// plain (orphans under a missing device, no counter).
func (r *FirestoreRepo) deletePage(ctx context.Context, uid, deviceID string, snaps []*firestore.DocumentSnapshot, withCounter bool) error {
	b := store.NewFirestoreBatch(r.client)
	for _, s := range snaps {
		if withCounter {
			b.Delete(s.Ref, firestore.Exists)
		} else {
			b.Delete(s.Ref)
		}
	}
	if withCounter {
		b.Update(r.deviceRef(uid, deviceID), []firestore.Update{{Path: "poolCount", Value: firestore.Increment(-len(snaps))}})
	}
	return b.Commit(ctx)
}

// ActiveDevices implements Repo: the List query (Limit MaxDevicesPerUser, oldest first) filtered to devices active at
// now. Nothing is written; LastSeenAt is not refreshed.
func (r *FirestoreRepo) ActiveDevices(ctx context.Context, uid string, now time.Time) ([]Device, error) {
	all, err := r.List(ctx, uid)
	if err != nil {
		return nil, err
	}
	out := make([]Device, 0, len(all))
	for _, d := range all {
		if d.Active(now) {
			out = append(out, d)
		}
	}
	return out, nil
}

// claimedDevice is one device a claim takes from: its reference, its stored document and its pool head (nil = empty).
type claimedDevice struct {
	ref  *firestore.DocumentRef
	doc  deviceDoc
	head *firestore.DocumentSnapshot
}

// Claim implements Repo as one transaction, so it conflicts with a concurrent Upload, Remove, Register or Claim of the
// same devices. All reads come first: the target's device documents (one query, Limit MaxDevicesPerUser, oldest first),
// then for each active, non-excluded device one pool query ordered by document id with Limit 1. The pool query, never
// poolCount, decides whether a package exists. Then per device with a pool head: delete it and set poolCount to
// max(read count - 1, 0) (a stale counter is never driven negative); with an empty pool the last-resort package is
// returned and nothing is written for that device. Bound: at most 5 device documents + 5 pool documents read (10), at
// most 5 deletes + 5 updates (10). LastSeenAt is never written. Two claims of one device read the same pool head and the
// device documents, so one of them retries; claims of one user are serialised by the device reads anyway.
func (r *FirestoreRepo) Claim(ctx context.Context, targetUID, excludeDeviceID string, now time.Time) ([]Claimed, error) {
	var out []Claimed
	var seen []string
	err := r.run(ctx, targetUID, excludeDeviceID, func(_ context.Context, tx *firestore.Transaction) error {
		out, seen = nil, seen[:0]
		snaps, err := tx.Documents(r.devices(targetUID).OrderBy("createdAt", firestore.Asc).Limit(MaxDevicesPerUser)).GetAll()
		if err != nil {
			return fmt.Errorf("keys: read devices: %w", err)
		}
		excluded := false
		picks := make([]claimedDevice, 0, len(snaps))
		for _, s := range snaps {
			seen = append(seen, s.Ref.ID)
			if s.Ref.ID == excludeDeviceID {
				excluded = true
				continue
			}
			var d deviceDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("keys: decode device: %w", err)
			}
			if d.device(s.Ref.ID).Active(now) {
				picks = append(picks, claimedDevice{ref: s.Ref, doc: d})
			}
		}
		if excludeDeviceID != "" && !excluded {
			return ErrExcludeNotFound
		}
		for i := range picks {
			heads, err := tx.Documents(picks[i].ref.Collection(keyPackagesCollection).OrderBy(firestore.DocumentID, firestore.Asc).Limit(1)).GetAll()
			if err != nil {
				return fmt.Errorf("keys: read pool: %w", err)
			}
			if len(heads) > 0 {
				picks[i].head = heads[0]
			}
		}
		b := store.NewFirestoreTxBatch(tx)
		out = make([]Claimed, 0, len(picks))
		for _, p := range picks {
			c := Claimed{DeviceID: p.ref.ID, SignatureKey: cloneBytes(p.doc.SignatureKey)}
			switch {
			case p.head != nil:
				var pd packageDoc
				if err := p.head.DataTo(&pd); err != nil {
					return fmt.Errorf("keys: decode package: %w", err)
				}
				c.KeyPackage, c.HasKeyPackage = cloneBytes(pd.Data), true
				b.Delete(p.head.Ref)
				b.Update(p.ref, []firestore.Update{{Path: "poolCount", Value: max(p.doc.PoolCount-1, 0)}})
			case len(p.doc.LastResort) > 0:
				c.KeyPackage, c.HasKeyPackage, c.LastResort = cloneBytes(p.doc.LastResort), true, true
			}
			out = append(out, c)
		}
		return b.Err()
	})
	if err != nil {
		return nil, logger.RedactErr(err, seen...)
	}
	return out, nil
}

// Upload implements Repo. poolCount is kept as a delta of the true document count (see deviceDoc.PoolCount); more than
// MaxUploadBatch packages is refused before any read, so the write bound holds for every caller. Reads: the device document and one GetAll of at most MaxUploadBatch candidate pool documents.
// Writes: one create per absent candidate while the pool has room (at most MaxUploadBatch) plus one device update (pool
// count, last resort, last seen), none at all when nothing changes.
func (r *FirestoreRepo) Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte, now time.Time) (int, bool, error) {
	if len(packages) > MaxUploadBatch {
		return 0, false, apierr.Validation("key_packages", "at most 100 key packages per upload")
	}
	now = now.UTC()
	var count int
	var hasLR bool
	err := r.run(ctx, uid, deviceID, func(_ context.Context, tx *firestore.Transaction) error {
		count, hasLR = 0, false
		ref := r.deviceRef(uid, deviceID)
		snap, err := tx.Get(ref)
		if status.Code(err) == codes.NotFound {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("keys: get device: %w", err)
		}
		var cur deviceDoc
		if err := snap.DataTo(&cur); err != nil {
			return fmt.Errorf("keys: decode device: %w", err)
		}

		// Candidates by id, first occurrence wins; the same bytes are one document.
		seen := make(map[string]bool, len(packages))
		var ids []string
		var datas [][]byte
		for _, p := range packages {
			id := packageID(p)
			if !seen[id] {
				seen[id] = true
				ids = append(ids, id)
				datas = append(datas, p)
			}
		}
		var have []*firestore.DocumentSnapshot
		if len(ids) > 0 {
			refs := make([]*firestore.DocumentRef, len(ids))
			for i, id := range ids {
				refs[i] = r.poolCol(uid, deviceID).Doc(id)
			}
			if have, err = tx.GetAll(refs); err != nil {
				return fmt.Errorf("keys: read pool candidates: %w", err)
			}
		}

		b := store.NewFirestoreTxBatch(tx)
		count = cur.PoolCount
		for i, s := range have {
			if s.Exists() {
				continue
			}
			if count >= MaxPoolSize {
				break // the oldest stay; the rest are dropped
			}
			b.Create(s.Ref, packageDoc{Data: cloneBytes(datas[i]), CreatedAt: now})
			count++
		}
		var updates []firestore.Update
		if count != cur.PoolCount {
			updates = append(updates, firestore.Update{Path: "poolCount", Value: count})
		}
		hasLR = len(cur.LastResort) > 0
		if len(lastResort) > 0 {
			updates = append(updates, firestore.Update{Path: "lastResort", Value: cloneBytes(lastResort)})
			hasLR = true
		}
		if refreshDue(cur.LastSeenAt, now) {
			updates = append(updates, firestore.Update{Path: "lastSeenAt", Value: now})
		}
		if len(updates) > 0 {
			b.Update(ref, updates)
		}
		return b.Err()
	})
	if err != nil {
		return 0, false, err
	}
	return count, hasLR, nil
}
