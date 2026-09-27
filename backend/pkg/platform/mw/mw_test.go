package mw_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// newTestServer builds a minimal end-to-end Connect handler+server so interceptors see a fully
// populated Spec/Header, exactly like they would in main.go. Reusing commonv1.ErrorDetail as a stand-in
// message keeps this self-contained (no need for a dedicated test .proto).
func newTestServer(t *testing.T, procedure string, handlerFn func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error), interceptors ...connect.Interceptor) *httptest.Server {
	t.Helper()
	opts := make([]connect.HandlerOption, 0, len(interceptors))
	for _, ic := range interceptors {
		opts = append(opts, connect.WithInterceptors(ic))
	}
	h := connect.NewUnaryHandler(procedure, handlerFn, opts...)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func callTestServer(t *testing.T, srv *httptest.Server, procedure string) (*connect.Response[commonv1.ErrorDetail], error) {
	t.Helper()
	client := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+procedure)
	return client.CallUnary(context.Background(), connect.NewRequest(&commonv1.ErrorDetail{}))
}

const testProcedure = "/test.Service/Method"

func TestRecover_ConvertsPanicToInternal(t *testing.T) {
	log := slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		panic("boom")
	}, mw.Recover(log))

	_, err := callTestServer(t, srv, testProcedure)
	if err == nil {
		t.Fatal("expected an error, got nil (panic should not crash the process)")
	}
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != connect.CodeInternal {
		t.Fatalf("Code() = %v, want Internal", cerr.Code())
	}
}

// TestRecover_LogsErrorReportingShapedEntry (M3): the panic must be logged with the fields Cloud Error
// Reporting recognizes (@type, stack_trace) — never just silently converted to a generic client error.
func TestRecover_LogsErrorReportingShapedEntry(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		panic("boom")
	}, mw.Recover(log))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}
	out := buf.String()
	for _, want := range []string{
		`"@type":"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"`,
		`"stack_trace"`,
		`"rpc":"` + testProcedure + `"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q; got: %s", want, out)
		}
	}
}

func TestRecover_PassesThroughOnSuccess(t *testing.T) {
	log := slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
	srv := newTestServer(t, testProcedure, func(_ context.Context, req *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return connect.NewResponse(&commonv1.ErrorDetail{Message: "ok"}), nil
	}, mw.Recover(log))

	resp, err := callTestServer(t, srv, testProcedure)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.Msg.GetMessage() != "ok" {
		t.Fatalf("Message = %q", resp.Msg.GetMessage())
	}
}

// TestReportError_IncludesApierrCauseInMessage (M3): apierr.Error.Error() deliberately hides the wrapped
// cause (client-safe by design), so reportError's message must surface it explicitly or Error Reporting
// would group every internal error from an interceptor under the single indistinguishable text
// "internal error". Exercised indirectly through mw.Recover here since causeChain itself is unexported;
// see also the more end-to-end assertions in the TestLogging_* tests below.
func TestReportError_IncludesApierrCauseInMessage(t *testing.T) {
	var buf bytes.Buffer
	log := newCloudLoggingTestLogger(&buf)
	cause := errors.New("firestore: deadline exceeded")

	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(cause)
	}, mw.ErrorMapping(log))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(buf.String(), cause.Error()) {
		t.Errorf("log message must include the wrapped cause, not just the client-safe message; got: %s", buf.String())
	}
}

func TestErrorMapping_ConvertsAppError(t *testing.T) {
	log := slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "bad input")
	}, mw.ErrorMapping(log))

	_, err := callTestServer(t, srv, testProcedure)
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != connect.CodeInvalidArgument {
		t.Fatalf("Code() = %v, want InvalidArgument", cerr.Code())
	}
	if len(cerr.Details()) != 1 {
		t.Fatalf("expected 1 error detail, got %d", len(cerr.Details()))
	}
}

func TestErrorMapping_UnknownErrorHidesInternals(t *testing.T) {
	log := slog.New(slog.NewTextHandler(&bytes.Buffer{}, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, errors.New("stack trace with secret=abc123")
	}, mw.ErrorMapping(log))

	_, err := callTestServer(t, srv, testProcedure)
	if err == nil || strings.Contains(err.Error(), "secret=abc123") {
		t.Fatalf("internal error details leaked to client: %v", err)
	}
}

// TestErrorMapping_LogsCauseAsErrorReportingShapedEntry (M3): an unknown/internal error's cause must be
// logged (with @type/stack_trace) here, at the boundary that still holds the raw error, even though the
// client only ever sees the generic "internal error" message (asserted above).
func TestErrorMapping_LogsCauseAsErrorReportingShapedEntry(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, fmt.Errorf("identity: get profile uid-1: %w", errors.New("firestore unavailable"))
	}, mw.ErrorMapping(log))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}
	out := buf.String()
	for _, want := range []string{
		`"@type":"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"`,
		`"stack_trace"`,
		"firestore unavailable",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q; got: %s", want, out)
		}
	}
}

// TestErrorMapping_DoesNotLogNonInternalErrors: a validation error is an expected, client-caused outcome,
// not a bug — it must not be logged as an Error Reporting entry (that would flood Error Reporting with
// noise instead of real bugs).
func TestErrorMapping_DoesNotLogNonInternalErrors(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, "bad input")
	}, mw.ErrorMapping(log))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}
	if buf.Len() != 0 {
		t.Errorf("expected no log output for a non-internal error, got: %s", buf.String())
	}
}

func TestLogging_RecordsRequestLine(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	srv := newTestServer(t, testProcedure, func(ctx context.Context, req *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		budget.FromContext(ctx).AddReads(3)
		budget.FromContext(ctx).AddWrites(1)
		return connect.NewResponse(&commonv1.ErrorDetail{}), nil
	}, mw.Logging(log, "demo-project"))

	if _, err := callTestServer(t, srv, testProcedure); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	for _, want := range []string{`"rpc":"` + testProcedure, `"fs_reads":3`, `"fs_writes":1`, `"code":"ok"`} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q; got: %s", want, out)
		}
	}
}

