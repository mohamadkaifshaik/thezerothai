package apiserver

import (
	"log/slog"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// chainDeps is everything the Connect interceptor chain is built from (chainInterceptors).
type chainDeps struct {
	log            *slog.Logger
	projectID      string
	appCheck       authn.AppCheckVerifier
	appCheckMode   authn.Mode
	idVerifier     authn.IDTokenVerifier
	profileExempt  map[string]struct{}
	allowAnonymous bool
	// sessionCuts and sessionCutOn feed authn.SessionCutInterceptor: identity's cached cut and "device_sign_out is not
	// globally off" (asked per request).
	sessionCuts   authn.SessionCutProvider
	sessionCutOn  func() bool
	rateLimit     ratelimit.Config
	degradedMode  config.DegradedMode
	media         degraded.ProcedureSet
	accountStatus authn.AccountStatusProvider
	restricted    []string
	publicIDs     connect.Interceptor
}

// sessionCutEnforced is the enforcement switch of the session cut: on unless device_sign_out is GLOBALLY off. Never "on
// for the caller": dropping a user from the allowlist (or a percent change) must not reopen that user's cut thief, and
// globally off is the emergency lever if the check locks people out.
func sessionCutEnforced(fl interface{ GloballyOff(name string) bool }) func() bool {
	return func() bool { return !fl.GloballyOff(keys.DeviceSignOutFlag) }
}

// chainInterceptors is the Connect interceptor chain in order (outermost first). It is a function of its inputs alone so
// the chain-order test (chain_test.go) runs exactly what Build wires.
//
// The session cut (authn.SessionCutInterceptor, security audit H2) runs after the 0-read verified-identity gate and
// BEFORE the rate limiter: a session refused with SESSION_ENDED draws on no per-minute bucket and no daily cap (notably
// messages_commits_daily), so a cut thief cannot keep using up the honest user's caps. Its lookup is the identity profile
// cache account status uses (60 s, 10 s negative), so the read only moves earlier in the chain; it is not added. While
// device_sign_out is globally off it reads nothing.
func chainInterceptors(d chainDeps) []connect.Interceptor {
	return []connect.Interceptor{
		mw.Logging(d.log, d.projectID),
		mw.Recover(d.log),
		authn.AppCheckInterceptor(d.appCheck, d.appCheckMode),
		authn.IDTokenInterceptor(d.idVerifier),
		// 0-read verified-identity gate (sign-in provider allowlist). Callers outside it never
		// reach the rate limiter, so a minted uid creates no limiter key and no Firestore read. Anonymous passes
		// only against the Auth emulator.
		authn.VerifiedIdentityInterceptor(d.profileExempt, d.allowAnonymous),
		authn.SessionCutInterceptor(d.sessionCuts, d.sessionCutOn),
		ratelimit.Interceptor(d.rateLimit),
		degraded.Interceptor(d.degradedMode, d.media),
		authn.AccountStatusInterceptor(d.accountStatus, d.profileExempt, authn.AllowRestricted(d.restricted...)),
		mw.ErrorMapping(d.log),
		d.publicIDs,
	}
}
