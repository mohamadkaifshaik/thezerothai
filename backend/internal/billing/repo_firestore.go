package billing

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// FirestoreBindings stores private binding pairs and their verification metadata.
// Identity operations use point reads; webhook recovery uses a bounded query.
type FirestoreBindings struct{ client *firestore.Client }

func NewFirestoreBindings(client *firestore.Client) *FirestoreBindings {
	return &FirestoreBindings{client: client}
}

type bindingDocument struct {
	UID         string      `firestore:"uid"`
	CustomerID  string      `firestore:"customerId"`
	Environment Environment `firestore:"environment"`
	CreatedAt   time.Time   `firestore:"createdAt"`
}

func bindingKey(env Environment, customer string) string {
	h := sha256.Sum256([]byte(string(env) + ":" + customer))
	return hex.EncodeToString(h[:])
}

func (r *FirestoreBindings) EnsureBinding(ctx context.Context, candidate Binding) (Binding, error) {
	if r.client == nil || !validBinding(candidate) {
		return Binding{}, ErrInvalidInput
	}
	var result Binding
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		// Recheck the account even on replay. A deletion/suspension racing this
		// transaction must prevent creation of a fresh purchase identity.
		user, err := tx.Get(r.client.Collection("users").Doc(candidate.UID))
		if status.Code(err) == codes.NotFound {
			return ErrOwnership
		}
		if err != nil {
			return err
		}
		accountStatus, err := user.DataAt("status")
		if err != nil || accountStatus != "ACTIVE" {
			return ErrOwnership
		}
		ref := r.client.Collection("billingCustomers").Doc(candidate.UID)
		snap, err := tx.Get(ref)
		if err == nil {
			var d bindingDocument
			if err := snap.DataTo(&d); err != nil {
				return ErrOwnership
			}
			b := Binding(d)
			if !validBinding(b) || b.UID != candidate.UID || b.Environment != candidate.Environment {
				return ErrOwnership
			}
			reverse, err := tx.Get(r.client.Collection("billingCustomerOwners").Doc(bindingKey(b.Environment, b.CustomerID)))
			if err != nil {
				return ErrOwnership
			}
			owner, err := reverse.DataAt("uid")
			if err != nil || owner != b.UID {
				return ErrOwnership
			}
			result = b
			return nil
		}
		if status.Code(err) != codes.NotFound {
			return err
		}
		reverse := r.client.Collection("billingCustomerOwners").Doc(bindingKey(candidate.Environment, candidate.CustomerID))
		if _, err := tx.Get(reverse); status.Code(err) != codes.NotFound {
			if err != nil {
				return err
			}
			return ErrOwnership
		}
		d := bindingDocument(candidate)
		if err := tx.Create(ref, d); err != nil {
			return err
		}
		if err := tx.Create(reverse, map[string]any{"uid": candidate.UID}); err != nil {
			return err
		}
		result = candidate
		return nil
	})
	if err != nil {
		if err == ErrOwnership {
			return Binding{}, err
		}
		// Firestore errors may contain document paths. Never expose them to a
		// transport/logger without a separate redacted diagnostic path.
		return Binding{}, ErrUnavailable
	}
	return result, nil
}

// Name/Run/WriteSection satisfy identity lifecycle seams without importing it.
func (*FirestoreBindings) Name() string { return "billing_bindings" }

func (r *FirestoreBindings) Run(ctx context.Context, uid string, _ []byte) ([]byte, bool, error) {
	if r.client == nil || !validUID(uid) {
		return nil, false, ErrInvalidInput
	}
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		ref := r.client.Collection("billingCustomers").Doc(uid)
		snap, err := tx.Get(ref)
		if status.Code(err) == codes.NotFound {
			return nil
		}
		if err != nil {
			return err
		}
		var d bindingDocument
		if err := snap.DataTo(&d); err != nil {
			return err
		}
		b := Binding(d)
		if !validBinding(b) || b.UID != uid {
			return ErrOwnership
		}
		reverse := r.client.Collection("billingCustomerOwners").Doc(bindingKey(b.Environment, b.CustomerID))
		owner, err := tx.Get(reverse)
		if err == nil {
			v, e := owner.DataAt("uid")
			if e != nil || v != uid {
				return ErrOwnership
			}
		} else if status.Code(err) != codes.NotFound {
			return err
		}
		if err := tx.Delete(reverse); err != nil {
			return err
		}
		return tx.Delete(ref)
	})
	if err != nil {
		return nil, false, ErrUnavailable
	}
	return nil, true, nil
}

// Export deliberately omits the private provider ID and reverse mapping.
func (r *FirestoreBindings) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	if r.client == nil || !validUID(uid) {
		return ErrInvalidInput
	}
	snap, err := r.client.Collection("billingCustomers").Doc(uid).Get(ctx)
	if status.Code(err) == codes.NotFound {
		_, err = io.WriteString(w, "null")
		return err
	}
	if err != nil {
		return ErrUnavailable
	}
	var d bindingDocument
	if err := snap.DataTo(&d); err != nil {
		return ErrUnavailable
	}
	if d.UID != uid {
		return ErrOwnership
	}
	return json.NewEncoder(w).Encode(struct {
		CreatedAt time.Time `json:"createdAt"`
	}{d.CreatedAt})
}
