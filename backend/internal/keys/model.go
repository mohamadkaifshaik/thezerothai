package keys

import (
	"context"
	"errors"
	"time"
)

// Limits (keys.proto header).
const (
	// MaxDevicesPerUser is the cap of devices per user; a sixth is refused, never evicting.
	MaxDevicesPerUser = 5
	// MaxPoolSize is the most one-time key packages stored per device.
	MaxPoolSize = 100
	// MaxUploadBatch is the most key packages in one upload.
	MaxUploadBatch = 100
	// MaxKeyPackageBytes is the largest key package (and last-resort package); the smallest is 1.
	MaxKeyPackageBytes = 4096
	// SignatureKeyBytes is the exact size of a signature public key (Ed25519).
	SignatureKeyBytes = 32
	// InactiveAfter is how long a device may go unseen before it is inactive (filtered at read time, never deleted).
	InactiveAfter = 30 * 24 * time.Hour

	// seenRefreshInterval is how old LastSeenAt must be before a register or upload moves it.
	seenRefreshInterval = 24 * time.Hour
	// limitKeyDevices is LIMIT_REACHED metadata["limit"] for a sixth device.
	limitKeyDevices = "key_devices"
)

// Sentinel errors a Repo returns; the service maps them to API errors.
var (
	// ErrNotFound is an upload to a device the caller has not registered.
	ErrNotFound = errors.New("keys: device not found")
	// ErrDeviceLimit is a new device when the user already has MaxDevicesPerUser.
	ErrDeviceLimit = errors.New("keys: device limit reached")
	// ErrKeyMismatch is a register of an existing device id with a different signature key.
	ErrKeyMismatch = errors.New("keys: signature key mismatch")
	// ErrExcludeNotFound is a claim whose non-empty exclude device id names none of the target's devices (inactive ones
	// included); nothing is consumed.
	ErrExcludeNotFound = errors.New("keys: excluded device not found")
	// ErrDeviceRemoved is a register or upload of a device id that carries a removed mark (a REMOTE removal), or whose
	// device document carries removedAt (a REMOTE removal in progress). It never names the id.
	ErrDeviceRemoved = errors.New("keys: device removed")
)

// StuckRemovalsError is Register's ErrDeviceLimit when some of the device documents it counted carry removedAt: REMOTE
// removals that stopped after their mark transaction (code review I-1, security audit M2). Such a document holds a slot
// that no list shows and no client can free, so the service finishes those removals (their ids are already marked, so
// no sign-in is needed) and runs Register once more. errors.Is(err, ErrDeviceLimit) holds, so a caller that does not
// look for it answers LIMIT_REACHED. DeviceIDs (in the count query's order) are for the service only: Error() never
// names them.
type StuckRemovalsError struct {
	DeviceIDs []string
}

func (e *StuckRemovalsError) Error() string {
	return ErrDeviceLimit.Error() + " (removals in progress)"
}

// Unwrap makes the error ErrDeviceLimit to errors.Is.
func (e *StuckRemovalsError) Unwrap() error { return ErrDeviceLimit }

// RemoveReason says why a device is removed (keysv1.RemoveReason); it decides whether the id is remembered.
type RemoveReason int

const (
	// RemoveSignOut is the device removing itself as it signs out (and REMOVE_REASON_UNSPECIFIED, which builds before the
	// field send): no mark, the same id may register again.
	RemoveSignOut RemoveReason = iota
	// RemoveRemote is the user removing another device of theirs: the id is marked for RemovalMarkTTL, and an id not yet
	// marked needs a recent sign-in.
	RemoveRemote
)

// String is the request-line value of the reason.
func (r RemoveReason) String() string {
	switch r {
	case RemoveSignOut:
		return "sign_out"
	case RemoveRemote:
		return "remote"
	}
	return "unknown"
}

// RemovalMarkTTL is how long a removed mark refuses its id: expireAt = removedAt + 90 days (owner decision 2026-11-23). It
// is the Firestore TTL field; the code never reads expireAt, so a mark refuses until Firestore deletes it (TTL deletion
// can lag by a day or more, which only makes the mark last longer).
const RemovalMarkTTL = 90 * 24 * time.Hour

