package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	exportsCollection    = "exports"
	privateSubcollection = "private"
	// exportPendingScan bounds the query for a user's PENDING exports. A user holds one live export plus any given-up ones
	// the daily backstop has not failed yet: normally at most one or two. Only a backstop outage of over a week could fill
	// the page and hide the live export, and the cost then is one extra job, not lost data.
	exportPendingScan = 10
	// exportTx* bound the CreateExport transaction. quotas/{uid} is shared with this user's other locked writes, but one
	// user's contention is a double tap, not a hot document.
	exportTxTimeout = 5 * time.Second
	exportTxMaxRuns = 3
	exportTxBackoff = 20 * time.Millisecond
)

var _ LifecycleRepo = (*FirestoreRepo)(nil)

// exportDocFS is the exports/{id} shape. expireAt is the Firestore TTL field.
type exportDocFS struct {
	UID        string    `firestore:"uid"`
	Status     string    `firestore:"status"`
	ObjectPath string    `firestore:"objectPath"`
	CreatedAt  time.Time `firestore:"createdAt"`
	ExpireAt   time.Time `firestore:"expireAt"`
	// LeaseUntil is absent until the first claim (L-4).
	LeaseUntil *time.Time `firestore:"leaseUntil,omitempty"`
}

func (d exportDocFS) toDomain(id string, updateTime time.Time) ExportDoc {
	return ExportDoc{ID: id, UID: d.UID, Status: ExportStatus(d.Status), ObjectPath: d.ObjectPath, CreatedAt: d.CreatedAt, ExpireAt: d.ExpireAt, LeaseUntil: derefTime(d.LeaseUntil), UpdateTime: updateTime}
}

func (r *FirestoreRepo) exportRef(id string) *firestore.DocumentRef {
	return r.client.Collection(exportsCollection).Doc(id)
}

func decodeExport(snap *firestore.DocumentSnapshot) (ExportDoc, error) {
	var d exportDocFS
	if err := snap.DataTo(&d); err != nil {
		return ExportDoc{}, fmt.Errorf("identity: decode export %s: %w", snap.Ref.ID, err)
	}
	return d.toDomain(snap.Ref.ID, snap.UpdateTime), nil
}

// BeginDeletion writes the deletion state once; a replay writes nothing.
func (r *FirestoreRepo) BeginDeletion(ctx context.Context, uid string, now time.Time) (DeletionStart, error) {
	var out DeletionStart
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(r.userRef(uid))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user for deletion: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for deletion: %w", err)
		}
		p := d.toProfile(uid)
		if p.Status == AccountStatusDeleting && !p.DeletionRequestedAt.IsZero() && p.DeletionJob != nil {
			out = DeletionStart{Profile: p, Replay: true}
			return nil
		}
		// ACTIVE, SUSPENDED, or DELETING set by hand without job state: (re)start the job.
		job := DeletionJob{Seq: 0, ProgressAt: now}
		b := store.NewFirestoreTxBatch(tx)
		b.Update(r.userRef(uid), []firestore.Update{
			{Path: "status", Value: statusToString(AccountStatusDeleting)},
			{Path: "updatedAt", Value: now},
			{Path: "deletionRequestedAt", Value: now},
			{Path: "deletionJob", Value: deletionJobToDoc(&job)},
		})
		if b.Err() != nil {
			return b.Err()
		}
		p.Status = AccountStatusDeleting
		p.UpdatedAt = now
		p.DeletionRequestedAt = now
		p.DeletionJob = &job
		out = DeletionStart{Profile: p}
		return nil
	})
	if err != nil {
		return DeletionStart{}, err
	}
	return out, nil
}

// GetJobState reads users/{uid} fresh.
func (r *FirestoreRepo) GetJobState(ctx context.Context, uid string) (Profile, time.Time, error) {
	snap, err := r.userRef(uid).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return Profile{}, time.Time{}, ErrNotFound
		}
		return Profile{}, time.Time{}, fmt.Errorf("identity: get job state: %w", err)
	}
	var d userDoc
	if err := snap.DataTo(&d); err != nil {
		return Profile{}, time.Time{}, fmt.Errorf("identity: decode job state: %w", err)
	}
	return d.toProfile(uid), snap.UpdateTime, nil
}

