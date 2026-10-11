// repo_moderation.go is the one write path moderation uses on users/{uid}: moving an account between ACTIVE and
// SUSPENDED (ADR-0016 D4, P7). It changes status and updatedAt only, through identity's own repo, and never
// touches Firebase Auth (IAM control C2: authadmin_guard_test.go). The status interceptor and Directory read the
// status from users/{uid}, so a suspended caller gets ACCOUNT_RESTRICTED once the 60 s identity cache expires.
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// ErrStatusConflict is returned by SetAccountStatus when the account is in neither the expected nor the target
// status (for example DELETING): a moderator action must never resurrect or override a deletion.
var ErrStatusConflict = errors.New("identity: account status does not allow this change")

// SetAccountStatus moves users/{uid} from `from` to `to`, where the pair is ACTIVE/SUSPENDED in either direction.
// It returns changed=false (0 writes) when the account is already in `to`. Any other current status is
// ErrStatusConflict; a missing user is ErrNotFound. One transaction: 1 read, 1 write (0 on no-op).
func (r *FirestoreRepo) SetAccountStatus(ctx context.Context, uid string, from, to AccountStatus, now time.Time) (changed bool, err error) {
	valid := (from == AccountStatusActive && to == AccountStatusSuspended) ||
		(from == AccountStatusSuspended && to == AccountStatusActive)
	if !valid {
		return false, fmt.Errorf("identity: unsupported status change %d -> %d", from, to)
	}
	_, err = store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		changed = false
		counter := budget.FromContext(ctx)
		snap, err := tx.Get(r.userRef(uid))
		counter.AddReads(1)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			return fmt.Errorf("identity: get user for status change: %w", err)
		}
		var d userDoc
		if err := snap.DataTo(&d); err != nil {
			return fmt.Errorf("identity: decode user for status change: %w", err)
		}
		switch cur := statusFromString(d.Status); cur {
		case to:
			return nil
		case from:
		default:
			return ErrStatusConflict
		}
		b := store.NewFirestoreTxBatch(tx, counter)
		b.Update(r.userRef(uid), []firestore.Update{
			{Path: "status", Value: statusToString(to)},
			{Path: "updatedAt", Value: now},
		})
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
