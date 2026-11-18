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

// FlagChecker is the seam to pkg/platform/flags.Registry (*flags.Registry satisfies it).
type FlagChecker interface {
	Enabled(uid, name string) bool
	GloballyOff(name string) bool
}

// Guard is the on-for-the-caller gate (RegisterKeyDevice, UploadKeyPackages, ClaimKeyPackages, GetKeyDevices): before any
// Firestore access. Disabled is FAILED_PRECONDITION + FEATURE_DISABLED with metadata feature=e2ee_dm. A nil checker is off
// for everyone.
func Guard(ctx context.Context, fc FlagChecker, uid string) error {
	return guard(ctx, func(uid, name string) bool { return fc != nil && fc.Enabled(uid, name) }, uid)
}

// GuardNotOff is the not-globally-off gate (ListMyKeyDevices, RemoveKeyDevice), so a user dropped from an allowlist can
// still see and remove their devices. Same error shape as Guard. A nil checker is off for everyone.
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