// TestLogging_RecordsUIDHashAndAppCheckFailed (M2): uid_hash and app_check_failed are set by inner
// interceptors (authn.IDTokenInterceptor, authn.AppCheckInterceptor) on the mutable logger.RequestInfo
// mw.Logging attaches to ctx — a plain ctx.WithValue by an inner interceptor would be invisible here,
// since Logging only ever holds its own original ctx once next() returns. This test stands in for those
// interceptors with a handler that mutates the same RequestInfo, isolating the wiring contract itself
// (the interceptor-level test lives in pkg/platform/authn/interceptor_test.go).
func TestLogging_RecordsUIDHashAndAppCheckFailed(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	srv := newTestServer(t, testProcedure, func(ctx context.Context, req *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		info := logger.RequestInfoFromContext(ctx)
		if info == nil {
			t.Fatal("expected mw.Logging to have attached a logger.RequestInfo")
		}
		info.UID = "uid-1"
		info.AppCheckFailed = true
		return connect.NewResponse(&commonv1.ErrorDetail{}), nil
	}, mw.Logging(log, "demo-project"))

	if _, err := callTestServer(t, srv, testProcedure); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"uid_hash":"`+expectedUIDHash+`"`) {
		t.Errorf("log output missing uid_hash for uid-1; got: %s", out)
	}
	if !strings.Contains(out, `"app_check_failed":true`) {
		t.Errorf("log output missing app_check_failed=true; got: %s", out)
	}
}

// expectedUIDHash mirrors logger.HashUID("uid-1") so the test above doesn't depend on that function's
// exact algorithm, only that Logging calls it with the RequestInfo.UID an inner interceptor set.
var expectedUIDHash = logger.HashUID("uid-1")

func TestLogging_RecordsErrorCode(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("nope"))
	}, mw.Logging(log, "demo-project"))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(buf.String(), `"code":"not_found"`) {
		t.Errorf("log output missing not_found code; got: %s", buf.String())
	}
}

// reportedErrorEventMarker is the same Error-Reporting-shaped @type mw.reportError attaches; duplicated
// here (unexported in mw) since the tests below need to count occurrences, not just check presence.
const reportedErrorEventMarker = `"@type":"type.googleapis.com/google.devtools.clouderrorreporting.v1beta1.ReportedErrorEvent"`

// newCloudLoggingTestLogger mirrors logger.New's ReplaceAttr (severity/message key renames, Cloud
// Logging-shaped) but writes to buf instead of os.Stdout, so tests below can assert on the exact field
// names Cloud Logging (and Error Reporting's severity=ERROR pickup) actually see, rather than slog's
// un-renamed defaults ("level"/"msg") that the other tests in this file don't need to distinguish.
func newCloudLoggingTestLogger(buf *bytes.Buffer) *slog.Logger {
	h := slog.NewJSONHandler(buf, &slog.HandlerOptions{
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
	return slog.New(h)
}

// TestLogging_ReportsRawApierrErrorFromShortCircuitingInterceptor (M3): an interceptor positioned before
// mw.ErrorMapping that short-circuits without ever calling next — exactly what
// authn.AccountStatusInterceptor does on a failed Firestore read — never reaches ErrorMapping's
// reportError call. mw.Logging, wired as the outermost interceptor (N5), must be the fallback that shapes
// the raw, not-yet-a-*connect.Error it receives and still reports its cause to Error Reporting, while the
// client only ever sees the generic message.
func TestLogging_ReportsRawApierrErrorFromShortCircuitingInterceptor(t *testing.T) {
	var buf bytes.Buffer
	log := newCloudLoggingTestLogger(&buf)
	cause := errors.New("firestore: deadline exceeded")
	shortCircuit := connect.UnaryInterceptorFunc(func(connect.UnaryFunc) connect.UnaryFunc {
		return func(context.Context, connect.AnyRequest) (connect.AnyResponse, error) {
			return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(cause)
		}
	})
	handlerCalled := false

	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		handlerCalled = true
		return connect.NewResponse(&commonv1.ErrorDetail{}), nil
	}, mw.Logging(log, "demo-project"), shortCircuit)

	_, err := callTestServer(t, srv, testProcedure)
	if handlerCalled {
		t.Fatal("handler must never run: shortCircuit returns before calling next")
	}
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != connect.CodeInternal {
		t.Fatalf("Code() = %v, want Internal", cerr.Code())
	}
	if strings.Contains(cerr.Error(), cause.Error()) {
		t.Fatalf("cause leaked to the client: %v", cerr)
	}

	out := buf.String()
	for _, want := range []string{reportedErrorEventMarker, `"stack_trace"`, cause.Error()} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q; got: %s", want, out)
		}
	}
}

// TestLogging_DoesNotDoubleReportWhenErrorMappingAlreadyReported: fixes the double ERROR-severity logging
// bug (M3) — for a handler-path Internal error, ErrorMapping already shapes it into a *connect.Error and
// already calls reportError with the cause; Logging (outermost) must recognize the error is already shaped
// and only read its Code() for the "code" field, never re-report or re-log at ERROR itself.
func TestLogging_DoesNotDoubleReportWhenErrorMappingAlreadyReported(t *testing.T) {
	var buf bytes.Buffer
	log := newCloudLoggingTestLogger(&buf)
	cause := errors.New("firestore: deadline exceeded")

	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(cause)
	}, mw.Logging(log, "demo-project"), mw.ErrorMapping(log))

	if _, err := callTestServer(t, srv, testProcedure); err == nil {
		t.Fatal("expected an error")
	}

	out := buf.String()
	if got := strings.Count(out, reportedErrorEventMarker); got != 1 {
		t.Errorf("expected exactly one Error-Reporting-shaped entry, got %d; log: %s", got, out)
	}
	if got := strings.Count(out, `"severity":"ERROR"`); got != 1 {
		t.Errorf("expected exactly one severity=ERROR log line (no double ERROR logging), got %d; log: %s", got, out)
	}
	if !strings.Contains(out, `"code":"internal"`) {
		t.Errorf("expected the per-request INFO line to still record code=internal; got: %s", out)
	}
}

// TestLogging_EmitsRequestLineWhenRecoverCatchesPanic (N5): Logging must be outermost so a panicking
// request still gets exactly one per-request log line (with trace/code/fs_reads) instead of the panic
// unwinding straight past Logging's post-call code to Recover's defer, skipping the log line entirely.
func TestLogging_EmitsRequestLineWhenRecoverCatchesPanic(t *testing.T) {
	var buf bytes.Buffer
	log := newCloudLoggingTestLogger(&buf)

	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		panic("boom")
	}, mw.Logging(log, "demo-project"), mw.Recover(log))

	const traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	client := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+testProcedure)
	req := connect.NewRequest(&commonv1.ErrorDetail{})
	req.Header().Set("traceparent", traceparent)
	_, err := client.CallUnary(context.Background(), req)

	var cerr *connect.Error
	if !errors.As(err, &cerr) || cerr.Code() != connect.CodeInternal {
		t.Fatalf("expected an Internal *connect.Error, got %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"message":"request"`) {
		t.Errorf("log output missing the per-request line for a panicking request; got: %s", out)
	}
	if !strings.Contains(out, `"rpc":"`+testProcedure) {
		t.Errorf("log output missing rpc field; got: %s", out)
	}
	if !strings.Contains(out, `"code":"internal"`) {
		t.Errorf("log output missing code=internal; got: %s", out)
	}
	if !strings.Contains(out, `"logging.googleapis.com/trace":"projects/demo-project/traces/4bf92f3577b34da6a3ce929d0e0e4736"`) {
		t.Errorf("log output missing the trace field on the per-request line; got: %s", out)
	}
	if got := strings.Count(out, reportedErrorEventMarker); got != 1 {
		t.Errorf("expected exactly one Error-Reporting-shaped entry for the panic, got %d; log: %s", got, out)
	}
}
