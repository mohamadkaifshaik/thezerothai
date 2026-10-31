package lists

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Moderator is the operator-side seam of the platform hide (security review W5-17 M-4, plan W5-44): `opsctl lists hide|restore`
// is its only caller, there is no moderator RPC at Stage 0. *FirestoreRepo implements it, so the lists module stays the only
// writer of lists/{listId}.
type Moderator interface {
	// SetHidden sets or clears the platform `hidden` flag of one list. changed is false when the list already was in that
	// state (nothing written). ErrNotFound for a missing list. Reads 1, writes 1 (0 when unchanged).
	SetHidden(ctx context.Context, listID string, hidden bool, now time.Time) (changed bool, err error)
	// Get reads the list outside a transaction (1 read), for `--dry-run`.
	Get(ctx context.Context, id string) (List, error)
}

var _ Moderator = (*FirestoreRepo)(nil)

// SetHidden implements Moderator: one transaction that reads the list (1 read, ErrNotFound when it is gone) and, only when
// the flag differs, writes `hidden` and `updatedAt` through a field-level Update (1 write). It is never a Set, so a list
// deleted between the read and the commit stays deleted, and no other field (members, name, privacy) can be touched or
// reverted. Restore removes the field (`firestore.Delete`), so storage keeps its "absent means false" shape. Idempotent: a
// repeat is 1 read and 0 writes. The api instances keep serving a cached copy for at most cacheTTL (60 s, ADR-0030 D11);
// nothing here can reach their memory.
func (r *FirestoreRepo) SetHidden(ctx context.Context, listID string, hidden bool, now time.Time) (bool, error) {
	if r == nil || r.client == nil {
		return false, fmt.Errorf("lists: repo is not wired")
	}
	changed := false
	_, err := r.run(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		changed = false
		snap, err := tx.Get(r.ref(listID))
		budget.FromContext(ctx).AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return logger.RedactErr(fmt.Errorf("lists: get list: %w", err), listID)
		}
		var d listDoc
		if err := snap.DataTo(&d); err != nil {
			return logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), listID)
		}
		if d.Hidden == hidden {
			return nil
		}
		var hv any = firestore.Delete
		if hidden {
			hv = true
		}
		b := store.NewFirestoreTxBatch(tx, budget.FromContext(ctx))
		b.Update(r.ref(listID), []firestore.Update{{Path: "hidden", Value: hv}, {Path: "updatedAt", Value: now.UTC()}})
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
