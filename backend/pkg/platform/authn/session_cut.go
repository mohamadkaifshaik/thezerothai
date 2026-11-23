package authn

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// SessionCutProvider answers the account's session cut (users/{uid}.sessionsValidAfter, identity.SessionCuts): zero for
// none or for a uid without a profile. Implementations must read the same instance cache account status uses (60 s,
// with the 10 s negative cache), so the check adds no Firestore read to a request.
type SessionCutProvider interface {
	SessionsValidAfter(ctx context.Context, uid string) (time.Time, error)
}

// fieldSessionCutRefused is the request-line field set on a refusal. Never a time or a uid.
const fieldSessionCutRefused = "session_cut_refused"

// SessionCutInterceptor refuses a session that signed in before the account's session cut (a REMOTE device removal with
// FEATURE_DEVICE_SIGN_OUT on for the remover; removal-server design 3.3). Must run after IDTokenInterceptor and
// VerifiedIdentityInterceptor and BEFORE the rate limiter, so a refused call draws on no per-minute bucket and no daily
// cap (a cut thief cannot keep using up the honest user's caps).
//
//   - enabled() false (the flag globally off, the emergency lever): no check, no read;
//   - no claims, or no cut: pass;
//   - Claims.AuthTime >= cut: pass (the remover's own session has auth_time equal to the cut);
//   - a zero AuthTime with a cut set, or an AuthTime before it: UNAUTHENTICATED + SESSION_ENDED (fail closed), with
//     session_cut_refused=true on the request line and no time or uid in any field;
//   - a provider error: INTERNAL, the raw *apierr.Error with its cause (as AccountStatusInterceptor, M3).
//
// enabled is asked on every request. A refresh keeps auth_time, so only a real sign-in passes the cut.
func SessionCutInterceptor(provider SessionCutProvider, enabled func() bool) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if !enabled() {
				return next(ctx, req)
			}
			claims, ok := ClaimsFromContext(ctx)
			if !ok {
				return next(ctx, req)
			}
			cut, err := provider.SessionsValidAfter(ctx, claims.UID)
			if err != nil {
				return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(err)
			}
			if cut.IsZero() || (!claims.AuthTime.IsZero() && !claims.AuthTime.Before(cut)) {
				return next(ctx, req)
			}
			logger.SetRequestField(ctx, fieldSessionCutRefused, true)
			return nil, apierr.ToConnect(apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_SESSION_ENDED,
				"you were signed out on this device, please sign in again"))
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}
