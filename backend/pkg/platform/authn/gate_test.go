package authn_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

func reasonOf(t *testing.T, err error) commonv1.ErrorReason {
	t.Helper()
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	for _, d := range cerr.Details() {
		v, verr := d.Value()
		if verr != nil {
			continue
		}
		if ed, ok := v.(*commonv1.ErrorDetail); ok {
			return ed.GetReason()
		}
	}
	t.Fatal("no ErrorDetail on the error")
	return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED
}

func TestClaims_UnverifiedPassword(t *testing.T) {
	tests := []struct {
		name string
		c    authn.Claims
		want bool
	}{
		{"password, unverified", authn.Claims{SignInProvider: "password"}, true},
		{"password, verified", authn.Claims{SignInProvider: "password", EmailVerified: true}, false},
		{"google, claim false", authn.Claims{SignInProvider: "google.com"}, false},
		{"apple, claim false", authn.Claims{SignInProvider: "apple.com"}, false},
		{"no provider", authn.Claims{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.c.UnverifiedPassword(); got != tt.want {
				t.Errorf("UnverifiedPassword() = %v, want %v", got, tt.want)
			}
		})
	}
}

// countingProvider fails the test's 0-read claim if the gate lets a call reach the account-status lookup.
type countingProvider struct{ calls atomic.Int64 }

func (p *countingProvider) AccountStatus(context.Context, string) (bool, authn.AccountStatus, error) {
	p.calls.Add(1)
	return false, authn.AccountStatusUnknown, nil
}

// TestVerifiedIdentityInterceptor (ADR-0010 D5 A2): an unverified password account is rejected from the token
// claims alone, before the account-status lookup (0 reads) and before any later interceptor, with
// EMAIL_NOT_VERIFIED on the gated (profile-exempt) procedures and PROFILE_REQUIRED on every other one.
func TestVerifiedIdentityInterceptor(t *testing.T) {
	tests := []struct {
		name       string
		claims     authn.Claims
		gated      map[string]struct{} // procedures answering EMAIL_NOT_VERIFIED
		wantReject bool
		wantReason commonv1.ErrorReason
	}{
		{"unverified password, exempt procedure", authn.Claims{UID: "u1", SignInProvider: "password"},
			authn.ProfileExemptProcedures(procedure), true, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED},
		{"unverified password, other procedure", authn.Claims{UID: "u1", SignInProvider: "password"},
			authn.ProfileExemptProcedures(), true, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED},
		{"verified password passes", authn.Claims{UID: "u1", SignInProvider: "password", EmailVerified: true},
			authn.ProfileExemptProcedures(), false, 0},
		{"google passes even with the claim false", authn.Claims{UID: "u1", SignInProvider: "google.com"},
			authn.ProfileExemptProcedures(), false, 0},
		{"apple passes", authn.Claims{UID: "u1", SignInProvider: "apple.com"},
			authn.ProfileExemptProcedures(procedure), false, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider := &countingProvider{}
			var info *logger.RequestInfo
			verifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"tok": tt.claims}}
			var reached atomic.Int64
			afterGate := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
				return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
					reached.Add(1)
					return next(ctx, req)
				}
			})
			srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(verifier),
				authn.VerifiedIdentityInterceptor(tt.gated), afterGate,
				authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures(procedure)))
			err := call(t, srv, map[string]string{"Authorization": "Bearer tok"})
			if !tt.wantReject {
				if err != nil {
					t.Fatalf("verified identity must pass the gate: %v", err)
				}
				return
			}
			if got := codeOf(t, err); got != connect.CodeFailedPrecondition {
				t.Fatalf("Code() = %v, want FailedPrecondition", got)
			}
			if got := reasonOf(t, err); got != tt.wantReason {
				t.Errorf("reason = %v, want %v", got, tt.wantReason)
			}
			if reached.Load() != 0 || provider.calls.Load() != 0 {
				t.Errorf("gate must reject before the next interceptor and cost 0 lookups (reached=%d lookups=%d)", reached.Load(), provider.calls.Load())
			}
			if v, _ := info.Get("gate"); v != "email_unverified" {
				t.Errorf("gate field = %v, want email_unverified", v)
			}
		})
	}
}

// TestAccountStatusInterceptor_FlagsProfileRequiredOnRequestInfo (A3): the !exists branch tells the rate limiter.
func TestAccountStatusInterceptor_FlagsProfileRequiredOnRequestInfo(t *testing.T) {
	tests := []struct {
		name   string
		exists bool
		want   bool
	}{
		{"no profile", false, true},
		{"has profile", true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var info *logger.RequestInfo
			provider := fakeAccountStatusProvider{byUID: map[string]struct {
				exists bool
				status authn.AccountStatus
			}{"u1": {exists: tt.exists, status: authn.AccountStatusActive}}}
			verifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"tok": {UID: "u1"}}}
			srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(verifier),
				authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures()))
			_ = call(t, srv, map[string]string{"Authorization": "Bearer tok"})
			if info.ProfileRequired != tt.want {
				t.Errorf("ProfileRequired = %v, want %v", info.ProfileRequired, tt.want)
			}
		})
	}
}
