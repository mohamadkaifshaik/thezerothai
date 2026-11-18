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
)

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
	// device is LIMIT_REACHED key_devices.
	Register(ctx context.Context, uid, deviceID string, signatureKey []byte) (Device, error)
	// ListMine returns the caller's devices, at most MaxDevicesPerUser, oldest first, inactive ones included.
	ListMine(ctx context.Context, uid string) ([]Device, error)
	// Remove deletes a device with its pool and last-resort package; a missing device is success.
	Remove(ctx context.Context, uid, deviceID string) error
	// Upload adds packages to a registered device's pool (duplicates stored once, excess over MaxPoolSize dropped) and
	// optionally replaces its last-resort package (nil or empty = keep). It returns the resulting pool size.
	Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte) (poolCount int, hasLastResort bool, err error)
	// GetDevices answers the active devices of 1 to 10 distinct users, keyed by every requested id (an empty list for a
	// user with the flag off or no active device). For every user other than the caller the caller must pass
	// Permission.CanMessage first; any refusal is the one CANNOT_MESSAGE. PoolCount and HasLastResort are zeroed for
	// other users. Nothing is written (LastSeenAt is not refreshed).
	GetDevices(ctx context.Context, uid string, userIDs []string) (map[string][]Device, error)
	// Claim takes one key package per active device of targetUID (see Claimed), oldest device first, after the same
	// permission and flag rules as GetDevices. For the caller's own id excludeDeviceID is required and must be one of the
	// caller's devices, which is skipped; for another user it must be empty or well-formed and is not used. Not
	// replayable: a retry consumes fresh packages.
	Claim(ctx context.Context, uid, targetUID, excludeDeviceID string) ([]Claimed, error)
}

// Repo is the storage seam (repo_firestore.go).
type Repo interface {
	// Register creates the device (ErrDeviceLimit past the cap) or, for an existing id with the same key, refreshes
	// LastSeenAt when older than seenRefreshInterval; a different key is ErrKeyMismatch.
	Register(ctx context.Context, uid string, d Device, now time.Time) (Device, error)
	// List returns at most MaxDevicesPerUser devices, oldest first.
	List(ctx context.Context, uid string) ([]Device, error)
	// Remove deletes the device, its pool and its last-resort package; a missing device is nil.
	Remove(ctx context.Context, uid, deviceID string) error
	// Upload stores packages (deduplicated by bytes, oldest stay when the pool is full), sets lastResort when non-nil and
	// refreshes LastSeenAt on the same rule as Register. An unknown device is ErrNotFound.
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
