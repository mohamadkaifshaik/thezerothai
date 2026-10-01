package authn

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func TestRequireVerifiedEmail(t *testing.T) {
	tests := []struct {
		name      string
		claims    *Claims // nil = no claims in ctx
		anonymous bool
		pass      bool
	}{
		{"unverified password account", &Claims{UID: "u", SignInProvider: SignInProviderPassword}, false, false},
		{"verified password account", &Claims{UID: "u", SignInProvider: SignInProviderPassword, EmailVerified: true}, false, true},
		{"google passes", &Claims{UID: "u", SignInProvider: SignInProviderGoogle}, false, true},
		{"apple passes", &Claims{UID: "u", SignInProvider: SignInProviderApple}, false, true},
		{"anonymous outside the emulator", &Claims{UID: "u", SignInProvider: SignInProviderAnonymous}, false, false},
		{"anonymous against the emulator", &Claims{UID: "u", SignInProvider: SignInProviderAnonymous}, true, true},
		{"unknown provider", &Claims{UID: "u", SignInProvider: "phone", EmailVerified: true}, false, false},
		{"no claims fails closed", nil, false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			if tc.claims != nil {
				ctx = WithClaims(ctx, *tc.claims)
			}
			err := RequireVerifiedEmail(ctx, tc.anonymous, "posting")
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
			if ae.Code != connect.CodeFailedPrecondition || ae.Reason != commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED {
				t.Fatalf("code=%v reason=%v, want FAILED_PRECONDITION + EMAIL_NOT_VERIFIED", ae.Code, ae.Reason)
			}
			if want := "please verify your email before posting"; ae.Message != want {
				t.Fatalf("message = %q, want %q", ae.Message, want)
			}
		})
	}
}

// TestRequireVerifiedEmail_IdentityMessage pins identity's CreateProfile wording, which this check replaced.
func TestRequireVerifiedEmail_IdentityMessage(t *testing.T) {
	ctx := WithClaims(context.Background(), Claims{UID: "u", SignInProvider: SignInProviderPassword})
	var ae *apierr.Error
	if err := RequireVerifiedEmail(ctx, false, "creating a profile"); !errors.As(err, &ae) ||
		ae.Message != "please verify your email before creating a profile" {
		t.Fatalf("err = %v", err)
	}
}
