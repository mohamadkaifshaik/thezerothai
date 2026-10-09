package identity

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	exportsCollection    = "exports"
	privateSubcollection = "private"
)

var _ LifecycleRepo = (*FirestoreRepo)(nil)

// exportDocFS is the exports/{id} shape (ADR-0003, ADR-0011). expireAt is the Firestore TTL field.
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

func addReads(ctx context.Context, docs int) {
	if docs < 1 {
		docs = 1
	}
	budget.FromContext(ctx).AddReads(int64(docs))
}

// BeginDeletion: 1 read, 1 write (replay: 1 read, 0 writes).
func (r *FirestoreRepo) BeginDeletion(ctx context.Context, uid string, now time.Time) (DeletionStart, error) {
	var out DeletionStart
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
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
		// ACTIVE, SUSPENDED (ADR-0011 Q3), or DELETING set by hand without job state: (re)start the job.
		job := DeletionJob{Seq: 0, ProgressAt: now}
		b := store.NewFirestoreTxBatch(tx, counter)
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

// GetJobState: 1 read.
func (r *FirestoreRepo) GetJobState(ctx context.Context, uid string) (Profile, time.Time, error) {
	snap, err := r.userRef(uid).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
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

// SaveJobState: 1 write.
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
	budget.FromContext(ctx).AddWrites(1)
	return nil
}

// CreateExport matches RequestAccountExport's documented budget (proto: reads 2/1 with the interceptor, writes 2;
// replay reads 3/2, writes 0): the first request reads quotas/{uid} (1 read) and creates the PENDING doc and the
// incremented quota in one atomic commit (2 writes). A replay is told apart without a second probe on the first
// request: if the daily quota is already used up, the exports doc is read (the replay of the request that used it,
// or QUOTA_EXCEEDED); if quota is left, the Create fails with AlreadyExists, which rolls the whole commit back (the
// quota is not incremented), and the doc is read after it. Either way a replay writes nothing.
func (r *FirestoreRepo) CreateExport(ctx context.Context, p CreateExportParams) (ExportDoc, bool, error) {
	var out ExportDoc
	replay := false
	qs := quota.New(r.client)
	// store.RunTransaction counts each attempt in its own scratch counter and folds the writes in only when the
	// commit succeeds: a commit that rolls back (AlreadyExists, below) wrote nothing.
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		rec, err := qs.Get(ctx, tx, p.UID)
		if err != nil {
			return fmt.Errorf("identity: export quota: %w", err)
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		if qerr := quota.CheckAndReserve(b, qs.Ref(p.UID), rec, quota.Exports, p.ExportsPerDay); qerr != nil {
			// Over the daily quota: only the request that used it up may be replayed.
			snap, gerr := tx.Get(r.exportRef(p.ID))
			counter.AddReads(1)
			switch {
			case gerr == nil:
				doc, derr := decodeExport(snap)
				if derr != nil {
					return derr
				}
				out, replay = doc, true
				return nil
			case status.Code(gerr) == codes.NotFound:
				return qerr
			default:
				return fmt.Errorf("identity: get export: %w", gerr)
			}
		}
		doc := exportDocFS{UID: p.UID, Status: string(ExportPending), ObjectPath: p.ObjectPath, CreatedAt: p.Now, ExpireAt: p.Now.Add(p.Retention)}
		b.Create(r.exportRef(p.ID), doc)
		if b.Err() != nil {
			return b.Err()
		}
		out, replay = doc.toDomain(p.ID, time.Time{}), false
		return nil
	})
	if status.Code(err) == codes.AlreadyExists {
		// A replay with quota left (for example the next IST day): the commit rolled back, nothing was written.
		doc, gerr := r.GetExport(ctx, p.ID)
		if gerr != nil {
			return ExportDoc{}, false, gerr
		}
		return doc, true, nil
	}
	if err != nil {
		return ExportDoc{}, false, err
	}
	return out, replay, nil
}

// GetExport: 1 read.
func (r *FirestoreRepo) GetExport(ctx context.Context, id string) (ExportDoc, error) {
	snap, err := r.exportRef(id).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		if status.Code(err) == codes.NotFound {
			return ExportDoc{}, ErrNotFound
		}
		return ExportDoc{}, fmt.Errorf("identity: get export: %w", err)
	}
	return decodeExport(snap)
}

