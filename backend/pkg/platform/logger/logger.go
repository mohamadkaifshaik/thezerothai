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
	"sync"
)

// TraceKey is the Cloud Logging structured-log field that correlates a log line with a Cloud Trace span.
const TraceKey = "logging.googleapis.com/trace"

// LevelNotice is Cloud Logging's NOTICE severity (between INFO and WARNING) for audit lines that are normal but
// must stay greppable and alertable, such as the identity module's one-line-per-Firebase-Auth-mutation record
// (ADR-0011 IAM control C3). New renders it as severity "NOTICE"; slog.Level(2) would otherwise print "INFO+2".
const LevelNotice = slog.LevelInfo + 2

// New builds the process-wide slog.Logger. Cheap: no I/O, safe to call before ListenAndServe.
func New(projectID string) *slog.Logger {
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level:       slog.LevelInfo,
		AddSource:   false,
		ReplaceAttr: replaceAttr,
	})
	return slog.New(h).With("project_id", projectID)
}

// replaceAttr renames slog's level and message keys to Cloud Logging's and renders LevelNotice as NOTICE.
func replaceAttr(_ []string, a slog.Attr) slog.Attr {
	switch a.Key {
	case slog.LevelKey:
		a.Key = "severity"
		if lvl, ok := a.Value.Any().(slog.Level); ok && lvl == LevelNotice {
			a.Value = slog.StringValue("NOTICE")
		}
	case slog.MessageKey:
		a.Key = "message"
	}
	return a
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

// TraceAttrs returns the slog key/value pair that correlates a log line with ctx's Cloud Trace span (see
// WithTrace), or nil when ctx has none, so callers can append it to an attribute list unconditionally:
// `append(attrs, logger.TraceAttrs(ctx)...)`.
func TraceAttrs(ctx context.Context) []any {
	if trace := TraceFromContext(ctx); trace != "" {
		return []any{TraceKey, trace}
	}
	return nil
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
	// ProfileRequired is set by authn.AccountStatusInterceptor when the verified caller has no profile
	// (ADR-0010 D5 A3); ratelimit.Interceptor reads it after next to charge the IP key. Written and read on
	// the request goroutine only (the interceptor chain is synchronous).
	ProfileRequired bool
	// ProfileFound is set by authn.AccountStatusInterceptor when the status lookup finds a profile (any status;
	// ADR-0010 D5 A9, never on a lookup error). ratelimit.Interceptor uses it to clear a stale profile-less mark.
	ProfileFound bool

	// mu guards fields: handlers may fan out under errgroup, and Logging reads after next() returns.
	mu     sync.Mutex
	fields []slog.Attr
}

// Set records a module-specific field (e.g. graph_op, outcome, txn_attempts) for the request's single
// log line. Setting the same key again replaces the earlier value. Values must never be PII.
func (i *RequestInfo) Set(key string, value any) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for n := range i.fields {
		if i.fields[n].Key == key {
			i.fields[n].Value = slog.AnyValue(value)
			return
		}
	}
	i.fields = append(i.fields, slog.Any(key, value))
}

// AddCount adds n to the int64 counter recorded under key (creating it at n), for per-request totals such as
// cache hits that several calls within one request each contribute to. A key previously recorded by Set with a
// non-int64 value is replaced by the counter.
func (i *RequestInfo) AddCount(key string, n int64) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for idx := range i.fields {
		if i.fields[idx].Key == key {
			cur := int64(0)
			if i.fields[idx].Value.Kind() == slog.KindInt64 {
				cur = i.fields[idx].Value.Int64()
			}
			i.fields[idx].Value = slog.Int64Value(cur + n)
			return
		}
	}
	i.fields = append(i.fields, slog.Int64(key, n))
}

// Get returns the value recorded by Set for key.
func (i *RequestInfo) Get(key string) (any, bool) {
	i.mu.Lock()
	defer i.mu.Unlock()
	for _, a := range i.fields {
		if a.Key == key {
			return a.Value.Any(), true
		}
	}
	return nil, false
}

// Fields returns a copy of the recorded fields in insertion order, for the Logging interceptor.
func (i *RequestInfo) Fields() []slog.Attr {
	i.mu.Lock()
	defer i.mu.Unlock()
	return append([]slog.Attr(nil), i.fields...)
}

// SetRequestField records key=value on the request's RequestInfo; a no-op when ctx carries none (unit
// tests, background jobs), so callers never need a nil check.
func SetRequestField(ctx context.Context, key string, value any) {
	if info := RequestInfoFromContext(ctx); info != nil {
		info.Set(key, value)
	}
}

// AddRequestCount adds n to a per-request counter field (see RequestInfo.AddCount); a no-op when ctx carries no
// RequestInfo. Use it, not SetRequestField, for totals that several calls in one request add to.
func AddRequestCount(ctx context.Context, key string, n int64) {
	if info := RequestInfoFromContext(ctx); info != nil {
		info.AddCount(key, n)
	}
}

// RequestField reads a field recorded by SetRequestField.
func RequestField(ctx context.Context, key string) (any, bool) {
	if info := RequestInfoFromContext(ctx); info != nil {
		return info.Get(key)
	}
	return nil, false
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
