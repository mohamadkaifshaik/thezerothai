// Package authn verifies Firebase ID tokens and Firebase App Check tokens (ADR-0006 §1-2). Both
// verifications are local JWT checks against cached Google public keys — no Firestore reads, no
// per-request network call once the keys are cached. Both underlying Firebase Admin SDK clients honor
// the emulator env vars (FIREBASE_AUTH_EMULATOR_HOST) automatically; see NewIDTokenVerifier.
package authn

import (
	"context"
	"time"
)

// Claims is the subset of Firebase ID token claims the platform cares about. UID is the only trusted
// identifier for the caller — request bodies must never carry a user id that overrides it.
type Claims struct {
	UID            string
	EmailVerified  bool
	SignInProvider string
	AuthTime       time.Time
}

// Firebase `firebase.sign_in_provider` claim values the verified-identity gate knows (ADR-0010 D5 A10).
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

// IdentityGate is the ADR-0010 D5 A10 allowlist predicate, the one definition shared by
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
