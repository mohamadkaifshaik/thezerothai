package media

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// noteRejected records outcome=rejected:<reason> for an error returned by an RPC.
func noteRejected(ctx context.Context, err error) {
	logger.SetRequestField(ctx, fieldOutcome, "rejected:"+rejectReason(err))
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		logger.SetRequestField(ctx, "feature_disabled", true)
	}
}

func rejectReason(err error) string {
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		return "error"
	}
	switch {
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED:
		return "feature_disabled"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
		return "quota_exceeded"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED:
		return "key_reused"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY:
		return "upload_incomplete"
	case ae.Code == connect.CodeInvalidArgument:
		return "invalid"
	case ae.Code == connect.CodeNotFound:
		return "not_found"
	case ae.Code == connect.CodeUnavailable:
		return "moderation_unavailable"
	}
	return "error"
}
