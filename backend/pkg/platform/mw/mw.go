// Package mw holds the cross-cutting Connect interceptors that are not specific to one platform
// concern: panic recovery, request logging, and the final error-to-Connect-code mapping (ADR-0002,
// ADR-0006 §2, observability skill). Wire order in apiserver.Build must match ADR-0006 §2 (as amended,
// M1: rate limit moved before account status so a profile-less caller cannot bypass the limiter and burn
// unauthenticated Firestore reads; degraded mode moved with it since it is also a free, in-memory check;
// N5: logging moved outermost, ahead of recover, so a panicking request still gets its one log line):
//
//	logging -> recover -> App Check -> ID token -> rate limit -> degraded mode -> account status -> errorMapping
//
// N5/M3: Logging must be outermost. Every other interceptor either calls next() and passes errors through
// unchanged, or short-circuits without ever reaching ErrorMapping (which sits innermost, next to the
// handler) — authn.AccountStatusInterceptor's failed-Firestore-read case is the concrete example. That
// means ErrorMapping's reportError call (below) never runs for those short-circuited errors, and Recover's
// defer never gets a chance to run for a panic if something above it (like the old logging-second order)
// doesn't itself use a defer. Logging, as the true outermost interceptor, is the only frame guaranteed to
// see every request's final (resp, err) exactly once — panic-recovered or not, short-circuited or not — so
// it is the single fallback place that shapes an as-yet-unshaped error into a *connect.Error and reports it
// to Error Reporting if the mapped code is Internal, without ever duplicating a report ErrorMapping or
// Recover already made (see Logging's doc comment).
package mw

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"strings"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// reportedErrorType shapes a log entry so Cloud Error Reporting recognizes it as a
// google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent even though we log via plain slog JSON
// rather than calling the Error Reporting API directly (observability skill: "Errors: Error Reporting
// picks up severity=ERROR logs with stack traces automatically" — the explicit @type plus stack_trace
// makes that pickup reliable instead of best-effort message sniffing).
const reportedErrorType = "type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"

// causeChain flattens err's full errors.Unwrap chain into one message. Most wrapped errors (fmt.Errorf's
// %w) already fold their cause into Error()'s own string, but *apierr.Error deliberately does not — its
// Error() returns only the client-safe Message, with the cause reachable solely via Unwrap/errors.Is/As
// (apierr's doc comment: "wrapped for logs only"). reportError needs that cause to actually show up in the
// log line it produces — Error Reporting groups/alerts on the message text, and errors.Is/As alone would
// leave it invisible there — so this walks the chain and appends any cause not already present in the
// accumulated message (avoiding redundant text for the fmt.Errorf case, where it already is).
func causeChain(err error) string {
	msg := err.Error()
	for cause := errors.Unwrap(err); cause != nil; cause = errors.Unwrap(cause) {
		if causeMsg := cause.Error(); !strings.Contains(msg, causeMsg) {
			msg += ": " + causeMsg
		}
	}
	return msg
}

// reportError logs err (its full cause chain, via causeChain) plus a stack trace as an Error-Reporting-
// shaped ERROR entry (M3). The stack trace is captured here, at the interceptor, not at the original
// panic/error site — Go errors don't carry their origin's frames — so it points at this interceptor rather
// than the failing repo/service call; still enough for Error Reporting to group and alert on the exception
// message, and strictly better than the cause being dropped entirely.
func reportError(ctx context.Context, log *slog.Logger, rpc string, err error) {
	log.ErrorContext(ctx, causeChain(err),
		"@type", reportedErrorType,
		"rpc", rpc,
		"stack_trace", string(debug.Stack()),
	)
}

