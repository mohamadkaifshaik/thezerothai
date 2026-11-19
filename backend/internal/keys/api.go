// Package keys is the Keys module (proto/dzeroth/keys/v1): the key directory for end-to-end encrypted direct messages.
// Each encryption device publishes a public signature key and a pool of opaque key packages; the server stores and hands
// out opaque bytes and never parses a key package or sees message content.
//
// It owns users/{uid}/keyDevices/{deviceId} and its keyPackages subcollection. The flag gates (Guard, GuardNotOff) are the
// handler's, before the service runs. Other modules reach it through the interfaces in this package only.
package keys

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FlagName is the wire name of FEATURE_E2EE_DM, the `feature` metadata of FEATURE_DISABLED and the string in
// GetMe.enabled_features.
const FlagName = "e2ee_dm"

// Permission is the seam to the messaging send rules; the composition root fills it.
type Permission interface {
	// CanMessage answers whether caller may message target by the messaging send rules. A refusal is
	// ErrCannotMessage (possibly wrapped); it never says why. Any other error is a failure to decide, not a refusal.
	CanMessage(ctx context.Context, callerUID, targetUID string) error
	// SharesEncryptedConversation reports whether the two users are the participants of a conversation whose
	// encryption is MLS. One cache-first conversation read (up to 60 s stale); writes nothing. No conversation, a
	// plaintext one, an invalid or equal uid, or a conversation whose other participant is not targetUID => false, nil.
	// A failed read is an error (uids and conversation id hashed), never false.
	SharesEncryptedConversation(ctx context.Context, callerUID, targetUID string) (bool, error)
}

// DeviceDirectory is the server-internal device lookup another module uses through the composition root (messaging: the
// welcome-device check of mls_init, and later ListWelcomes / AckWelcomes). It is NOT an RPC and runs without any check:
// no permission (Permission.CanMessage), no FEATURE_E2EE_DM gate for the caller or the target, and nothing on the request
// line (it runs inside another module's RPC). The caller of this interface has already applied its own rules. Each method
// is one query of at most MaxDevicesPerUser device documents and writes nothing; a read failure is an error (with the
// uid hashed), never an empty answer. Device ids are returned for comparison only: they are never logged. The service
// built by New implements it; the composition root type-asserts it, like messaging.Permission.
type DeviceDirectory interface {
	// ActiveDeviceIDs returns the ids of uid's ACTIVE devices (seen within InactiveAfter), oldest first, at most
	// MaxDevicesPerUser.
	ActiveDeviceIDs(ctx context.Context, uid string) ([]string, error)
	// DeviceIDs returns the ids of every registered device of uid, active or not, oldest first, at most MaxDevicesPerUser.
	DeviceIDs(ctx context.Context, uid string) ([]string, error)
}

// ErrCannotMessage is Permission's refusal: an unknown or non-ACTIVE target, a block in either direction or any other
// refusal by the messaging send rules. The service answers every one with the same CANNOT_MESSAGE.
var ErrCannotMessage = errors.New("keys: cannot message")

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the on-for-the-caller gate (RegisterKeyDevice, UploadKeyPackages, ClaimKeyPackages): before any Firestore
// access. Disabled is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=e2ee_dm. A nil checker is off
// for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid)
}

// GuardNotOff is the not-globally-off gate (ListMyKeyDevices, RemoveKeyDevice, GetKeyDevices), so a user dropped from an
// allowlist can still see and remove their devices and look up a peer they share an encrypted conversation with (the
// service answers an empty success for every other peer of a flag-off caller). Same error shape as Guard. A nil checker is off for everyone.
func GuardNotOff(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(_, name string) bool { return fc != nil && !fc.GloballyOff(name) }, uid)
}

// guard runs flags.Guard for FlagName and stamps the request line and the error metadata with the feature.
func guard(ctx context.Context, enabled func(uid, name string) bool, uid string) error {
	err := flags.Guard(ctx, enabled, uid, FlagName)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", FlagName)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", FlagName)
	}
	return err
}
