// purge.go is the right-to-delete path of users/{uid}/keyDevices and its keyPackages pools. Deleting users/{uid} does not
// delete subcollections, so the `keys` account-deletion step (Eraser, registered BeforeIdentity last in
// apiserver/lifecycle_keys.go) removes them: one device per call, its pool in pages of purgePage and then the device
// document. Devices are found by listing the collection's document references INCLUDING missing documents, so pool
// documents left under a device document that a concurrent Remove already deleted are found and erased too, with no index
// and no collection-group query. Once no device is left, a second phase erases users/{uid}/keyDeviceRemovals (the removed
// marks) in pages of purgePage, orphan marks included. Not flag-gated: documents outlive the flag.
package keys

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"google.golang.org/api/iterator"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// purgePage is the most pool documents one batch deletes.
	purgePage = 100
	// maxPagesPerRun bounds one eraser call; a device with more pages continues on the next call.
	maxPagesPerRun = 50
)

// PagePurger is the storage the eraser needs (FirestoreRepo in production).
type PagePurger interface {
	// FirstDeviceID returns the id of one device of uid that still has a document or pool documents (a "missing" device
	// document with children counts), or found=false when none is left. One list request of page size 1.
	FirstDeviceID(ctx context.Context, uid string) (id string, found bool, err error)
	// PurgePoolPage deletes up to limit pool documents of the device in one atomic batch and reports how many (query with
	// a Limit; deleted documents leave the next page, so repeating the call resumes).
	PurgePoolPage(ctx context.Context, uid, deviceID string, limit int) (deleted int, err error)
	// DeleteDevice deletes the device document (a missing document is success).
	DeleteDevice(ctx context.Context, uid, deviceID string) error
	// PurgeRemovalMarksPage deletes up to limit removed marks of uid in one batch and reports how many (a query with a
	// Limit; repeating the call resumes).
	PurgeRemovalMarksPage(ctx context.Context, uid string, limit int) (deleted int, err error)
}

var _ PagePurger = (*FirestoreRepo)(nil)

// FirstDeviceID implements PagePurger.
func (r *FirestoreRepo) FirstDeviceID(ctx context.Context, uid string) (string, bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	it := r.devices(uid).DocumentRefs(ctx)
	it.PageInfo().MaxSize = 1
	ref, err := it.Next()
	if errors.Is(err, iterator.Done) {
		return "", false, nil
	}
	if err != nil {
		return "", false, logger.RedactErr(fmt.Errorf("keys: purge %s: list devices: %w", logger.HashUID(uid), err), uid)
	}
	return ref.ID, true, nil
}

// PurgePoolPage implements PagePurger. Reads: one per pool document (minimum 1); deletes: one per document.
func (r *FirestoreRepo) PurgePoolPage(ctx context.Context, uid, deviceID string, limit int) (int, error) {
	snaps, err := r.poolCol(uid, deviceID).Select().Limit(min(max(limit, 1), purgePage)).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("keys: purge %s: pool query: %w", logger.HashUID(uid), err), uid, deviceID)
	}
	if len(snaps) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, s := range snaps {
		b.Delete(s.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, logger.RedactErr(fmt.Errorf("keys: purge %s: pool delete: %w", logger.HashUID(uid), err), uid, deviceID)
	}
	return len(snaps), nil
}

// DeleteDevice implements PagePurger.
func (r *FirestoreRepo) DeleteDevice(ctx context.Context, uid, deviceID string) error {
	if _, err := r.deviceRef(uid, deviceID).Delete(ctx); err != nil {
		return logger.RedactErr(fmt.Errorf("keys: purge %s: delete device: %w", logger.HashUID(uid), err), uid, deviceID)
	}
	return nil
}

