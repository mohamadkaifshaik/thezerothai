package location

import (
	"context"
	"errors"
	"time"
)

// Stored values of users/{uid}/locationArea/current and users/{uid}/locationConsents/{id} (design section 4).
const (
	// PurposePlansNearby is the one purpose of P1/P2: see public plans in my chosen area (Explore Nearby).
	PurposePlansNearby = "plans_nearby"
	// ActionGranted and ActionWithdrawn are the consent record actions.
	ActionGranted   = "granted"
	ActionWithdrawn = "withdrawn"
)

// StoredArea is the caller's area doc. No TTL: it lives until ClearArea or account erasure.
type StoredArea struct {
	AreaID             string
	Purposes           []string
	ConsentCopyVersion int
	AdultConfirmedAt   time.Time
	ConsentedAt        time.Time
	UpdatedAt          time.Time
}

// ConsentRecord is one append-only consent log entry. It holds no area id (data minimisation).
type ConsentRecord struct {
	ID             string
	Purpose        string
	Action         string
	CopyVersion    int
	AdultConfirmed bool
	At             time.Time
}

// State is what the repo reads for the settings answer: the area doc, or (only when there is none) the latest consent
// record. Both nil: the user never consented.
type State struct {
	Area   *StoredArea
	Latest *ConsentRecord
}

// Grant is the consent a SetArea request carries (ConsentGrant).
type Grant struct {
	CopyVersion    int
	AdultConfirmed bool
}

// Outcome is what a write did.
type Outcome int

const (
	// Unchanged wrote only the idempotency doc.
	Unchanged Outcome = iota
	// Written changed the area doc and/or appended a consent record.
	Written
	// Replayed answered a retry of an earlier request with the same key and body; nothing was written.
	Replayed
)

// SetParams is one SetArea transaction.
type SetParams struct {
	UID string
	// IdemKey is idempotency.Key(uid, rpc, key); RequestHash the canonical body hash.
	IdemKey, RequestHash string
	AreaID               string
	// ConsentID is the snowflake id of the GRANTED record, used only when the transaction grants.
	ConsentID string
	// Grant is the request's consent (nil when absent).
	Grant *Grant
	// MinCopyVersion is LOCATION_CONSENT_MIN_COPY_VERSION; ConsentsPerDay is LOCATION_CONSENT_CHANGES_PER_DAY.
	MinCopyVersion, ConsentsPerDay int
	Now                            time.Time
}

// ClearParams is one ClearArea transaction.
type ClearParams struct {
	UID                  string
	IdemKey, RequestHash string
	// ConsentID is the snowflake id of the WITHDRAWN record, used only when an area existed.
	ConsentID string
	Now       time.Time
}

// WriteResult is a write's outcome and the state after it.
type WriteResult struct {
	Outcome Outcome
	State   State
}

// Repo is the module's storage (FirestoreRepo in production).
type Repo interface {
	// Area reads the area doc; nil when none is set. 1 read.
	Area(ctx context.Context, uid string) (*StoredArea, error)
	// LatestConsent reads the newest consent record; nil when there is none. 1 read.
	LatestConsent(ctx context.Context, uid string) (*ConsentRecord, error)
	// SetArea runs the SetArea transaction (repo_firestore.go).
	SetArea(ctx context.Context, p SetParams) (WriteResult, error)
	// ClearArea runs the ClearArea transaction.
	ClearArea(ctx context.Context, p ClearParams) (WriteResult, error)
}

// IDGenerator mints time-ordered consent record ids (*snowflake.Node).
type IDGenerator interface {
	Generate() string
}

var (
	// ErrKeyReused: the idempotency key was used for a different request body.
	ErrKeyReused = errors.New("location: idempotency key reused")
	// ErrConsentRequired: SetArea with no current consent and no consent in the request.
	ErrConsentRequired = errors.New("location: consent required")
	// ErrConsentLimit: LOCATION_CONSENT_CHANGES_PER_DAY consent records today.
	ErrConsentLimit = errors.New("location: consent change limit reached")
)
