package authn_test

import (
	"context"
	"errors"
	"strings"
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

// TestClaims_IdentityGate is the ADR-0010 D5 A10 allowlist table: fail closed on everything not listed.
func TestClaims_IdentityGate(t *testing.T) {
	tests := []struct {
		name           string
		c              authn.Claims
		allowAnonymous bool
		want           string
	}{
		{"google, claim false", authn.Claims{SignInProvider: "google.com"}, false, authn.GatePass},
		{"apple, claim false", authn.Claims{SignInProvider: "apple.com"}, false, authn.GatePass},
		{"password, verified", authn.Claims{SignInProvider: "password", EmailVerified: true}, false, authn.GatePass},
		{"password, unverified", authn.Claims{SignInProvider: "password"}, false, authn.GateEmailUnverified},
		{"anonymous, emulator off", authn.Claims{SignInProvider: "anonymous"}, false, authn.GateProviderNotAllow},
		{"anonymous, emulator on", authn.Claims{SignInProvider: "anonymous"}, true, authn.GatePass},
		{"anonymous with email_verified claim, emulator off", authn.Claims{SignInProvider: "anonymous", EmailVerified: true}, false, authn.GateProviderNotAllow},
		{"phone", authn.Claims{SignInProvider: "phone", EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"custom", authn.Claims{SignInProvider: "custom", EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"github.com", authn.Claims{SignInProvider: "github.com", EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"saml.x", authn.Claims{SignInProvider: "saml.x", EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"oidc.x", authn.Claims{SignInProvider: "oidc.x", EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"empty provider", authn.Claims{EmailVerified: true}, true, authn.GateProviderNotAllow},
		{"case differs", authn.Claims{SignInProvider: "Google.com"}, true, authn.GateProviderNotAllow},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.c.IdentityGate(tt.allowAnonymous); got != tt.want {
				t.Errorf("IdentityGate(%v) = %q, want %q", tt.allowAnonymous, got, tt.want)
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

// TestVerifiedIdentityInterceptor (ADR-0010 D5 A2/A10): a caller outside the provider allowlist is rejected
// from the token claims alone, before the account-status lookup (0 reads) and before any later interceptor, with
// EMAIL_NOT_VERIFIED on the gated (profile-exempt) procedures and PROFILE_REQUIRED on every other one, and the
// right `gate` log value.
func TestVerifiedIdentityInterceptor(t *testing.T) {
	exempt := authn.ProfileExemptProcedures(procedure)
	none := authn.ProfileExemptProcedures()
	tests := []struct {
		name           string
		claims         authn.Claims
		gated          map[string]struct{} // procedures answering EMAIL_NOT_VERIFIED
		allowAnonymous bool
		wantReject     bool
		wantReason     commonv1.ErrorReason
		wantGate       string
		wantProvider   string // gate_provider, only for provider_not_allowed
	}{
		{name: "unverified password, exempt procedure", claims: authn.Claims{UID: "u1", SignInProvider: "password"}, gated: exempt,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, wantGate: "email_unverified"},
		{name: "unverified password, other procedure", claims: authn.Claims{UID: "u1", SignInProvider: "password"}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "email_unverified"},
		{name: "verified password passes", claims: authn.Claims{UID: "u1", SignInProvider: "password", EmailVerified: true}, gated: none},
		{name: "google passes even with the claim false", claims: authn.Claims{UID: "u1", SignInProvider: "google.com"}, gated: none},
		{name: "apple passes", claims: authn.Claims{UID: "u1", SignInProvider: "apple.com"}, gated: exempt},
		{name: "anonymous passes with the emulator flag", claims: authn.Claims{UID: "u1", SignInProvider: "anonymous"}, gated: exempt, allowAnonymous: true},
		{name: "anonymous, flag off, exempt procedure", claims: authn.Claims{UID: "u1", SignInProvider: "anonymous"}, gated: exempt,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, wantGate: "provider_not_allowed", wantProvider: "anonymous"},
		{name: "anonymous, flag off, other procedure", claims: authn.Claims{UID: "u1", SignInProvider: "anonymous"}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: "anonymous"},
		{name: "phone", claims: authn.Claims{UID: "u1", SignInProvider: "phone", EmailVerified: true}, gated: none, allowAnonymous: true,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: "phone"},
		{name: "custom", claims: authn.Claims{UID: "u1", SignInProvider: "custom"}, gated: exempt,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, wantGate: "provider_not_allowed", wantProvider: "custom"},
		{name: "github.com", claims: authn.Claims{UID: "u1", SignInProvider: "github.com", EmailVerified: true}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: "github.com"},
		{name: "saml.x", claims: authn.Claims{UID: "u1", SignInProvider: "saml.x", EmailVerified: true}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: "saml.x"},
		{name: "oidc.x", claims: authn.Claims{UID: "u1", SignInProvider: "oidc.x", EmailVerified: true}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: "oidc.x"},
		{name: "empty provider", claims: authn.Claims{UID: "u1", EmailVerified: true}, gated: exempt,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, wantGate: "provider_not_allowed", wantProvider: ""},
		{name: "provider cut to 32 bytes", claims: authn.Claims{UID: "u1", SignInProvider: strings.Repeat("x", 40)}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: strings.Repeat("x", 32)},
		{name: "provider cut never splits a rune", claims: authn.Claims{UID: "u1", SignInProvider: strings.Repeat("x", 31) + "é"}, gated: none,
			wantReject: true, wantReason: commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, wantGate: "provider_not_allowed", wantProvider: strings.Repeat("x", 31)},
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
				authn.VerifiedIdentityInterceptor(tt.gated, tt.allowAnonymous), afterGate,
				authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures(procedure)))
			err := call(t, srv, map[string]string{"Authorization": "Bearer tok"})
			if !tt.wantReject {
				if err != nil {
					t.Fatalf("allowlisted identity must pass the gate: %v", err)
				}
				if v, ok := info.Get("gate"); ok {
					t.Errorf("gate field = %v on a pass, want unset", v)
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
			if v, _ := info.Get("gate"); v != tt.wantGate {
				t.Errorf("gate field = %v, want %s", v, tt.wantGate)
			}
			v, ok := info.Get("gate_provider")
			if tt.wantGate == "provider_not_allowed" {
				if !ok || v != tt.wantProvider {
					t.Errorf("gate_provider = %v (set=%v), want %q", v, ok, tt.wantProvider)
				}
			} else if ok {
				t.Errorf("gate_provider = %v, want unset for %s", v, tt.wantGate)
			}
		})
	}
}

// TestAccountStatusInterceptor_FlagsProfileRequiredOnRequestInfo (A3, A9): the !exists branch sets
// ProfileRequired; any lookup that finds a profile (whatever the status) sets ProfileFound, and a lookup error
// sets neither.
func TestAccountStatusInterceptor_FlagsProfileRequiredOnRequestInfo(t *testing.T) {
	tests := []struct {
		name         string
		exists       bool
		status       authn.AccountStatus
		wantRequired bool
		wantFound    bool
	}{
		{"no profile", false, authn.AccountStatusActive, true, false},
		{"has profile", true, authn.AccountStatusActive, false, true},
		{"suspended profile is still found", true, authn.AccountStatusSuspended, false, true},
		{"deleting profile is still found", true, authn.AccountStatusDeleting, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var info *logger.RequestInfo
			provider := fakeAccountStatusProvider{byUID: map[string]struct {
				exists bool
				status authn.AccountStatus
			}{"u1": {exists: tt.exists, status: tt.status}}}
			verifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"tok": {UID: "u1"}}}
			srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(verifier),
				authn.AccountStatusInterceptor(provider, authn.ProfileExemptProcedures()))
			_ = call(t, srv, map[string]string{"Authorization": "Bearer tok"})
			if info.ProfileRequired != tt.wantRequired {
				t.Errorf("ProfileRequired = %v, want %v", info.ProfileRequired, tt.wantRequired)
			}
			if info.ProfileFound != tt.wantFound {
				t.Errorf("ProfileFound = %v, want %v", info.ProfileFound, tt.wantFound)
			}
		})
	}
}

type erroringProvider struct{}

func (erroringProvider) AccountStatus(context.Context, string) (bool, authn.AccountStatus, error) {
	// A lookup error must not look like a found profile even if a buggy provider returns exists == true.
	return true, authn.AccountStatusActive, errors.New("firestore unavailable")
}

// TestAccountStatusInterceptor_LookupErrorSetsNoFlags (A9): ProfileFound is never set on a lookup error.
func TestAccountStatusInterceptor_LookupErrorSetsNoFlags(t *testing.T) {
	var info *logger.RequestInfo
	verifier := fakeIDTokenVerifier{tokens: map[string]authn.Claims{"tok": {UID: "u1"}}}
	srv := newServer(t, seedRequestInfo(&info), authn.IDTokenInterceptor(verifier),
		authn.AccountStatusInterceptor(erroringProvider{}, authn.ProfileExemptProcedures()))
	if err := call(t, srv, map[string]string{"Authorization": "Bearer tok"}); err == nil {
		t.Fatal("lookup error must fail the call")
	}
	if info.ProfileFound || info.ProfileRequired {
		t.Errorf("ProfileFound=%v ProfileRequired=%v, want both false on a lookup error", info.ProfileFound, info.ProfileRequired)
	}
}