// SaveJobState writes users/{uid}.deletionJob.
func (r *FirestoreRepo) SaveJobState(ctx context.Context, uid string, updateTime time.Time, job DeletionJob) error {
	_, err := r.userRef(uid).Update(ctx, []firestore.Update{
		{Path: "deletionJob.seq", Value: job.Seq},
		{Path: "deletionJob.step", Value: job.Step},
		{Path: "deletionJob.checkpoint", Value: job.Checkpoint},
		{Path: "deletionJob.progressAt", Value: job.ProgressAt},
	}, firestore.LastUpdateTime(updateTime))
	if err != nil {
		switch status.Code(err) {
		case codes.FailedPrecondition:
			return ErrJobConflict
		case codes.NotFound:
			return ErrNotFound
		}
		return fmt.Errorf("identity: save job state: %w", err)
	}
	return nil
}

// CreateExport creates the PENDING doc unless this id already exists or the uid already has a PENDING export. Either of
// those is returned with replay=true and writes nothing.
func (r *FirestoreRepo) CreateExport(ctx context.Context, p CreateExportParams) (ExportDoc, bool, error) {
	var out ExportDoc
	var replay bool
	quotas := quota.New(r.client)
	cfg := store.TxnRetry{Timeout: exportTxTimeout, MaxRuns: exportTxMaxRuns, Backoff: exportTxBackoff}
	body := func(ctx context.Context, tx *firestore.Transaction) error {
		out, replay = ExportDoc{}, false // the closure reruns on a conflict
		snap, err := tx.Get(r.exportRef(p.ID))
		if err == nil {
			out, err = decodeExport(snap)
			replay = err == nil
			return err
		}
		if status.Code(err) != codes.NotFound {
			return fmt.Errorf("identity: read export: %w", err)
		}
		// Concurrent requests by one user all read and write quotas/{uid} (here and in quota.Touch below), so only one of
		// two racing calls commits: the other is rejected at commit and its retry finds the winner's export. The query must
		// stay AFTER this read: in optimistic mode a query placed above it could miss a winner that commits between the two
		// reads, and this read would then no longer guard it.
		qrec, err := quotas.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("identity: export lock read: %w", err)
		}
		// Equality filters only, so the automatic single-field indexes serve it. Given-up exports are filtered here, not in
		// the query, because a createdAt range would need a new composite index.
		pending, err := tx.Documents(r.client.Collection(exportsCollection).
			Where("uid", "==", p.UID).
			Where("status", "==", string(ExportPending)).
			Limit(exportPendingScan)).GetAll()
		if err != nil {
			return fmt.Errorf("identity: query pending exports: %w", err)
		}
		for _, s := range pending {
			e, err := decodeExport(s)
			if err != nil {
				return err
			}
			if e.CreatedAt.After(p.GiveUpBefore) {
				out, replay = e, true
				return nil
			}
		}
		doc := exportDocFS{UID: p.UID, Status: string(ExportPending), ObjectPath: p.ObjectPath, CreatedAt: p.Now, ExpireAt: p.Now.Add(p.Retention)}
		b := store.NewFirestoreTxBatch(tx)
		quota.Touch(b, quotas.Ref(p.UID), qrec) // counts nothing; it makes racing requests conflict (above)
		b.Create(r.exportRef(p.ID), doc)
		if err := b.Err(); err != nil {
			return err
		}
		out = doc.toDomain(p.ID, time.Time{})
		return nil
	}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg, body)
	if status.Code(err) == codes.AlreadyExists {
		// A same-key request committed first, so this one's Create lost. One more run finds that doc and replays it.
		var again int
		again, err = store.RunTransactionRetry(ctx, r.client, cfg, body)
		attempts += again
	}
	store.NoteTxnAttempts(ctx, "identity_export_txn_contention", attempts)
	if err != nil {
		return ExportDoc{}, false, fmt.Errorf("identity: create export: %w", err)
	}
	return out, replay, nil
}

