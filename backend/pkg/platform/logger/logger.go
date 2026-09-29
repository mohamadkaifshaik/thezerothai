// Package logger provides a single slog JSON logger, shaped for Cloud Logging: "severity" and
// "message" keys, a Cloud Trace correlation field, and a per-request line with rpc/uid_hash/
// fs_reads/fs_writes/latency_ms/code (observability skill). No request/response bodies, no PII,
// tokens or post text are ever logged.
package logger

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"net/http"
	"os"
	"strings"
)

// TraceKey is the Cloud Logging structured-log field that correlates a log line with a Cloud Trace span.
const TraceKey = "logging.googleapis.com/trace"

// New builds the process-wide slog.Logger. Cheap: no I/O, safe to call before ListenAndServe.
func New(projectID string) *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level:     slog.LevelInfo,
		AddSource: false,
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.LevelKey:
				a.Key = "severity"
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	})
	return slog.New(h).With("project_id", projectID)
}

type traceCtxKey struct{}

// WithTrace attaches the Cloud Trace resource name to ctx so handlers/loggers downstream can include it.
func WithTrace(ctx context.Context, trace string) context.Context {
	if trace == "" {
		return ctx
	}
	return context.WithValue(ctx, traceCtxKey{}, trace)
}

// TraceFromContext returns the trace resource name attached by WithTrace, or "".
func TraceFromContext(ctx context.Context) string {
	v, _ := ctx.Value(traceCtxKey{}).(string)
	return v
}

// TraceFromRequest extracts a Cloud Trace resource name ("projects/{p}/traces/{id}") from the standard
// W3C `traceparent` header, falling back to Google's `X-Cloud-Trace-Context`. Returns "" if neither is set.
func TraceFromRequest(r *http.Request, projectID string) string {
	return TraceFromRequestHeader(r.Header, projectID)
}

// TraceFromRequestHeader is TraceFromRequest for callers that only have http.Header (e.g. Connect's
// connect.AnyRequest.Header(), which is not backed by a full *http.Request).
func TraceFromRequestHeader(h http.Header, projectID string) string {
	if tp := h.Get("traceparent"); tp != "" {
		// 00-<32 hex trace id>-<16 hex span id>-<2 hex flags>
		parts := strings.Split(tp, "-")
		if len(parts) == 4 && len(parts[1]) == 32 {
			return "projects/" + projectID + "/traces/" + parts[1]
		}
	}
	if xct := h.Get("X-Cloud-Trace-Context"); xct != "" {
		id := xct
		if i := strings.IndexByte(xct, '/'); i >= 0 {
			id = xct[:i]
		}
		if id != "" {
			return "projects/" + projectID + "/traces/" + id
		}
	}
	return ""
}

// HashUID returns a short, irreversible-enough (for log-grep, not crypto) identifier for a Firebase UID
// so request logs can be correlated per user without logging PII directly.
func HashUID(uid string) string {
	if uid == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(uid))
	return hex.EncodeToString(sum[:8])
}

// RequestInfo is a small mutable struct attached to the request context once, by the Logging interceptor
// (the interceptor closest to the top of the chain, so its one log line runs after every inner
// interceptor has had a chance to run) so inner interceptors — App Check, ID token — can surface fields
// that log line needs (uid_hash, app_check_failed) even though they only see a *derived* ctx and cannot
// hand mutations back up to an ancestor through a returned (resp, err) alone. This mirrors the
// budget.Counter pattern (pkg/platform/budget) rather than introducing a new mechanism.
type RequestInfo struct {
	// UID is the verified caller, set by authn.IDTokenInterceptor on success. Empty until then.
	UID string
	// AppCheckFailed records whether App Check verification failed even though the request was allowed
	// through in APP_CHECK_MODE=monitor (set by authn.AppCheckInterceptor).
	AppCheckFailed bool
	// XFFHops is the number of comma-separated X-Forwarded-For entries seen, and ViaHosting records
	// whether the rightmost one was recognized as a Google Front End / Firebase Hosting egress address
	// rather than the real client (set by ratelimit.Interceptor; see ratelimit.ResolveClientIP). M2,
	// 2026-09-27 security audit: this is what makes TRUSTED_PROXY_HOPS measurable from real dev traffic —
	// the previous mechanism logged the same count at Debug, which Cloud Run's default Info level drops
	// before it is ever written. Deliberately a count and a bool, never an IP address (PII).
	XFFHops    int
	ViaHosting bool
	// LimitName identifies which in-memory limiter rejected the request (set by ratelimit.Interceptor,
	// e.g. "graph_list_daily" for the ADR-0008 T4 per-uid daily list cap), empty when nothing was rejected
	// or the rejection came from elsewhere (a Firestore quota). Observability skill / ADR-0008: every graph
	// RPC logs limit_name so `abuse-spike.md` can query rejections by limiter.
	LimitName string
}

type requestInfoCtxKey struct{}

// WithRequestInfo attaches a fresh, zero-value RequestInfo to ctx, returning the new context and a
// pointer inner interceptors can mutate in place.
func WithRequestInfo(ctx context.Context) (context.Context, *RequestInfo) {
	info := &RequestInfo{}
	return context.WithValue(ctx, requestInfoCtxKey{}, info), info
}

// RequestInfoFromContext returns the RequestInfo attached by WithRequestInfo, or nil if none is attached
// (e.g. a test that exercises an inner interceptor directly, without Logging above it) — callers must
// nil-check before writing to the fields.
func RequestInfoFromContext(ctx context.Context) *RequestInfo {
	info, _ := ctx.Value(requestInfoCtxKey{}).(*RequestInfo)
	return info
}

// L returns the logger attached to ctx via WithLogger, or the fallback if none is attached. Use this in
// service/repo code that wants to add fields (rpc-scoped) without threading *slog.Logger through every call.
func L(ctx context.Context, fallback *slog.Logger) *slog.Logger {
	if v, ok := ctx.Value(loggerCtxKey{}).(*slog.Logger); ok && v != nil {
		return v
	}
	return fallback
}

type loggerCtxKey struct{}

// WithLogger attaches a (possibly request-scoped, field-enriched) logger to ctx.
func WithLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, loggerCtxKey{}, l)
}
