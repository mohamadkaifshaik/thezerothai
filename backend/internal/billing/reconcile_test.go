package billing

import (
	"context"
	"errors"
	"testing"
	"time"
)

type reconciliationFake struct {
	binding Binding
	commits int
	reject  bool
}

func (s *reconciliationFake) BeginVerification(context.Context, string) (Binding, int64, error) {
	return s.binding, 1, nil
}
func (s *reconciliationFake) CommitVerification(_ context.Context, b Binding, g int64, snapshot Snapshot) error {
	s.commits++
	if s.reject {
		return ErrUnavailable
	}
	return nil
}

type providerFunc func(context.Context, Binding) (Snapshot, error)

func (f providerFunc) GetCustomer(c context.Context, b Binding) (Snapshot, error) { return f(c, b) }

func TestReconcileRejectsUnverifiedAndFencedResults(t *testing.T) {
	b := testBinding()
	now := b.CreatedAt.Add(time.Hour)
	for _, tc := range []struct {
		name                   string
		providerErr, commitErr bool
		wrongOwner, stale      bool
		wantCommits            int
	}{
		{name: "valid", wantCommits: 1},
		{name: "provider failure", providerErr: true},
		{name: "wrong owner", wrongOwner: true},
		{name: "stale", stale: true},
		{name: "newer generation wins", commitErr: true, wantCommits: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store := &reconciliationFake{binding: b, reject: tc.commitErr}
			provider := providerFunc(func(context.Context, Binding) (Snapshot, error) {
				if tc.providerErr {
					return Snapshot{}, ErrUnavailable
				}
				s := Snapshot{UID: b.UID, CustomerID: b.CustomerID, Environment: b.Environment, VerifiedAt: now}
				if tc.wrongOwner {
					s.UID = "other"
				}
				if tc.stale {
					s.VerifiedAt = now.Add(-MaxVerificationAge)
				}
				return s, nil
			})
			r, _ := NewReconciler(store, provider, func() time.Time { return now })
			_, err := r.Refresh(context.Background(), b.UID)
			wantError := tc.providerErr || tc.commitErr || tc.wrongOwner || tc.stale
			if (err != nil) != wantError || store.commits != tc.wantCommits {
				t.Fatalf("error=%v commits=%d", err, store.commits)
			}
			if tc.providerErr && !errors.Is(err, ErrUnavailable) {
				t.Fatal("provider error lost")
			}
		})
	}
}