// GetExport reads exports/{id}.
func (r *FirestoreRepo) GetExport(ctx context.Context, id string) (ExportDoc, error) {
	snap, err := r.exportRef(id).Get(ctx)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return ExportDoc{}, ErrNotFound
		}
		return ExportDoc{}, fmt.Errorf("identity: get export: %w", err)
	}
	return decodeExport(snap)
}

// SetExportStatus sets exports/{id}.status.
func (r *FirestoreRepo) SetExportStatus(ctx context.Context, id string, st ExportStatus, updateTime time.Time) error {
	_, err := r.exportRef(id).Update(ctx, []firestore.Update{{Path: "status", Value: string(st)}}, firestore.LastUpdateTime(updateTime))
	if err != nil {
		switch status.Code(err) {
		case codes.FailedPrecondition:
			return ErrJobConflict
		case codes.NotFound:
			return ErrNotFound
		}
		return fmt.Errorf("identity: set export status: %w", err)
	}
	return nil
}

// ClaimExport sets the lease. The status stays PENDING; only leaseUntil changes, under the read's update time.
func (r *FirestoreRepo) ClaimExport(ctx context.Context, id string, updateTime, leaseUntil time.Time) (time.Time, error) {
	res, err := r.exportRef(id).Update(ctx, []firestore.Update{{Path: "leaseUntil", Value: leaseUntil}}, firestore.LastUpdateTime(updateTime))
	if err != nil {
		switch status.Code(err) {
		case codes.FailedPrecondition, codes.NotFound:
			return time.Time{}, ErrJobConflict
		}
		return time.Time{}, fmt.Errorf("identity: claim export: %w", err)
	}
	return res.UpdateTime, nil
}

// ListExports lists the uid's exports. The uid equality uses the automatic single-field index.
func (r *FirestoreRepo) ListExports(ctx context.Context, uid string, limit int) ([]ExportDoc, error) {
	snaps, err := r.client.Collection(exportsCollection).Where("uid", "==", uid).Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("identity: list exports: %w", err)
	}
	return decodeExports(snaps)
}

func decodeExports(snaps []*firestore.DocumentSnapshot) ([]ExportDoc, error) {
	out := make([]ExportDoc, 0, len(snaps))
	for _, s := range snaps {
		doc, err := decodeExport(s)
		if err != nil {
			return nil, err
		}
		out = append(out, doc)
	}
	return out, nil
}

// DeleteExportDocs: len(ids) deletes in one batch (<= 500).
func (r *FirestoreRepo) DeleteExportDocs(ctx context.Context, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, id := range ids {
		b.Delete(r.exportRef(id))
	}
	return b.Commit(ctx)
}

// DeletePrivate deletes up to limit docs of users/{uid}/private.
func (r *FirestoreRepo) DeletePrivate(ctx context.Context, uid string, limit int) (int, error) {
	snaps, err := r.userRef(uid).Collection(privateSubcollection).Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return 0, fmt.Errorf("identity: list private docs: %w", err)
	}
	if len(snaps) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, s := range snaps {
		b.Delete(s.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, err
	}
	return len(snaps), nil
}

// DeleteHandleIfOwned reads the handle and deletes it only when it is uid's, in one transaction.
func (r *FirestoreRepo) DeleteHandleIfOwned(ctx context.Context, handleLower, uid string) (HandleOutcome, error) {
	if handleLower == "" {
		return HandleAbsent, nil
	}
	outcome := HandleAbsent
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(r.handleRef(handleLower))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				outcome = HandleAbsent
				return nil
			}
			return fmt.Errorf("identity: get handle for deletion: %w", err)
		}
		var hd handleDoc
		if err := snap.DataTo(&hd); err != nil {
			return fmt.Errorf("identity: decode handle for deletion: %w", err)
		}
		if hd.UID != uid {
			outcome = HandleOwnerMismatch
			return nil
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Delete(r.handleRef(handleLower))
		if b.Err() != nil {
			return b.Err()
		}
		outcome = HandleDeleted
		return nil
	})
	if err != nil {
		return HandleAbsent, err
	}
	return outcome, nil
}

