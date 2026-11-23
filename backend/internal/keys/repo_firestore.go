package keys

import (
	"bytes"
	"context"
	"crypto/rand"
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
	// keyDeviceRemovalsCollection is users/{uid}/keyDeviceRemovals/{deviceId}, the removed marks (doc id = the device id).
	keyDeviceRemovalsCollection = "keyDeviceRemovals"
	usersCollection             = "users"

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
	// PoolCount is the number of pool documents. Invariant: it changes only in the same atomic write as the pool
	// documents it counts (Upload's transaction, Remove's page batches and final transaction, Claim's compare-and-delete
	// batch), as a delta, never recounted (a recount would break Upload's bound of 100 reads); the eraser deletes by
	// listing documents, never by this counter.
	PoolCount int `firestore:"poolCount"`
	// RemovedAt is set by a REMOTE removal's mark transaction (MarkRemoved) and absent while the device is live. A
	// document carrying it is not a registered device: List, ActiveDevices and Claim skip it, and Register and Upload
	// refuse its id with ErrDeviceRemoved. It still counts toward MaxDevicesPerUser in Register until the removal deletes
	// it, so a user never has more than MaxDevicesPerUser device documents and the Limit-5 readers always see all of them.
	RemovedAt *time.Time `firestore:"removedAt,omitempty"`
}

// removed reports whether the document carries removedAt.
func (d deviceDoc) removed() bool { return d.RemovedAt != nil }

// markDoc is users/{uid}/keyDeviceRemovals/{deviceId}, the removed mark of a REMOTE removal. The doc id is the device id
// (one direct get answers "is this id marked?"); nothing else names the device. ExpireAt is the Firestore TTL field
// (infra/terraform/modules/firestore ttl_fields key_device_removals_expire_at) and is never read by the code. The H2 cut
// fields (cutAt, cutDone) come with the session-cut PR.
type markDoc struct {
	RemovedAt time.Time `firestore:"removedAt"`
	ExpireAt  time.Time `firestore:"expireAt"`
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
	// beforeClaimCommit, set only by tests, runs before a claim batch commits; a non-nil result replaces the commit.
	beforeClaimCommit func(deviceID string) error
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

func (r *FirestoreRepo) marks(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(keyDeviceRemovalsCollection)
}

func (r *FirestoreRepo) markRef(uid, id string) *firestore.DocumentRef { return r.marks(uid).Doc(id) }

// MarkRemoved implements Repo: one transaction that reads the device document and the mark (one GetAll of 2) and writes
// the mark (create, when absent) and the device's removedAt (when the document exists without it): at most 2 writes, none
// on a repeat. recent is whether the caller signed in recently; it is required unless this is a retry, decided on the
// documents read here: the mark exists AND the device document is missing or already carries removedAt. A mark over a
// live document (one an image without the marks re-created, security audit M3) is not a retry. Without it the answer is
// ErrReauthRequired and nothing is written. A Register of the same id runs its transaction on the same two documents, so
// Firestore serialises the two: either the Register lands first and is stamped here, or it reads the mark and is refused.
func (r *FirestoreRepo) MarkRemoved(ctx context.Context, uid, deviceID string, now time.Time, recent bool) error {
	now = now.UTC()
	return r.run(ctx, uid, deviceID, func(_ context.Context, tx *firestore.Transaction) error {
		devRef, markRef := r.deviceRef(uid, deviceID), r.markRef(uid, deviceID)
		snaps, err := tx.GetAll([]*firestore.DocumentRef{devRef, markRef})
		if err != nil {
			return fmt.Errorf("keys: read device and mark: %w", err)
		}
		if len(snaps) != 2 {
			return fmt.Errorf("keys: read device and mark: got %d documents, want 2", len(snaps))
		}
		devExists, marked := snaps[0].Exists(), snaps[1].Exists()
		var cur deviceDoc
		if devExists {
			if err := snaps[0].DataTo(&cur); err != nil {
				return fmt.Errorf("keys: decode device: %w", err)
			}
		}
		retry := marked && (!devExists || cur.removed())
		if !recent && !retry {
			return ErrReauthRequired
		}
		b := store.NewFirestoreTxBatch(tx)
		if !marked {
			b.Create(markRef, markDoc{RemovedAt: now, ExpireAt: now.Add(RemovalMarkTTL)})
		}
		if devExists && !cur.removed() {
			b.Update(devRef, []firestore.Update{{Path: "removedAt", Value: now}})
		}
		return b.Err()
	})
}

// ListRemovalMarks implements ExportSource: one query ordered by document id (no index), after afterID exclusive, at most
// limit (clamped to 1..exportMarkPage) marks.
func (r *FirestoreRepo) ListRemovalMarks(ctx context.Context, uid, afterID string, limit int) ([]RemovalMark, error) {
	q := r.marks(uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if afterID != "" {
		q = q.StartAfter(afterID)
	}
	snaps, err := q.Limit(min(max(limit, 1), exportMarkPage)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("keys: list removal marks: %w", err), uid, afterID)
	}
	out := make([]RemovalMark, 0, len(snaps))
	for _, s := range snaps {
		var m markDoc
		if err := s.DataTo(&m); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("keys: decode removal mark: %w", err), uid, s.Ref.ID)
		}
		out = append(out, RemovalMark{DeviceID: s.Ref.ID, RemovedAt: m.RemovedAt, ExpireAt: m.ExpireAt})
	}
	return out, nil
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

