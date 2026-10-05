package posts

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-log fields for CreatePost (ADR-0010 D20). They ride on the mw.Logging line; every value is an enum, a
// count or a boolean. Never log text, handles, hashtags, mention lists or uids.
const (
	fieldOp               = "posts_op"
	fieldOutcome          = "outcome"
	fieldMentionsResolved = "mentions_resolved"
	fieldMentionsDropped  = "mentions_dropped"
	fieldMentionsInURL    = "mentions_in_url"
	fieldHashtagsCount    = "hashtags_count"
	fieldTextLen          = "text_len"
	fieldTxnAttempts      = "txn_attempts"
	fieldFeature          = "feature"
)

// outcomes of CreatePost (posts_op=create).
const (
	outcomeCreated = "created"
	outcomeReplay  = "replay"
)

// noteRejected records outcome=rejected:<reason> for an error returned by an RPC.
func noteRejected(ctx context.Context, err error) {
	logger.SetRequestField(ctx, fieldOutcome, "rejected:"+rejectReason(err))
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		logger.SetRequestField(ctx, "feature_disabled", true)
		if f := ae.Metadata["feature"]; f != "" {
			logger.SetRequestField(ctx, fieldFeature, f)
		}
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
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED:
		return "email_not_verified"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED:
		return "profile_required"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
		return "quota_exceeded"
	case ae.Reason == commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED:
		return "key_reused"
	case ae.Code == connect.CodeInvalidArgument:
		return "invalid"
	case ae.Code == connect.CodeNotFound:
		return "not_found"
	}
	return "error"
}

// noteTxnAttempts records txn_attempts and WARNs above store.TxnWarnAttempts (only under real contention; no ids).
func noteTxnAttempts(ctx context.Context, attempts int) {
	store.NoteTxnAttempts(ctx, "posts_txn_contention", attempts)
}
