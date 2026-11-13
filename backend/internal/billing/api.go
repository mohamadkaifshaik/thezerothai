// Package billing owns subscription policy and private provider account binding.
// It does not authorize purchases from client-reported tier or receipt data.
// Consumers must preserve their existing account, audience and rollout checks.
package billing

import (
	"context"
	"errors"
	"time"
)

type Tier string

const (
	TierFree    Tier = "free"
	TierPlus    Tier = "plus"
	TierPremium Tier = "premium"
)

const (
	PlusEntitlement    = "plus_access"
	PremiumEntitlement = "premium_access"
	ProEntitlement     = "dzeroth_pro"
	PolicyVersion      = 1
	MaxVerificationAge = 15 * time.Minute
	// ProviderRequestTimeout bounds the complete HTTP readback. Recovery needs
	// additional time to read and commit its private Firestore metadata.
	ProviderRequestTimeout = 10 * time.Second
	RecoveryAttemptBudget  = ProviderRequestTimeout + 2*time.Second
)

type Environment string

const (
	Sandbox    Environment = "SANDBOX"
	Production Environment = "PRODUCTION"
)

// Grant is a provider-verified access interval, not a renewal-intent flag.
// AccessUntil includes provider-confirmed grace when applicable.
type Grant struct {
	Entitlement string
	AccessUntil time.Time
}

// Snapshot must come from server-side verification. Do not deserialize a client
// request into this type. UID and CustomerID must match the private binding.
type Snapshot struct {
	UID         string
	CustomerID  string
	Environment Environment
	VerifiedAt  time.Time
	Grants      []Grant
}

var (
	ErrInvalidInput = errors.New("billing: invalid input")
	ErrUnavailable  = errors.New("billing: verified access unavailable")
	ErrOwnership    = errors.New("billing: account binding mismatch")
	ErrNotFound     = errors.New("billing: record not found")
)

// Binding contains private identifiers. Never include it in public profiles,
// author snapshots, logs or analytics. Environment isolation belongs to storage.
type Binding struct {
	UID         string
	CustomerID  string
	Environment Environment
	CreatedAt   time.Time
}

// BindingStore atomically allocates a candidate only if the owner has no
// binding. It must check the account is active in that transaction, reject
// customer-ID collisions and return the original binding on every replay.
// Implementations must not recreate deleted users from a provider notification.
type BindingStore interface {
	EnsureBinding(context.Context, Binding) (Binding, error)
}

// Provider is called only by authenticated server reconciliation. Its customer
// ID comes from the binding store, never from an arbitrary caller-supplied UID.
type Provider interface {
	GetCustomer(context.Context, Binding) (Snapshot, error)
}
