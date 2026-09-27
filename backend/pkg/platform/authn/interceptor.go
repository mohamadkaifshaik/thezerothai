package authn

import (
	"context"
	"strings"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// AppCheckHeader is the header Flutter clients attach on every call (ADR-0006 §2).
const AppCheckHeader = "X-Firebase-AppCheck"

// Mode controls whether a missing/invalid App Check token blocks the request.
type Mode string

const (
	ModeEnforce Mode = "enforce"
	ModeMonitor Mode = "monitor"
)

// AppCheckInterceptor verifies the X-Firebase-AppCheck header. In ModeMonitor a failure is recorded on
// the request's logger.RequestInfo (M2: the one line-per-request log needs app_check_failed, and can only
// see it via that mutable pointer — see mw.Logging's doc comment) but does not block the request, so
// false rejects can be measured before switching to ModeEnforce (ADR-0006 §2).
func AppCheckInterceptor(verifier AppCheckVerifier, mode Mode) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			token := req.Header().Get(AppCheckHeader)
			err := verifyAppCheck(ctx, verifier, token)
			if err == nil {
				return next(ctx, req)
			}
			if mode == ModeMonitor {
				if info := logger.RequestInfoFromContext(ctx); info != nil {
					info.AppCheckFailed = true
				}
				return next(ctx, req)
			}
			return nil, apierr.ToConnect(apierr.New(
				connect.CodeUnauthenticated,
				commonv1.ErrorReason_ERROR_REASON_APP_CHECK_REQUIRED,
				"missing or invalid App Check token",
			).WithCause(err))
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

func verifyAppCheck(ctx context.Context, verifier AppCheckVerifier, token string) error {
	if token == "" {
		return errEmptyAppCheckToken
	}
	return verifier.VerifyToken(ctx, token)
}

var errEmptyAppCheckToken = apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_APP_CHECK_REQUIRED, "missing App Check token")

// IDTokenInterceptor verifies the `Authorization: Bearer <idToken>` header and attaches Claims to the
// context for downstream handlers. Every RPC requires a valid ID token at Stage 0 (ADR-0006 §2). It also
// records the verified uid on logger.RequestInfo (M2) so the one-line-per-request log can include
// uid_hash without every handler/interceptor having to thread claims back up to mw.Logging.
func IDTokenInterceptor(verifier IDTokenVerifier) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			authz := req.Header().Get("Authorization")
			const prefix = "Bearer "
			if !strings.HasPrefix(authz, prefix) || len(authz) <= len(prefix) {
				return nil, apierr.ToConnect(apierr.New(
					connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
					"missing bearer token",
				))
			}
			claims, err := verifier.VerifyIDToken(ctx, strings.TrimPrefix(authz, prefix))
			if err != nil {
				return nil, apierr.ToConnect(apierr.New(
					connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
					"invalid or expired sign-in, please sign in again",
				).WithCause(err))
			}
			if info := logger.RequestInfoFromContext(ctx); info != nil {
				info.UID = claims.UID
			}
			return next(WithClaims(ctx, claims), req)
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

// AccountStatus mirrors identityv1.AccountStatus without importing the identity module (platform code
// must not depend on any internal/<module>; ADR-0002). Callers pass a small adapter.
type AccountStatus int

const (
	AccountStatusUnknown AccountStatus = iota
	AccountStatusActive
	AccountStatusSuspended
	AccountStatusDeleting
)

// AccountStatusProvider looks up whether uid has a profile yet and its status. Implementations should
// be backed by an instance cache (users/{uid}, 60s TTL per ADR-0003) so this costs ~0 extra Firestore
// reads on the hot path.
type AccountStatusProvider interface {
	AccountStatus(ctx context.Context, uid string) (exists bool, status AccountStatus, err error)
}

// ProfileExemptProcedures lists the fully-qualified Connect procedures allowed before a profile exists.
// ADR-0006 names CreateProfile explicitly; CheckHandleAvailability is exempted too because it is a
// read-only, side-effect-free call the sign-up form must be able to make before CreateProfile succeeds
// (documented deviation from the ADR's literal wording — see backend-developer handoff notes).
func ProfileExemptProcedures(procedures ...string) map[string]struct{} {
	set := make(map[string]struct{}, len(procedures))
	for _, p := range procedures {
		set[p] = struct{}{}
	}
	return set
}

// AccountStatusInterceptor rejects SUSPENDED/DELETING accounts and enforces PROFILE_REQUIRED for every
// procedure not in exempt (ADR-0006 §2, §6). Must run after IDTokenInterceptor.
func AccountStatusInterceptor(provider AccountStatusProvider, exempt map[string]struct{}) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if _, ok := exempt[req.Spec().Procedure]; ok {
				return next(ctx, req)
			}
			uid, ok := UIDFromContext(ctx)
			if !ok {
				return nil, apierr.ToConnect(apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated"))
			}
			exists, status, err := provider.AccountStatus(ctx, uid)
			if err != nil {
				// M3: return the raw *apierr.Error (cause attached), not apierr.ToConnect(...) — this
				// interceptor runs before mw.ErrorMapping in the chain and never calls next() on this path,
				// so ErrorMapping never gets a chance to see (and report) this error. Pre-converting here
				// would strip the cause (apierr.ToConnect builds a bare connect.Error with no wrapped
				// error), so it would never reach Cloud Error Reporting. mw.Logging, the outermost
				// interceptor, is the fallback that shapes any not-yet-a-*connect.Error it sees and reports
				// Internal ones with their cause (see mw.Logging's doc comment); the client still only ever
				// sees the generic "internal error" message either way.
				return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(err)
			}
			if !exists {
				return nil, apierr.ToConnect(apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first"))
			}
			switch status {
			case AccountStatusSuspended, AccountStatusDeleting:
				return nil, apierr.ToConnect(apierr.New(connect.CodePermissionDenied, commonv1.ErrorReason_ERROR_REASON_ACCOUNT_RESTRICTED, "account is restricted"))
			}
			return next(ctx, req)
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}
