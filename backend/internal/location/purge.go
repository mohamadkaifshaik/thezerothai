// purge.go is the right-to-delete path of users/{uid}/locationArea and users/{uid}/locationConsents. Deleting users/{uid}
// does not delete its subcollections, so the `location` account-deletion step (Eraser, registered BeforeIdentity last in
// apiserver/lifecycle_location.go) deletes them: (1) the area doc, then (2) the consent log, purgePage records per batch,
// in id order from the checkpoint. Re-runs are idempotent. Not flag-gated: documents outlive the flag.
package location

import (
	"context"
	"fmt"
	"log/slog"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// purgePage is the consent page of the erase step (one batch).
const purgePage = 400

// Purger is the storage side of the eraser (FirestoreRepo in production).
type Purger interface {
	// DeleteArea deletes uid's area doc (a missing doc is success).
	DeleteArea(ctx context.Context, uid string) error
	// PurgeConsentsPage deletes up to limit of uid's consent records after the id `after`, in id order, in one batch, and
	// reports the last id deleted and how many.
	PurgeConsentsPage(ctx context.Context, uid, after string, limit int) (lastID string, deleted int, err error)
}

var _ Purger = (*FirestoreRepo)(nil)

// DeleteArea implements Purger.
func (r *FirestoreRepo) DeleteArea(ctx context.Context, uid string) error {
	if _, err := r.areaRef(uid).Delete(ctx); err != nil {
		return logger.RedactErr(fmt.Errorf("location: purge area %s: %w", logger.HashUID(uid), err), uid)
	}
	return nil
}

// PurgeConsentsPage implements Purger. Reads: one per document (minimum 1).
func (r *FirestoreRepo) PurgeConsentsPage(ctx context.Context, uid, after string, limit int) (string, int, error) {
	q := r.consents(uid).OrderBy(firestore.DocumentID, firestore.Asc).Select()
	if after != "" {
		q = q.StartAfter(r.consents(uid).Doc(after))
	}
	docs, err := q.Limit(min(max(limit, 1), purgePage)).Documents(ctx).GetAll()
	if err != nil {
		return "", 0, logger.RedactErr(fmt.Errorf("location: purge consents %s: query: %w", logger.HashUID(uid), err), uid)
	}
	if len(docs) == 0 {
		return after, 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return "", 0, logger.RedactErr(fmt.Errorf("location: purge consents %s: %w", logger.HashUID(uid), err), uid)
	}
	return docs[len(docs)-1].Ref.ID, len(docs), nil
}

// Checkpoint resumes Eraser.PurgeUser. It is the step's own type: the step name is persisted in deletionJob.step.
type Checkpoint struct {
	// Phase 0 deletes the area doc; phase 1 pages the consent log.
	Phase int `json:"phase"`
	// AfterID is the last consent id deleted in phase 1.
	AfterID string `json:"afterId"`
	// Deleted is the running count of consent records.
	Deleted int `json:"deleted"`
}

// Eraser is the `location` account-deletion step.
type Eraser struct {
	repo Purger
}

// NewEraser builds the step on a Purger.
func NewEraser(repo Purger) *Eraser { return &Eraser{repo: repo} }

// PurgeUser runs one unit: in phase 0 the area doc (then phase 1 in the same call), in phase 1 one consent page. done is
// true on a short page (including the empty page of an account with none).
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if cp.Phase == 0 {
		if err := e.repo.DeleteArea(ctx, uid); err != nil {
			return cp, false, err
		}
		cp = Checkpoint{Phase: 1}
	}
	last, n, err := e.repo.PurgeConsentsPage(ctx, uid, cp.AfterID, purgePage)
	if err != nil {
		return cp, false, err
	}
	next := Checkpoint{Phase: 1, AfterID: last, Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "location_purge", "uid_hash", logger.HashUID(uid), "consents", n, "deleted_total", next.Deleted)
	}
	return next, n < purgePage, nil
}
