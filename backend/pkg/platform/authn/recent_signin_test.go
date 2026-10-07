package authn

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestRequireRecentSignIn(t *testing.T) {
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	const maxAge = 5 * time.Minute
	tests := []struct {
		name   string
		claims *Claims // nil = no claims in ctx
		pass   bool
	}{
		{"4m59s ago passes", &Claims{UID: "u", AuthTime: now.Add(-4*time.Minute - 59*time.Second)}, true},
		{"exactly maxAge passes", &Claims{UID: "u", AuthTime: now.Add(-maxAge)}, true},
		{"5m01s ago is stale", &Claims{UID: "u", AuthTime: now.Add(-5*time.Minute - time.Second)}, false},
		{"missing auth_time", &Claims{UID: "u"}, false},
		{"no claims fails closed", nil, false},
		{"30s in the future passes (skew)", &Claims{UID: "u", AuthTime: now.Add(30 * time.Second)}, true},
		{"31s in the future fails closed", &Claims{UID: "u", AuthTime: now.Add(31 * time.Second)}, false},
		{"just now passes", &Claims{UID: "u", AuthTime: now}, true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.claims != nil {
				ctx = WithClaims(ctx, *tc.claims)
			}
			err := RequireRecentSignIn(ctx, maxAge, now)
			if tc.pass {
				if err != nil {
					t.Fatalf("err = %v, want nil", err)
				}
				return
			}
			var ae *apierr.Error
			if !errors.As(err, &ae) {
				t.Fatalf("err = %v, want *apierr.Error", err)
			}
			if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED {
				t.Fatalf("got code=%v reason=%v, want FAILED_PRECONDITION + REAUTH_REQUIRED", ae.Code, ae.Reason)
			}
		})
	}
}