// DeleteQuotas deletes quotas/{uid}.
func (r *FirestoreRepo) DeleteQuotas(ctx context.Context, uid string) error {
	if _, err := quota.New(r.client).Ref(uid).Delete(ctx); err != nil {
		return fmt.Errorf("identity: delete quotas: %w", err)
	}
	return nil
}

// DeleteUserDoc: one transaction that reads users/{uid} and deletes it (a missing doc deletes nothing). The delete happens only
// while users/{uid} is still DELETING with deletionJob.seq == seq, the seq of the delivery that got here; anything
// else (a restore by hand, another delivery that advanced the job) is ErrJobConflict and deletes nothing.
func (r *FirestoreRepo) DeleteUserDoc(ctx context.Context, uid string, seq int64) error {
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		snap, err := tx.Get(r.userRef(uid))
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return nil // already gone: success
			}
			return fmt.Errorf("identity: get user for final delete: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for final delete: %w", err)
		}
		if p := d.toProfile(uid); p.Status != AccountStatusDeleting || p.DeletionJob == nil || p.DeletionJob.Seq != seq {
			return ErrJobConflict
		}
		b := store.NewFirestoreTxBatch(tx)
		b.Delete(r.userRef(uid))
		return b.Err()
	})
	if err != nil {
		if errors.Is(err, ErrJobConflict) {
			return ErrJobConflict
		}
		return logger.RedactErr(fmt.Errorf("identity: delete user doc: %w", err), uid)
	}
	return nil
}

// ListDeleting returns at most limit accounts. Ordered by (deletionJob.progressAt, __name__)
// ascending so a run walks the oldest-progress jobs first and a cursor continues after the last one (L-6); the
// no-progress threshold is in the query, so fresh jobs cost no read. Composite index users(status ASC,
// deletionJob.progressAt ASC) in firebase/firestore.indexes.json. Documents without deletionJob.progressAt (a
// DELETING flag set by hand) are not matched; the founder's tool drives those.
func (r *FirestoreRepo) ListDeleting(ctx context.Context, noProgressSince time.Time, after BackstopCursor, limit int) ([]Profile, error) {
	q := r.client.Collection(usersCollection).
		Where("status", "==", statusToString(AccountStatusDeleting)).
		Where("deletionJob.progressAt", "<=", noProgressSince).
		OrderBy("deletionJob.progressAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if !after.IsZero() {
		q = q.StartAfter(after.At, after.ID)
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("identity: list deleting accounts: %w", err)
	}
	out := make([]Profile, 0, len(snaps))
	for _, s := range snaps {
		var d userDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("identity: decode deleting account: %w", err)
		}
		out = append(out, d.toProfile(s.Ref.ID))
	}
	return out, nil
}

// ListPendingExports returns at most limit exports. Ordered by (createdAt, __name__) ascending
// with the age threshold in the query (L-6). Composite index exports(status ASC, createdAt ASC).
func (r *FirestoreRepo) ListPendingExports(ctx context.Context, createdBefore time.Time, after BackstopCursor, limit int) ([]ExportDoc, error) {
	q := r.client.Collection(exportsCollection).
		Where("status", "==", string(ExportPending)).
		Where("createdAt", "<=", createdBefore).
		OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if !after.IsZero() {
		q = q.StartAfter(after.At, after.ID)
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("identity: list pending exports: %w", err)
	}
	return decodeExports(snaps)
}

// isNotFound reports a repo ErrNotFound.
func isNotFound(err error) bool { return errors.Is(err, ErrNotFound) }
