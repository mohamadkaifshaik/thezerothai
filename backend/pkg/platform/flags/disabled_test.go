package flags

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func TestGuard(t *testing.T) {
	on := func(string, string) bool { return true }
	off := func(string, string) bool { return false }
	tests := []struct {
		name    string
		enabled func(uid, name string) bool
		wantErr bool
	}{
		{"on passes", on, false},
		{"off rejects", off, true},
		{"nil means off", nil, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx, info := logger.WithRequestInfo(context.Background())
			err := Guard(ctx, tc.enabled, "u1", "x")
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if !tc.wantErr {
				if _, ok := info.Get("feature_disabled"); ok {
					t.Error("feature_disabled set on a pass")
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
				t.Fatalf("err = %v, want FEATURE_DISABLED", err)
			}
			if v, _ := info.Get("feature_disabled"); v != true {
				t.Errorf("feature_disabled = %v", v)
			}
			if v, _ := info.Get("outcome"); v != "rejected:feature_disabled" {
				t.Errorf("outcome = %v", v)
			}
		})
	}
}

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
