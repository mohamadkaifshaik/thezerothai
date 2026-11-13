package billing

import (
	"context"
	"time"
)

// ReconciliationStore fences every readback. Commit must atomically verify the
// active account, unchanged binding and generation before persisting a snapshot.
// A later attempt or webhook invalidation makes an earlier commit fail closed.
type ReconciliationStore interface {
	BeginVerification(context.Context, string) (Binding, int64, error)
	CommitVerification(context.Context, Binding, int64, Snapshot) error
}

type Reconciler struct {
	store    ReconciliationStore
	provider Provider
	now      func() time.Time
}

func NewReconciler(store ReconciliationStore, provider Provider, now func() time.Time) (*Reconciler, error) {
	if store == nil || provider == nil {
		return nil, ErrInvalidInput
	}
	if now == nil {
		now = time.Now
	}
	return &Reconciler{store: store, provider: provider, now: now}, nil
}

// Refresh does not allocate a binding. Notifications cannot recreate an account.
func (r *Reconciler) Refresh(ctx context.Context, uid string) (Snapshot, error) {
	if !validUID(uid) {
		return Snapshot{}, ErrInvalidInput
	}
	b, generation, err := r.store.BeginVerification(ctx, uid)
	if err != nil {
		return Snapshot{}, err
	}
	if !validBinding(b) || b.UID != uid || generation <= 0 {
		return Snapshot{}, ErrOwnership
	}
	snapshot, err := r.provider.GetCustomer(ctx, b)
	if err != nil {
		return Snapshot{}, err
	}
	if _, err = EffectiveTier(b, snapshot, r.now()); err != nil {
		return Snapshot{}, err
	}
	if err = r.store.CommitVerification(ctx, b, generation, snapshot); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}