// Register implements Repo. Reads: one GetAll of the device document and the removed mark (2 reads) and, for a new id, a
// query of at most MaxDevicesPerUser+1 devices. Writes: one (create, a last-seen update or a removedAt stamp; nothing when
// the refresh is not due). ErrDeviceRemoved comes first: an existing document carrying removedAt; an existing live
// document under a mark (re-created by an image without the marks: it is stamped removedAt in this transaction, then
// refused with ErrDeviceStamped, which the service follows with RemoveRemoving); or a marked new id (decided before the count, so a marked id never learns about the cap). The count includes documents carrying removedAt (see
// deviceDoc.RemovedAt); at the cap, when some of the counted documents carry it since at least StuckRemovalMinAge, the
// answer is a StuckRemovalsError naming them (still ErrDeviceLimit to errors.Is), decided on the documents the count query already read.
func (r *FirestoreRepo) Register(ctx context.Context, uid string, d Device, now time.Time) (Device, error) {
	now = now.UTC()
	var out Device
	stamped := false
	err := r.run(ctx, uid, d.ID, func(_ context.Context, tx *firestore.Transaction) error {
		out, stamped = Device{}, false
		ref := r.deviceRef(uid, d.ID)
		snaps, err := tx.GetAll([]*firestore.DocumentRef{ref, r.markRef(uid, d.ID)})
		if err != nil {
			return fmt.Errorf("keys: read device and mark: %w", err)
		}
		if len(snaps) != 2 {
			return fmt.Errorf("keys: read device and mark: got %d documents, want 2", len(snaps))
		}
		marked := snaps[1].Exists()
		if snaps[0].Exists() {
			var cur deviceDoc
			if err := snaps[0].DataTo(&cur); err != nil {
				return fmt.Errorf("keys: decode device: %w", err)
			}
			if cur.removed() {
				return ErrDeviceRemoved
			}
			if marked {
				// A live document under a mark: an image without the marks (a rollback) registered the id again. Stamp it
				// in this transaction, so every reader skips it, and refuse after the commit (an error here would roll the
				// stamp back).
				b := store.NewFirestoreTxBatch(tx)
				b.Update(ref, []firestore.Update{{Path: "removedAt", Value: now}})
				stamped = true
				return b.Err()
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
		}
		if marked {
			return ErrDeviceRemoved
		}
		existing, err := tx.Documents(r.devices(uid).Limit(MaxDevicesPerUser + 1)).GetAll()
		if err != nil {
			return fmt.Errorf("keys: count devices: %w", err)
		}
		if len(existing) >= MaxDevicesPerUser {
			// The documents are already read: name those carrying removedAt (stuck REMOTE removals) so the service can
			// finish them. No extra read.
			var stuck []string
			for _, s := range existing {
				var have deviceDoc
				if err := s.DataTo(&have); err != nil {
					return fmt.Errorf("keys: decode device: %w", err)
				}
				// A younger removedAt may be a REMOTE removal still in flight: not stuck (yet).
				if have.removed() && now.Sub(*have.RemovedAt) >= StuckRemovalMinAge {
					stuck = append(stuck, s.Ref.ID)
				}
			}
			if len(stuck) > 0 {
				return &StuckRemovalsError{DeviceIDs: stuck}
			}
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
	if stamped {
		return Device{}, ErrDeviceStamped
	}
	return out, nil
}

// List implements Repo: one query, Limit MaxDevicesPerUser, oldest first; documents carrying removedAt are skipped (in
// memory, on documents already read: Register keeps every document, removing ones included, under the cap, so the Limit
// still covers all of them).
func (r *FirestoreRepo) List(ctx context.Context, uid string) ([]Device, error) {
	live, _, err := r.listDocs(ctx, uid)
	return live, err
}

// ExportDevices implements ExportSource: the List query, with the documents carrying removedAt returned apart (pending)
// instead of skipped, so the export never leaves stored data out.
func (r *FirestoreRepo) ExportDevices(ctx context.Context, uid string) ([]Device, []PendingRemoval, error) {
	return r.listDocs(ctx, uid)
}

// listDocs is the one device query of List and ExportDevices (Limit MaxDevicesPerUser, oldest first), split into live
// devices and documents carrying removedAt.
func (r *FirestoreRepo) listDocs(ctx context.Context, uid string) ([]Device, []PendingRemoval, error) {
	snaps, err := r.devices(uid).OrderBy("createdAt", firestore.Asc).Limit(MaxDevicesPerUser).Documents(ctx).GetAll()
	if err != nil {
		return nil, nil, logger.RedactErr(fmt.Errorf("keys: list devices: %w", err), uid)
	}
	live := make([]Device, 0, len(snaps))
	var pending []PendingRemoval
	for _, s := range snaps {
		var d deviceDoc
		if err := s.DataTo(&d); err != nil {
			return nil, nil, logger.RedactErr(fmt.Errorf("keys: decode device: %w", err), uid)
		}
		if d.removed() {
			pending = append(pending, PendingRemoval{Device: d.device(s.Ref.ID), RemovedAt: *d.RemovedAt})
			continue
		}
		live = append(live, d.device(s.Ref.ID))
	}
	return live, pending, nil
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
// The poolCount invariant: poolCount equals the number of pool documents and changes only in the same atomic write as
// those documents (Upload, Remove, Claim; see deviceDoc.PoolCount); the eraser deletes by listing documents, never by the
// counter.
func (r *FirestoreRepo) Remove(ctx context.Context, uid, deviceID string) error {
	return r.remove(ctx, uid, deviceID, false)
}

// RemoveRemoving implements Repo: Remove for a document carrying removedAt only (Minor 1: the stuck-removal finish must
// never delete a live device, even when the stuck document was deleted and the id registered again after its mark
// expired). One device read first: a live document returns nil with nothing written, so its pool is not swept. The
// delete transaction checks again and leaves a document that turned live during the sweep (nil). The one residue of that
// double race: pool documents the sweep took before the document turned live are gone (the counter stays true, the
// device uploads more). Reads: Remove's, plus that one device read.
func (r *FirestoreRepo) RemoveRemoving(ctx context.Context, uid, deviceID string) error {
	snap, err := r.deviceRef(uid, deviceID).Get(ctx)
	switch {
	case err == nil:
		var cur deviceDoc
		if err := snap.DataTo(&cur); err != nil {
			return logger.RedactErr(fmt.Errorf("keys: decode device: %w", err), uid, deviceID)
		}
		if !cur.removed() {
			return nil
		}
	case status.Code(err) != codes.NotFound:
		return logger.RedactErr(fmt.Errorf("keys: get device: %w", err), uid, deviceID)
	}
	return r.remove(ctx, uid, deviceID, true)
}

// remove is Remove; onlyRemoving makes its delete transaction leave a live device document (no removedAt) in place.
func (r *FirestoreRepo) remove(ctx context.Context, uid, deviceID string, onlyRemoving bool) error {
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
			if exists && onlyRemoving {
				var cur deviceDoc
				if err := snap.DataTo(&cur); err != nil {
					return fmt.Errorf("keys: decode device: %w", err)
				}
				if !cur.removed() {
					done = true // live (again): never deleted by the removing-only path
					return nil
				}
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

// Claim re-pick waits (full jitter, store.Wait): a short one after the picked document was taken, a longer one after the
// write lost a lock race.
const (
	claimRepickWait     = 5 * time.Millisecond
	claimContentionWait = 25 * time.Millisecond
)

// claimAttempts bounds how often Claim picks a pool document of one device again after another claimer (or a Remove
// sweep) took the one it picked first. Exhausted attempts fall back to the last-resort package, never an error. With k
// claimers racing over k documents in lock step, each round leaves about a third of them losing; a simulation of 20 over
// 20 gives P(some claimer exhausts its attempts) of 0.74 at 4, 0.085 at 6, 0.0016 at 8 and none in 20000 trials at 10.
const claimAttempts = 10

// fieldClaimRetries is the request-line count of pool picks Claim had to repeat (contention, never an id).
const fieldClaimRetries = "claim_retries"

// claimTarget is one device a claim takes from: its reference and its stored document as the device query read it.
type claimTarget struct {
	ref *firestore.DocumentRef
	doc deviceDoc
}

// Claim implements Repo with compare-and-delete and no transaction, so concurrent claimers hold no read locks and
// cannot deadlock. A plain device query (Limit MaxDevicesPerUser, oldest first) gives the devices, their signature keys
// and last-resort packages; an unmatched non-empty exclude is ErrExcludeNotFound before any write. Per remaining active
// device (claimOne): pick a pool document at a random point of the id space, then take it with one atomic batch of
// Delete(document, Exists) + poolCount Increment(-1). Exactly one batch can delete a given document, and the counter moves
// in the same write, so the poolCount invariant holds without reading it. Reads: the device query (at most 5 documents)
// plus, per device and attempt, at most 2 pool queries of at most 1 document, plus at most 1 device read per device
// (only after a failed batch): at most 15 without contention, at most 5 + 5 x (10 x 2 + 1) = 110 in the worst case.
// Writes: per device one batch of 2 (only a committed batch writes), at most 10. LastSeenAt is never written.
// Not atomic across devices: an error on a later device leaves the packages already taken from earlier ones consumed.
//
// The removal window (code review Minor 3, security audit L1; accepted, documented in keys.proto ClaimKeyPackages): the
// removedAt skip is decided on the device query's read, and the claim batch has no precondition on removedAt. A REMOTE
// removal whose mark transaction commits between the two does not stop the batch, so one package of a device being
// removed can still be handed out. claimOne's re-read after a failed batch does skip it. A precondition would need the
// device's update time from the query and would turn every concurrent last-seen or upload write into a failed batch;
// a fresh read per device would cost up to 5 reads per claim. The welcome-target check (messaging, ActiveDeviceIDs)
// refuses a later commit that names the removed device.
func (r *FirestoreRepo) Claim(ctx context.Context, targetUID, excludeDeviceID string, now time.Time) ([]Claimed, error) {
	snaps, err := r.devices(targetUID).OrderBy("createdAt", firestore.Asc).Limit(MaxDevicesPerUser).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("keys: read devices: %w", err), targetUID, excludeDeviceID)
	}
	seen := []string{targetUID, excludeDeviceID}
	excluded := false
	targets := make([]claimTarget, 0, len(snaps))
	for _, s := range snaps {
		seen = append(seen, s.Ref.ID)
		var d deviceDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("keys: decode device: %w", err), seen...)
		}
		if d.removed() {
			continue // a REMOTE removal in progress: not a registered device, so not claimable and not excludable
		}
		if s.Ref.ID == excludeDeviceID {
			excluded = true
			continue
		}
		if d.device(s.Ref.ID).Active(now) {
			targets = append(targets, claimTarget{ref: s.Ref, doc: d})
		}
	}
	if excludeDeviceID != "" && !excluded {
		return nil, ErrExcludeNotFound
	}
	out := make([]Claimed, 0, len(targets))
	retries := 0
	for _, tg := range targets {
		c, present, n, err := r.claimOne(ctx, tg)
		retries += n
		if err != nil {
			logger.SetRequestField(ctx, fieldClaimRetries, retries)
			return nil, logger.RedactErr(err, seen...)
		}
		if present {
			out = append(out, c)
		}
	}
	logger.SetRequestField(ctx, fieldClaimRetries, retries)
	return out, nil
}

// claimOne takes one package of the device: a one-time package by compare-and-delete, else (empty pool, or every
// attempt lost to another claimer) the last-resort package, else HasKeyPackage false. present is false when the device
// document was deleted meanwhile (the device is then left out). retries counts the repeated picks.
//
// A failed batch is not followed by a read: the next attempt picks again after a short full-jitter wait. Only when a
// pick comes back empty after a failure, or the attempts run out, one device read decides between leaving the device
// out (deleted) and answering with its last-resort package, taken (with the signature key) from that fresh read. An
// empty pool on the first pick uses the device query's own read.
func (r *FirestoreRepo) claimOne(ctx context.Context, tg claimTarget) (c Claimed, present bool, retries int, err error) {
	failed, contended := false, false
	for attempt := 0; attempt < claimAttempts; attempt++ {
		if attempt > 0 {
			retries++
			wait := claimRepickWait
			if contended {
				wait = claimContentionWait
			}
			if werr := store.Wait(ctx, wait); werr != nil {
				return Claimed{}, false, retries, fmt.Errorf("keys: claim wait: %w", werr)
			}
		}
		head, err := r.pickPoolDoc(ctx, tg.ref)
		if err != nil {
			return Claimed{}, false, retries, err
		}
		if head == nil {
			break // empty pool
		}
		var pd packageDoc
		if err := head.DataTo(&pd); err != nil {
			return Claimed{}, false, retries, logger.RedactErr(fmt.Errorf("keys: decode package: %w", err), head.Ref.ID)
		}
		cerr := r.commitClaim(ctx, tg.ref, head.Ref)
		switch {
		case cerr == nil:
			c = Claimed{DeviceID: tg.ref.ID, SignatureKey: cloneBytes(tg.doc.SignatureKey)}
			c.KeyPackage, c.HasKeyPackage = cloneBytes(pd.Data), true
			return c, true, retries, nil
		case store.IsContention(cerr):
			failed, contended = true, true // the write lost a lock race: nothing was written
		case store.IsPreconditionFailed(cerr):
			failed, contended = true, false // the picked document (or the device) is gone
		default:
			return Claimed{}, false, retries, logger.RedactErr(fmt.Errorf("keys: claim package: %w", cerr), head.Ref.ID)
		}
	}
	doc := tg.doc
	if failed {
		snap, gerr := tg.ref.Get(ctx)
		if status.Code(gerr) == codes.NotFound {
			return Claimed{}, false, retries, nil
		}
		if gerr != nil {
			return Claimed{}, false, retries, fmt.Errorf("keys: get device: %w", gerr)
		}
		if err := snap.DataTo(&doc); err != nil {
			return Claimed{}, false, retries, fmt.Errorf("keys: decode device: %w", err)
		}
		if doc.removed() {
			return Claimed{}, false, retries, nil // marked removed meanwhile: left out, like a deleted device
		}
	}
	c = Claimed{DeviceID: tg.ref.ID, SignatureKey: cloneBytes(doc.SignatureKey)}
	if len(doc.LastResort) > 0 {
		c.KeyPackage, c.HasKeyPackage, c.LastResort = cloneBytes(doc.LastResort), true, true
	}
	return c, true, retries, nil
}

// commitClaim is the compare-and-delete: one atomic batch that deletes the pool document only if it still exists and
// decrements the device's poolCount (which fails if the device document is gone).
func (r *FirestoreRepo) commitClaim(ctx context.Context, device, pkg *firestore.DocumentRef) error {
	if r.beforeClaimCommit != nil {
		if err := r.beforeClaimCommit(device.ID); err != nil {
			return err
		}
	}
	b := store.NewFirestoreBatch(r.client)
	b.Delete(pkg, firestore.Exists)
	b.Update(device, []firestore.Update{{Path: "poolCount", Value: firestore.Increment(-1)}})
	return b.Commit(ctx)
}

// pickPoolDoc returns one pool document of the device (nil for an empty pool) without a transaction: the first at or
// after a random id (ids are SHA-256 hex, so concurrent claimers spread over the pool), else the first of all
// (wrap-around). Ordering by document id needs no index. At most 2 queries of at most 1 document.
func (r *FirestoreRepo) pickPoolDoc(ctx context.Context, device *firestore.DocumentRef) (*firestore.DocumentSnapshot, error) {
	var b [packageIDHexLen / 2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return nil, fmt.Errorf("keys: random pick: %w", err)
	}
	byID := device.Collection(keyPackagesCollection).OrderBy(firestore.DocumentID, firestore.Asc)
	snaps, err := byID.StartAt(hex.EncodeToString(b[:])).Limit(1).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("keys: pick package: %w", err)
	}
	if len(snaps) == 0 {
		if snaps, err = byID.Limit(1).Documents(ctx).GetAll(); err != nil {
			return nil, fmt.Errorf("keys: pick package: %w", err)
		}
	}
	if len(snaps) == 0 {
		return nil, nil
	}
	return snaps[0], nil
}

// Upload implements Repo. poolCount is kept as a delta of the true document count (see deviceDoc.PoolCount), written as
// an Increment; more than MaxUploadBatch packages is refused before any read, so the write bound holds for every caller.
// The cap of MaxPoolSize is decided on the transaction's read of the device document. Two concurrent Uploads of one
// device that both add packages both write that document, so the later commit conflicts with the earlier (optimistic
// mode: its read is stale at commit and the transaction is retried; pessimistic: it waits for the lock) and re-reads the
// count; a concurrent Claim only lowers the count, so a stale read can only make Upload add fewer, never overfill.
// Reads: the device document and one GetAll of at most MaxUploadBatch candidate pool documents.
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
			// One more read only on this path: the mark decides DEVICE_REMOVED over NOT_FOUND.
			switch _, merr := tx.Get(r.markRef(uid, deviceID)); {
			case merr == nil:
				return ErrDeviceRemoved
			case status.Code(merr) != codes.NotFound:
				return fmt.Errorf("keys: get removal mark: %w", merr)
			}
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("keys: get device: %w", err)
		}
		var cur deviceDoc
		if err := snap.DataTo(&cur); err != nil {
			return fmt.Errorf("keys: decode device: %w", err)
		}
		if cur.removed() {
			return ErrDeviceRemoved
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
		added := 0
		for i, s := range have {
			if s.Exists() {
				continue
			}
			if cur.PoolCount+added >= MaxPoolSize {
				break // the oldest stay; the rest are dropped
			}
			b.Create(s.Ref, packageDoc{Data: cloneBytes(datas[i]), CreatedAt: now})
			added++
		}
		// The cap is decided on this transaction's read; the counter is written as Increment(added), which commutes with
		// Claim's Increment(-1) under any concurrency mode. The returned count is that read plus what was added: it can be
		// momentarily stale against a concurrent claim (higher by what was claimed meanwhile).
		count = cur.PoolCount + added
		var updates []firestore.Update
		if added > 0 {
			updates = append(updates, firestore.Update{Path: "poolCount", Value: firestore.Increment(added)})
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
