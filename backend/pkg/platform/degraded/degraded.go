// Package degraded implements the DEGRADED_MODE switch (CLAUDE.md, ADR-0007 cost-spike runbook):
// "readonly" rejects mutating RPCs, "nomedia" rejects media-upload RPCs, "off" is normal operation.
// Flipping it is a Cloud Run env var update (seconds, no image rebuild).
package degraded

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// retryAfter is a conservative hint: degraded mode is a human-flipped switch, not a short-lived
// backpressure signal, so clients should back off longer than a rate limit retry.
const retryAfter = 60 * time.Second

// ProcedureSet is a fully-qualified Connect procedure allow/deny list, e.g. built from the generated
// `<Service><Method>Procedure` constants of the services wired into main.go.
type ProcedureSet map[string]struct{}

// NewProcedureSet is a small constructor so callers can write NewProcedureSet(identityv1connect.IdentityServiceCreateProfileProcedure, ...).
func NewProcedureSet(procedures ...string) ProcedureSet {
	set := make(ProcedureSet, len(procedures))
	for _, p := range procedures {
		set[p] = struct{}{}
	}
	return set
}

// Interceptor rejects requests disallowed by the current mode. In "readonly" mode, mutating is derived
// mechanically from each RPC's declared `idempotency_level` (proto: NO_SIDE_EFFECTS = read-only,
// everything else = mutating) via req.Spec().IdempotencyLevel — no hand-maintained list to go stale. In
// "nomedia" mode, media lists the media-upload procedures to block (no mechanical signal for that).
func Interceptor(mode config.DegradedMode, media ProcedureSet) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			switch mode {
			case config.DegradedReadonly:
				if req.Spec().IdempotencyLevel != connect.IdempotencyNoSideEffects {
					return nil, blockedErr("the service is temporarily read-only, please try again shortly")
				}
			case config.DegradedNoMedia:
				if _, blocked := media[req.Spec().Procedure]; blocked {
					return nil, blockedErr("media uploads are temporarily disabled, please try again shortly")
				}
			case config.DegradedOff:
				// fall through
			}
			return next(ctx, req)
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

func blockedErr(msg string) error {
	return apierr.ToConnect(apierr.New(
		connect.CodeUnavailable,
		commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE,
		msg,
	).WithRetryAfter(retryAfter))
}
