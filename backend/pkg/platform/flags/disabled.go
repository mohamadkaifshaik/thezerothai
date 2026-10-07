package flags

import (
	"context"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Guard is the one flag check for flag-guarded RPCs that carry a caller uid: it returns nil when enabled(uid,
// name) is true, otherwise it logs feature_disabled=true and outcome=rejected:feature_disabled on the request
// line and returns DisabledError(). A nil enabled func means off. It never reads Firestore.
func Guard(ctx context.Context, enabled func(uid, name string) bool, uid, name string) error {
	if enabled == nil || !enabled(uid, name) {
		logger.SetRequestField(ctx, "feature_disabled", true)
		logger.SetRequestField(ctx, "outcome", "rejected:feature_disabled")
		return DisabledError()
	}
	return nil
}

// DisabledError is the one answer every flag-guarded service gives when its flag is off for the caller
// (ADR-0008 D6, ADR-0010 D1): FAILED_PRECONDITION + FEATURE_DISABLED, "this feature is not available yet".
// Clients hide the feature and refresh GetMe.enabled_features. A sub-feature rejection adds
// metadata["feature"] on top of this (ADR-0010 D2); an absent name means the whole service.
func DisabledError() *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "this feature is not available yet")
}
