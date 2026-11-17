package publicid

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request log fields (mw.Logging's one line per request), set only for a caller with FEATURE_PUBLIC_IDS on.
const (
	// LogFieldIDs is the distinct ids translated, both directions.
	LogFieldIDs = "pubid_ids"
	// LogFieldUnmapped is the distinct response uids with no public id, sent as Tombstone. Should stay 0 outside erased
	// authors.
	LogFieldUnmapped = "pubid_unmapped"
	// LogFieldUnknown is the distinct well-formed request public ids that resolved to nobody (caller-controlled, so
	// kept apart from LogFieldUnmapped).
	LogFieldUnknown = "pubid_unknown"
	// LogFieldReads is the resolver calls (batched lookups, both directions). Not Firestore reads: a warm call reads
	// nothing, a cold one reads one GetAll per chunk of misses.
	LogFieldReads = "pubid_reads"
)

// RecordStats writes s onto the request's log line (logger.RequestInfo). It is the interceptor's default recorder.
func RecordStats(ctx context.Context, s Stats) {
	logger.SetRequestField(ctx, LogFieldIDs, s.InboundIDs+s.OutboundIDs)
	logger.SetRequestField(ctx, LogFieldUnmapped, s.OutboundUnmapped)
	logger.SetRequestField(ctx, LogFieldUnknown, s.InboundUnknown)
	logger.SetRequestField(ctx, LogFieldReads, s.ResolverCalls)
}

// NewInterceptor is the edge translation: a Connect unary interceptor that, for a caller with FEATURE_PUBLIC_IDS on,
// rewrites the request message from wire to internal form before the handler and the response message from internal
// to wire form after it. It sits innermost, after mw.ErrorMapping, and behaves as part of the handler: its errors are
// shaped (and Internal ones reported) by ErrorMapping like a handler's.
//
//   - enabled says whether the caller (read from ctx) has the flag on. nil means the flag is globally off: the
//     interceptor is then the identity and adds nothing to the chain. A false answer costs one call and no allocation.
//   - record receives the request's Stats when enabled; nil means RecordStats.
//
// With the flag on: a request value that is not a public id is an *apierr.Error VALIDATION naming the field, returned
// before the handler runs. A lookup cut short by the request's end is CANCELED or DEADLINE_EXCEEDED. Any other failure
// (a lookup error, a message type with no plan) is Internal, inbound or
// outbound, and outbound the untranslated response is dropped, never returned (for a mutation the write has
// committed; a retry with the same idempotency key replays). A handler error passes through untouched: error details
// carry no user id (apierr metadata holds field, feature, limit, reason, state, quota, policy, media id or a poll
// choice).
func NewInterceptor(tr *Translator, enabled func(context.Context) bool, record func(context.Context, Stats)) (connect.UnaryInterceptorFunc, error) {
	if tr == nil {
		return nil, errors.New("publicid: nil translator")
	}
	if enabled == nil {
		return func(next connect.UnaryFunc) connect.UnaryFunc { return next }, nil
	}
	if record == nil {
		record = RecordStats
	}
	return func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			if !enabled(ctx) {
				return next(ctx, req)
			}
			return tr.intercept(ctx, req, next, record)
		}
	}, nil
}

func (t *Translator) intercept(ctx context.Context, req connect.AnyRequest, next connect.UnaryFunc, record func(context.Context, Stats)) (connect.AnyResponse, error) {
	in, ok := req.Any().(proto.Message)
	if !ok || in == nil {
		return nil, internal(fmt.Errorf("publicid: %s: request %T is not a proto message", req.Spec().Procedure, req.Any()))
	}
	st, err := t.TranslateRequest(ctx, in)
	if err != nil {
		// Only the walker's own validation answer is client-facing, so the assertion is deliberately not errors.As: a
		// wrapped error (a resolver's, whatever it wraps) must not lend its code to the response.
		if ae, isValidation := err.(*apierr.Error); isValidation {
			return nil, ae
		}
		return nil, failure(ctx, fmt.Errorf("publicid: %s: request: %w", req.Spec().Procedure, err))
	}
	resp, err := next(ctx, req)
	if err != nil {
		record(ctx, st.Stats())
		return resp, err
	}
	if resp == nil {
		record(ctx, st.Stats())
		return nil, nil
	}
	out, ok := resp.Any().(proto.Message)
	if !ok || out == nil {
		return nil, internal(fmt.Errorf("publicid: %s: response %T is not a proto message", req.Spec().Procedure, resp.Any()))
	}
	stats, err := t.TranslateResponse(ctx, st, out)
	record(ctx, stats)
	if err != nil {
		return nil, failure(ctx, fmt.Errorf("publicid: %s: response: %w", req.Spec().Procedure, err))
	}
	return resp, nil
}

// failure shapes a lookup failure: the request's end (a client cancel or its deadline, seen on ctx or in the cause)
// answers CANCELED or DEADLINE_EXCEEDED like the modules' own mapErr helpers, which ErrorMapping does not report as an
// error; anything else is Internal.
func failure(ctx context.Context, err error) error {
	switch {
	case errors.Is(ctx.Err(), context.Canceled), errors.Is(err, context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled").WithCause(err)
	case errors.Is(ctx.Err(), context.DeadlineExceeded), errors.Is(err, context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded").WithCause(err)
	}
	return internal(err)
}

// internal is the generic Internal answer with err attached for ErrorMapping's report (never sent to the client).
func internal(err error) error {
	return apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(err)
}
