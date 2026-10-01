package flags

import (
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestDisabledError(t *testing.T) {
	err := DisabledError()
	var ae *apierr.Error
	if !errors.As(err, &ae) {
		t.Fatalf("err %v is not an *apierr.Error", err)
	}
	if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
		t.Fatalf("code=%v reason=%v, want FAILED_PRECONDITION + FEATURE_DISABLED", ae.Code, ae.Reason)
	}
	if ae.Message != "this feature is not available yet" {
		t.Fatalf("message = %q", ae.Message)
	}
	if DisabledError() == err {
		t.Fatal("each call must return a fresh error (callers may attach metadata)")
	}
}