// RemovalMark is users/{uid}/keyDeviceRemovals/{deviceId} as the export reads it.
type RemovalMark struct {
	DeviceID  string
	RemovedAt time.Time
	ExpireAt  time.Time
}

// PendingRemoval is a device document carrying removedAt (a REMOTE removal that has not deleted it yet) as the export
// reads it: the stored metadata (Device; key bytes are never exported) and the document's removedAt.
type PendingRemoval struct {
	Device    Device
	RemovedAt time.Time
}

// ValidDeviceID reports whether s matches [A-Za-z0-9_-]{16,64}.
func ValidDeviceID(s string) bool {
	if len(s) < 16 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

// Device is one encryption device of a user.
type Device struct {
	ID           string
	SignatureKey []byte
	CreatedAt    time.Time
	LastSeenAt   time.Time
	// PoolCount is the one-time packages in the pool; HasLastResort is whether a last-resort package is stored.
	PoolCount     int
	HasLastResort bool
	// Inactive is !Active(now), set by ListMine and GetDevices (never stored, so a repository leaves it false).
	Inactive bool
}

// Claimed is the answer of a claim for one active device: a one-time package (consumed), else the last-resort package
// (LastResort, reusable, not consumed), else HasKeyPackage false with no bytes.
type Claimed struct {
	DeviceID      string
	SignatureKey  []byte
	KeyPackage    []byte
	HasKeyPackage bool
	LastResort    bool
}

// Active reports whether the device was seen within InactiveAfter of now (exactly InactiveAfter ago is inactive).
func (d Device) Active(now time.Time) bool { return now.Sub(d.LastSeenAt) < InactiveAfter }

// Service is the KeysService business layer for the device and upload RPCs. The flag gates and the idempotency_key format
// check are the handler's, before this runs; every method validates its input before any Firestore access. Byte slices
// passed in are copied, and byte slices returned never alias the caller's.
type Service interface {
	// Register publishes (or refreshes) the caller's device. ErrKeyMismatch is VALIDATION signature_public_key, a sixth
	// device is LIMIT_REACHED key_devices, a marked id (ErrDeviceRemoved, decided first) is DEVICE_REMOVED. At the cap it
	// first finishes REMOTE removals that stopped after their mark (StuckRemovalsError) and tries once more.
	Register(ctx context.Context, uid, deviceID string, signatureKey []byte) (Device, error)
	// ListMine returns the caller's devices, at most MaxDevicesPerUser, oldest first, inactive ones included (Inactive set).
	ListMine(ctx context.Context, uid string) ([]Device, error)
	// Remove deletes a device with its pool and last-resort package; a missing device is success. RemoveRemote first
	// marks the id (RemovalMarked; when not yet marked, a recent sign-in or REAUTH_REQUIRED with nothing written; then
	// MarkRemoved), so Register and Upload refuse it with DEVICE_REMOVED. Any other reason value is VALIDATION "reason".
	Remove(ctx context.Context, uid, deviceID string, reason RemoveReason) error
	// Upload adds packages to a registered device's pool (duplicates stored once, excess over MaxPoolSize dropped) and
	// optionally replaces its last-resort package (nil or empty = keep). It returns the resulting pool size. A marked id
	// is DEVICE_REMOVED, any other unknown device NOT_FOUND.
	Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte) (poolCount int, hasLastResort bool, err error)
	// GetDevices answers the devices of 1 to 10 distinct users, keyed by every requested id. For every user other than
	// the caller the caller must pass Permission.CanMessage first (in request order, before anything else); any refusal is
	// the one CANNOT_MESSAGE. Then, per other user: a pair that shares an accepted encrypted conversation
	// (Permission.SharesEncryptedConversation, whatever either flag says) gets every registered device with Inactive
	// set; else, when the flag is on for both caller and target, the active devices; else an empty list and no device
	// read. The caller's own id answers the caller's active devices only when the caller's flag is on, else an empty
	// list. A failed shared-conversation read is an error, never an empty list. PoolCount, HasLastResort and both
	// timestamps are zeroed for other users. Nothing is written (LastSeenAt is not refreshed).
	GetDevices(ctx context.Context, uid string, userIDs []string) (map[string][]Device, error)
	// Claim takes one key package per active device of targetUID (see Claimed), oldest device first, after the same
	// permission and flag rules as GetDevices (the shared-conversation rule does not apply: a claim still needs the
	// caller's flag on, enforced by the handler, and the target's flag on, else an empty success). For the caller's own id
	// excludeDeviceID is required and must be one of the caller's devices, which is skipped; for another user it must be
	// empty or well-formed and is not used. conversationID is the id of the (caller, target) conversation on every
	// success for another user (the flag-off target's empty success included) and "" for a self-claim and with every
	// error. Not replayable: a retry consumes fresh packages.
	Claim(ctx context.Context, uid, targetUID, excludeDeviceID string) (claimed []Claimed, conversationID string, err error)
}