// SetExportStatus: 1 write.
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
	budget.FromContext(ctx).AddWrites(1)
	return nil
}

// ClaimExport: 1 write. The status stays PENDING; only leaseUntil changes, under the read's update time.
func (r *FirestoreRepo) ClaimExport(ctx context.Context, id string, updateTime, leaseUntil time.Time) (time.Time, error) {
	res, err := r.exportRef(id).Update(ctx, []firestore.Update{{Path: "leaseUntil", Value: leaseUntil}}, firestore.LastUpdateTime(updateTime))
	if err != nil {
		switch status.Code(err) {
		case codes.FailedPrecondition, codes.NotFound:
			return time.Time{}, ErrJobConflict
		}
		return time.Time{}, fmt.Errorf("identity: claim export: %w", err)
	}
	budget.FromContext(ctx).AddWrites(1)
	return res.UpdateTime, nil
}

// ListExports: reads = docs returned (minimum 1). The uid equality uses the automatic single-field index.
func (r *FirestoreRepo) ListExports(ctx context.Context, uid string, limit int) ([]ExportDoc, error) {
	snaps, err := r.client.Collection(exportsCollection).Where("uid", "==", uid).Limit(limit).Documents(ctx).GetAll()
	addReads(ctx, len(snaps))
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
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, id := range ids {
		b.Delete(r.exportRef(id))
	}
	return b.Commit(ctx)
}

// DeletePrivate: reads = docs returned (minimum 1), deletes = docs.
func (r *FirestoreRepo) DeletePrivate(ctx context.Context, uid string, limit int) (int, error) {
	snaps, err := r.userRef(uid).Collection(privateSubcollection).Limit(limit).Documents(ctx).GetAll()
	addReads(ctx, len(snaps))
	if err != nil {
		return 0, fmt.Errorf("identity: list private docs: %w", err)
	}
	if len(snaps) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, s := range snaps {
		b.Delete(s.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, err
	}
	return len(snaps), nil
}

// DeleteHandleIfOwned: 1 read, at most 1 delete, in one transaction.
func (r *FirestoreRepo) DeleteHandleIfOwned(ctx context.Context, handleLower, uid string) (HandleOutcome, error) {
	if handleLower == "" {
		return HandleAbsent, nil
	}
	outcome := HandleAbsent
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.handleRef(handleLower))
		counter.AddReads(1)
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
		b := store.NewFirestoreTxBatch(tx, counter)
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

// DeleteQuotas: 1 delete.
func (r *FirestoreRepo) DeleteQuotas(ctx context.Context, uid string) error {
	if _, err := quota.New(r.client).Ref(uid).Delete(ctx); err != nil {
		return fmt.Errorf("identity: delete quotas: %w", err)
	}
	budget.FromContext(ctx).AddDeletes(1)
	return nil
}

// DeleteUserDoc: one transaction, 1 read + 1 delete (a missing doc: 1 read, no delete). The delete happens only
// while users/{uid} is still DELETING with deletionJob.seq == seq, the seq of the delivery that got here; anything
// else (a restore by hand, another delivery that advanced the job) is ErrJobConflict and deletes nothing.
func (r *FirestoreRepo) DeleteUserDoc(ctx context.Context, uid string, seq int64) error {
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
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
		b := store.NewFirestoreTxBatch(tx, counter)
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

// ListDeleting: reads = docs returned (minimum 1), at most limit. Ordered by (deletionJob.progressAt, __name__)
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
	addReads(ctx, len(snaps))
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

// ListPendingExports: reads = docs returned (minimum 1), at most limit. Ordered by (createdAt, __name__) ascending
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
	addReads(ctx, len(snaps))
	if err != nil {
		return nil, fmt.Errorf("identity: list pending exports: %w", err)
	}
	return decodeExports(snaps)
}

// isNotFound reports a repo ErrNotFound.
func isNotFound(err error) bool { return errors.Is(err, ErrNotFound) }