// Recover converts a panic inside the handler chain into connect.CodeInternal instead of crashing the
// process (CLAUDE.md: "no panics on request paths"). It logs the panic and stack as an Error
// Reporting-shaped entry (M3) so it is never silently lost; the client only ever sees a generic message.
func Recover(log *slog.Logger) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (resp connect.AnyResponse, err error) {
			defer func() {
				if r := recover(); r != nil {
					reportError(ctx, log, req.Spec().Procedure, fmt.Errorf("panic: %v", r))
					err = connect.NewError(connect.CodeInternal, errors.New("internal error"))
				}
			}()
			return next(ctx, req)
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

// Logging emits exactly one JSON log line per request, always at INFO (observability skill: "One log line
// per request, INFO"): rpc, uid_hash, latency_ms, code, fs_reads/fs_writes/fs_deletes, cache_hit is left to
// callers via context if needed. It also seeds the request's budget.Counter, trace correlation field, and
// logger.RequestInfo (M2): uid_hash and app_check_failed are populated by authn's interceptors, which run
// *after* this one in the chain and can only hand data back up to this log line through the mutable
// logger.RequestInfo pointer, never through ctx.WithValue alone (a context value set downstream is
// invisible to an ancestor holding the original ctx).
//
// Logging is also the last-resort error shaper and Error-Reporting fallback (M3/N5 — see the package doc
// comment for why it must be outermost). If the error coming back from next() is already a *connect.Error,
// ErrorMapping or Recover further in have already shaped it and, if Internal, already called reportError
// with the original cause — Logging only reads its Code() for the "code" field and passes it through
// unchanged. If it is *not* yet a *connect.Error (an interceptor between here and ErrorMapping — e.g.
// authn.AccountStatusInterceptor — returned a raw *apierr.Error or other error and short-circuited before
// ever reaching ErrorMapping), Logging is the only frame that ever sees it: it shapes it with
// apierr.ToConnect and, if the result is Internal, calls reportError itself here so the cause still reaches
// Error Reporting instead of being silently dropped. Either way this fires reportError at most once per
// request (never both here and in ErrorMapping/Recover for the same error), fixing the double
// ERROR-severity logging that used to happen when this function also re-logged at ERROR itself.
func Logging(log *slog.Logger, projectID string) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			start := time.Now()

			trace := logger.TraceFromRequestHeader(req.Header(), projectID)
			ctx = logger.WithTrace(ctx, trace)
			ctx, counter := budget.WithCounter(ctx)
			ctx, info := logger.WithRequestInfo(ctx)

			resp, err := next(ctx, req)

			var cerr *connect.Error
			if err != nil {
				var alreadyShaped *connect.Error
				if errors.As(err, &alreadyShaped) {
					cerr = alreadyShaped
				} else {
					cerr = apierr.ToConnect(err)
					if cerr.Code() == connect.CodeInternal {
						reportError(ctx, log, req.Spec().Procedure, err)
					}
				}
			}

			latencyMS := time.Since(start).Milliseconds()
			code := "ok"
			if cerr != nil {
				code = cerr.Code().String()
			}
			uidHash := ""
			if info.UID != "" {
				uidHash = logger.HashUID(info.UID)
			}

			attrs := []any{
				"rpc", req.Spec().Procedure,
				"uid_hash", uidHash,
				"latency_ms", latencyMS,
				"code", code,
				"fs_reads", counter.Reads(),
				"fs_writes", counter.Writes(),
				"fs_deletes", counter.Deletes(),
				"app_check_failed", info.AppCheckFailed,
			}
			if trace != "" {
				attrs = append(attrs, logger.TraceKey, trace)
			}
			log.InfoContext(ctx, "request", attrs...)

			if cerr != nil {
				return nil, cerr
			}
			return resp, nil
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}

// ErrorMapping is the place a service/handler error becomes a *connect.Error with an attached
// dzeroth.common.v1.ErrorDetail (CLAUDE.md: map errors to Connect codes at the handler boundary only).
// It must be the innermost interceptor (closest to the handler) so every interceptor above it — and the
// client — only ever sees fully-shaped Connect errors for anything that actually reaches the handler.
// (An interceptor positioned *before* ErrorMapping that short-circuits without calling next — e.g.
// authn.AccountStatusInterceptor — never reaches this function at all; Logging's doc comment explains the
// fallback that covers that case.)
//
// Being innermost also means it is the only place with access to the raw, unsanitized error (with its
// full %w cause chain) before apierr.ToConnect collapses anything unrecognized to a generic "internal
// error" for the client (M3): when the mapped code is Internal, it logs that raw error here as an
// Error-Reporting-shaped entry so the cause is never silently lost, while the client still only ever sees
// the generic message.
func ErrorMapping(log *slog.Logger) connect.UnaryInterceptorFunc {
	interceptor := func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			resp, err := next(ctx, req)
			if err == nil {
				return resp, nil
			}
			cerr := apierr.ToConnect(err)
			if cerr.Code() == connect.CodeInternal {
				reportError(ctx, log, req.Spec().Procedure, err)
			}
			return nil, cerr
		}
	}
	return connect.UnaryInterceptorFunc(interceptor)
}