// Repo is the storage seam (repo_firestore.go).
type Repo interface {
	// Register creates the device (ErrDeviceLimit past the cap) or, for an existing id with the same key, refreshes
	// LastSeenAt when older than seenRefreshInterval; a different key is ErrKeyMismatch. ErrDeviceRemoved comes before
	// both: a device document carrying removedAt, or a new id with a removed mark (read before the count). At the cap,
	// when some counted documents carry removedAt, the error is a StuckRemovalsError naming them.
	Register(ctx context.Context, uid string, d Device, now time.Time) (Device, error)
	// List returns at most MaxDevicesPerUser devices, oldest first. Every reader (List, ActiveDevices, Claim) skips a
	// device document carrying removedAt.
	List(ctx context.Context, uid string) ([]Device, error)
	// Remove deletes the device, its pool and its last-resort package; a missing device is nil.
	Remove(ctx context.Context, uid, deviceID string) error
	// Upload stores packages (deduplicated by bytes, oldest stay when the pool is full), sets lastResort when non-nil and
	// refreshes LastSeenAt on the same rule as Register. A device document carrying removedAt, or a missing one with a
	// removed mark, is ErrDeviceRemoved; any other unknown device is ErrNotFound.
	Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte, now time.Time) (int, bool, error)
	// ActiveDevices returns the user's devices active at now, oldest first (one query, Limit MaxDevicesPerUser). Nothing
	// is written.
	ActiveDevices(ctx context.Context, uid string, now time.Time) ([]Device, error)
	// Claim reads the target's devices; a non-empty excludeDeviceID that names none of them is ErrExcludeNotFound
	// (nothing written). For every other device active at now it takes one pool document (any one) by compare-and-delete,
	// deleting it and decrementing poolCount in one atomic write, else returns the last-resort package (LastResort),
	// else HasKeyPackage false; a device deleted meanwhile is left out. Contention on a device is never an error.
	// LastSeenAt is not touched.
	Claim(ctx context.Context, targetUID, excludeDeviceID string, now time.Time) ([]Claimed, error)
	// RemovalMarked reports whether the id carries a removed mark (one direct get, no query, no index).
	RemovalMarked(ctx context.Context, uid, deviceID string) (bool, error)
	// MarkRemoved is the REMOTE removal's transaction: it reads the device document and the mark, creates the mark when
	// absent (removedAt = now, expireAt = now + RemovalMarkTTL; an existing mark keeps its times) and sets removedAt on
	// the device document when it exists and lacks it. 2 reads, at most 2 writes. Idempotent.
	MarkRemoved(ctx context.Context, uid, deviceID string, now time.Time) error
}

// cloneBytes returns a copy of b (nil stays nil).
func cloneBytes(b []byte) []byte {
	if b == nil {
		return nil
	}
	return append([]byte{}, b...)
}

func cloneClaimed(c Claimed) Claimed {
	c.SignatureKey = cloneBytes(c.SignatureKey)
	c.KeyPackage = cloneBytes(c.KeyPackage)
	return c
}

func cloneDevice(d Device) Device {
	d.SignatureKey = cloneBytes(d.SignatureKey)
	return d
}
