package apierr

import (
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

func TestToConnect_MapsAppError(t *testing.T) {
	err := New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "bad field").
		WithMeta("field", "handle").
		WithRetryAfter(5 * time.Second)

	cerr := ToConnect(err)
	if cerr.Code() != connect.CodeInvalidArgument {
		t.Fatalf("Code() = %v, want InvalidArgument", cerr.Code())
	}
	details := cerr.Details()
	if len(details) != 1 {
		t.Fatalf("expected 1 detail, got %d", len(details))
	}
	msg, derr := details[0].Value()
	if derr != nil {
		t.Fatalf("Value() error = %v", derr)
	}
	detail, ok := msg.(*commonv1.ErrorDetail)
	if !ok {
		t.Fatalf("detail is %T, want *commonv1.ErrorDetail", msg)
	}
	if detail.GetReason() != commonv1.ErrorReason_ERROR_REASON_VALIDATION {
		t.Errorf("Reason = %v", detail.GetReason())
	}
	if detail.GetMetadata()["field"] != "handle" {
		t.Errorf("Metadata[field] = %q", detail.GetMetadata()["field"])
	}
	if detail.GetRetryAfter().AsDuration() != 5*time.Second {
		t.Errorf("RetryAfter = %v", detail.GetRetryAfter().AsDuration())
	}
}

func TestToConnect_UnknownErrorBecomesInternalNoLeak(t *testing.T) {
	err := errors.New("some internal detail: password=hunter2")
	cerr := ToConnect(err)
	if cerr.Code() != connect.CodeInternal {
		t.Fatalf("Code() = %v, want Internal", cerr.Code())
	}
	if cerr.Message() == err.Error() {
		t.Fatal("internal error details must not be echoed back to the client")
	}
}

func TestToConnect_PassesThroughExistingConnectError(t *testing.T) {
	original := connect.NewError(connect.CodeNotFound, errors.New("not found"))
	cerr := ToConnect(original)
	if cerr != original {
		t.Fatal("expected the same *connect.Error to be returned unchanged")
	}
}

func TestToConnect_Nil(t *testing.T) {
	if ToConnect(nil) != nil {
		t.Fatal("ToConnect(nil) should return nil")
	}
}

func TestError_WrapsCauseForLogsNotForClient(t *testing.T) {
	cause := errors.New("firestore: deadline exceeded")
	err := New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(cause)

	if !errors.Is(err, cause) {
		t.Fatal("expected errors.Is to find the wrapped cause")
	}
	cerr := ToConnect(err)
	if cerr.Message() != "internal error" {
		t.Errorf("client-facing message leaked internals: %q", cerr.Message())
	}
}

func TestValidation_SetsFieldMetadata(t *testing.T) {
	err := Validation("bio", "too long")
	if err.Code != connect.CodeInvalidArgument {
		t.Errorf("Code = %v", err.Code)
	}
	if err.Metadata["field"] != "bio" {
		t.Errorf("Metadata[field] = %q", err.Metadata["field"])
	}
}