// Checkpoint resumes Eraser.PurgeUser. It is the step's own type: the step name is persisted in deletionJob.step. Erased
// devices drop out of the next listing, so the purge is self-resuming and the fields are for logging and inspection.
type Checkpoint struct {
	// Devices is how many devices have been fully erased.
	Devices int `json:"devices,omitempty"`
	// LastDevice is the id of the last device fully erased.
	LastDevice string `json:"lastDevice,omitempty"`
	// Marks counts the removed marks erased (the second phase, after the last device). A statistic for the log only: it
	// can undercount after a failed page (see purgeMarks), and nothing reads it to decide what to delete.
	Marks int `json:"marks,omitempty"`
}

// PurgeRemovalMarksPage implements PagePurger: one query (Select, Limit at most purgePage; no index) and one batch delete.
// Reads: one per mark (minimum 1); deletes: one per mark.
func (r *FirestoreRepo) PurgeRemovalMarksPage(ctx context.Context, uid string, limit int) (int, error) {
	snaps, err := r.marks(uid).Select().Limit(min(max(limit, 1), purgePage)).Documents(ctx).GetAll()
	if err != nil {
		return 0, logger.RedactErr(fmt.Errorf("keys: purge %s: mark query: %w", logger.HashUID(uid), err), uid)
	}
	if len(snaps) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	redact := make([]string, 0, len(snaps)+1)
	redact = append(redact, uid)
	for _, s := range snaps {
		b.Delete(s.Ref)
		redact = append(redact, s.Ref.ID) // the doc id is a device id: never in an error
	}
	if err := b.Commit(ctx); err != nil {
		return 0, logger.RedactErr(fmt.Errorf("keys: purge %s: mark delete: %w", logger.HashUID(uid), err), redact...)
	}
	return len(snaps), nil
}

// Eraser is the `keys` account-deletion step.
type Eraser struct {
	repo PagePurger
}

// NewEraser builds the step on a PagePurger (FirestoreRepo in production).
func NewEraser(repo PagePurger) *Eraser { return &Eraser{repo: repo} }

// PurgeUser erases at most one device per call (its pool in pages, then the device document). Once no device is left it
// erases the removed marks (phase 2: up to maxPagesPerRun pages of purgePage per call) and reports the step finished when a
// page comes back short. The marks go last so a device erased in phase 1 cannot be re-registered in between; once the
// account is gone they protect nothing. An account with no devices and no marks is done in one call without a write; a
// repeat after completion does the same.
func (e *Eraser) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	id, found, err := e.repo.FirstDeviceID(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	if !found {
		return e.purgeMarks(ctx, uid, cp)
	}
	for range maxPagesPerRun {
		n, err := e.repo.PurgePoolPage(ctx, uid, id, purgePage)
		if err != nil {
			return cp, false, err
		}
		if n < purgePage {
			if err := e.repo.DeleteDevice(ctx, uid, id); err != nil {
				return cp, false, err
			}
			next := Checkpoint{Devices: cp.Devices + 1, LastDevice: id}
			slog.InfoContext(ctx, "keys_purge", "uid_hash", logger.HashUID(uid), "devices_total", next.Devices)
			return next, false, nil
		}
	}
	return cp, false, nil // a long pool: the next call lists the same device again and continues
}

// purgeMarks is phase 2. Correctness never depends on the checkpoint: each call lists what is left, and deleted marks
// are gone from the next listing, so the step is self-resuming. Checkpoint.Marks is a statistic for the log only, and
// not exact: a failed page returns the checkpoint this call was given, so marks deleted earlier in the same call are not
// counted (they are deleted all the same).
func (e *Eraser) purgeMarks(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	next := cp
	for range maxPagesPerRun {
		n, err := e.repo.PurgeRemovalMarksPage(ctx, uid, purgePage)
		if err != nil {
			return cp, false, err
		}
		next.Marks += n
		if n < purgePage {
			if next.Marks != cp.Marks {
				slog.InfoContext(ctx, "keys_purge_marks", "uid_hash", logger.HashUID(uid), "marks_total", next.Marks)
			}
			return next, true, nil
		}
	}
	return next, false, nil // a long list: the next call continues
}
