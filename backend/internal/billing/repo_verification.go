package billing

import (
	"context"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Verification metadata lives on the private binding so paired erasure also
// removes its access projection. These operations require no collection scans.
type verificationDocument struct {
	bindingDocument
	Generation int64    `firestore:"verificationGeneration"`
	Snapshot   Snapshot `firestore:"verifiedSnapshot"`
}

func (r *FirestoreBindings) readVerification(ctx context.Context, tx *firestore.Transaction, uid string) (verificationDocument, error) {
	var d verificationDocument
	u, err := tx.Get(r.client.Collection("users").Doc(uid))
	if err != nil {
		return d, ErrUnavailable
	}
	state, err := u.DataAt("status")
	if err != nil || state != "ACTIVE" {
		return d, ErrOwnership
	}
	s, err := tx.Get(r.client.Collection("billingCustomers").Doc(uid))
	if status.Code(err) == codes.NotFound {
		return d, ErrNotFound
	}
	if err != nil {
		return d, ErrUnavailable
	}
	if s.DataTo(&d) != nil {
		return d, ErrUnavailable
	}
	b := Binding{d.UID, d.CustomerID, d.Environment, d.CreatedAt}
	if !validBinding(b) || b.UID != uid {
		return d, ErrOwnership
	}
	owner, err := tx.Get(r.client.Collection("billingCustomerOwners").Doc(bindingKey(b.Environment, b.CustomerID)))
	if err != nil {
		return d, ErrOwnership
	}
	v, err := owner.DataAt("uid")
	if err != nil || v != uid {
		return d, ErrOwnership
	}
	return d, nil
}

func (r *FirestoreBindings) LookupBinding(ctx context.Context, uid string) (Binding, error) {
	if r.client == nil || !validUID(uid) {
		return Binding{}, ErrInvalidInput
	}
	var b Binding
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		d, err := r.readVerification(ctx, tx, uid)
		if err != nil {
			return err
		}
		b = Binding{d.UID, d.CustomerID, d.Environment, d.CreatedAt}
		return nil
	})
	if err == ErrNotFound {
		return Binding{}, ErrNotFound
	}
	if err != nil {
		return Binding{}, ErrUnavailable
	}
	return b, nil
}

func (r *FirestoreBindings) BeginVerification(ctx context.Context, uid string) (Binding, int64, error) {
	if r.client == nil || !validUID(uid) {
		return Binding{}, 0, ErrInvalidInput
	}
	var b Binding
	var generation int64
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		d, err := r.readVerification(ctx, tx, uid)
		if err != nil {
			return err
		}
		if d.Generation < 0 || d.Generation == 1<<63-1 {
			return ErrUnavailable
		}
		generation = d.Generation + 1
		b = Binding{d.UID, d.CustomerID, d.Environment, d.CreatedAt}
		return tx.Update(r.client.Collection("billingCustomers").Doc(uid), []firestore.Update{{Path: "verificationGeneration", Value: generation}})
	})
	if err != nil {
		return Binding{}, 0, ErrUnavailable
	}
	return b, generation, nil
}

func (r *FirestoreBindings) CommitVerification(ctx context.Context, b Binding, generation int64, s Snapshot) error {
	if r.client == nil || !validBinding(b) || generation <= 0 {
		return ErrInvalidInput
	}
	// Policy validation belongs here as well as in Reconciler: storage must not
	// become an alternate path for a mismatched identity or environment.
	if _, err := EffectiveTier(b, s, s.VerifiedAt); err != nil {
		return err
	}
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		d, err := r.readVerification(ctx, tx, b.UID)
		if err != nil {
			return err
		}
		if d.Generation != generation || d.CustomerID != b.CustomerID || d.Environment != b.Environment || !d.CreatedAt.Equal(b.CreatedAt) {
			return ErrOwnership
		}
		return tx.Update(r.client.Collection("billingCustomers").Doc(b.UID), []firestore.Update{{Path: "verifiedSnapshot", Value: s}})
	})
	if err != nil {
		return ErrUnavailable
	}
	return nil
}
