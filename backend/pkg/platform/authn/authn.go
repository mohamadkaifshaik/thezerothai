// Package authn verifies Firebase ID tokens and Firebase App Check tokens. Both
// verifications are local JWT checks against cached Google public keys — no Firestore reads, no
// per-request network call once the keys are cached. Both underlying Firebase Admin SDK clients honor
// the emulator env vars (FIREBASE_AUTH_EMULATOR_HOST) automatically; see NewIDTokenVerifier.
package authn

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Claims is the subset of Firebase ID token claims the platform cares about. UID is the only trusted
// identifier for the caller — request bodies must never carry a user id that overrides it.
type Claims struct {
	UID            string
	EmailVerified  bool
	SignInProvider string
	AuthTime       time.Time
	// Identities is firebase.identities: provider -> the subject ids the account holds (the password provider is
	// listed as "email"); nil when absent. It comes from the verified JWT, so reading it costs nothing. It feeds
	// only the warn-only identity audit, which compares the signing federated subject against the stored baseline.
	Identities map[string][]string
}

// Firebase `firebase.sign_in_provider` claim values the verified-identity gate knows.
const (
	// SignInProviderPassword is email/password, the only allowed provider whose email Firebase does not itself
	// guarantee verified (Google and Apple verify it upstream), so it also needs email_verified.
	SignInProviderPassword  = "password"
	SignInProviderGoogle    = "google.com"
	SignInProviderApple     = "apple.com"
	SignInProviderAnonymous = "anonymous"
)

// Gate results of Claims.IdentityGate; they are also the `gate` log field values.
const (
	GatePass             = ""
	GateEmailUnverified  = "email_unverified"
	GateProviderNotAllow = "provider_not_allowed"
)

// IdentityGate is the allowlist predicate, the one definition shared by
// VerifiedIdentityInterceptor and identity's CreateProfile. It fails closed: only google.com, apple.com and
// password with email_verified pass, plus anonymous when allowAnonymous (Auth emulator only). It returns
// GatePass, GateEmailUnverified (an unverified password account) or GateProviderNotAllow (everything else,
// including an empty provider). An account that fails it can never own a profile.
func (c Claims) IdentityGate(allowAnonymous bool) string {
	switch c.SignInProvider {
	case SignInProviderGoogle, SignInProviderApple:
		return GatePass
	case SignInProviderPassword:
		if c.EmailVerified {
			return GatePass
		}
		return GateEmailUnverified
	case SignInProviderAnonymous:
		if allowAnonymous {
			return GatePass
		}
	}
	return GateProviderNotAllow
}

// RequireVerifiedEmail is the shared "verified email before you may <action>" check (
// "email verification or Google/Apple sign-in required before posting"). It applies Claims.IdentityGate to the
// caller in ctx and returns FAILED_PRECONDITION + EMAIL_NOT_VERIFIED, "please verify your email before
// <action>", for anyone outside the allowlist. 0 Firestore reads. action completes the sentence, for example
// "creating a profile" or "posting". allowAnonymous must be config.AuthEmulator only.
//
// authn.VerifiedIdentityInterceptor already stops these callers earlier, from the same claims; modules call
// this as defence in depth so a chain without the gate (a unit test, a future service) still refuses them.
func RequireVerifiedEmail(ctx context.Context, allowAnonymous bool, action string) error {
	claims, _ := ClaimsFromContext(ctx)
	if claims.IdentityGate(allowAnonymous) == GatePass {
		return nil
	}
	return apierr.New(
		connect.CodeFailedPrecondition,
		commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED,
		"please verify your email before "+action,
	)
}

// recentSignInSkew is how far in the future a token's auth_time may be (clock skew between Firebase and this
// instance) and still count as a fresh sign-in.
const recentSignInSkew = 30 * time.Second

// IsRecentSignIn reports whether the caller's Firebase sign-in is recent: Claims.AuthTime (when the user last
// authenticated, not when the token was refreshed) is non-zero, no older than maxAge, and no more than 30 s in the
// future (fail closed). It reads no Firestore and, unlike RequireRecentSignIn, has NO side effect: it sets no
// request-log field. Use it where a stale sign-in is a normal, non-error outcome (GetAccountExport withholding the
// download URL so status polling stays open), not a rejection. A zero maxAge makes every token fail (fail closed).
func IsRecentSignIn(ctx context.Context, maxAge time.Duration, now time.Time) bool {
	claims, _ := ClaimsFromContext(ctx)
	if claims.AuthTime.IsZero() {
		return false
	}
	age := now.Sub(claims.AuthTime)
	return age <= maxAge && age >= -recentSignInSkew
}

// RequireRecentSignIn is the shared "recent sign-in" check for sensitive account actions (DeleteAccount, RequestAccountExport).
// It is IsRecentSignIn as a gate: it returns FAILED_PRECONDITION + REAUTH_REQUIRED when the sign-in is not recent
// (zero/missing auth_time, older than maxAge, or more than 30 s in the future), and on that rejection logs
// reauth_required=true on the request line. now is injected so tests need no sleeps. Callers pass the
// config-validated maxAge (config.AccountDeleteReauthMaxAge, in (0, 10m]). 0 Firestore reads.
func RequireRecentSignIn(ctx context.Context, maxAge time.Duration, now time.Time) error {
	if IsRecentSignIn(ctx, maxAge, now) {
		return nil
	}
	logger.SetRequestField(ctx, "reauth_required", true)
	return apierr.New(
		connect.CodeFailedPrecondition,
		commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED,
		"please sign in again to continue",
	)
}

// IDTokenVerifier verifies a Firebase Auth ID token from the `Authorization: Bearer` header.
type IDTokenVerifier interface {
	VerifyIDToken(ctx context.Context, idToken string) (Claims, error)
}

// AppCheckVerifier verifies a Firebase App Check token from the `X-Firebase-AppCheck` header.
type AppCheckVerifier interface {
	VerifyToken(ctx context.Context, token string) error
}

type ctxKey int

const claimsCtxKey ctxKey = iota

// WithClaims attaches verified caller claims to ctx.
func WithClaims(ctx context.Context, c Claims) context.Context {
	return context.WithValue(ctx, claimsCtxKey, c)
}

// ClaimsFromContext returns the caller's verified claims and true, or zero value and false if the
// request was never authenticated (should not happen once the auth interceptor is installed).
func ClaimsFromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsCtxKey).(Claims)
	return c, ok
}

// UIDFromContext is a convenience wrapper for the common case of just needing the caller's uid.
func UIDFromContext(ctx context.Context) (string, bool) {
	c, ok := ClaimsFromContext(ctx)
	if !ok {
		return "", false
	}
	return c.UID, true
}
