package degraded_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/degraded"
)

const (
	readProcedure  = "/test.Service/Read"
	writeProcedure = "/test.Service/Write"
	mediaProcedure = "/test.Service/UploadMedia"
)

func okHandler(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
	return connect.NewResponse(&commonv1.ErrorDetail{}), nil
}

func newServer(t *testing.T, procedure string, idempotency connect.IdempotencyLevel, mode config.DegradedMode, media degraded.ProcedureSet) *httptest.Server {
	t.Helper()
	h := connect.NewUnaryHandler(procedure, okHandler,
		connect.WithIdempotency(idempotency),
		connect.WithInterceptors(degraded.Interceptor(mode, media)),
	)
	mux := http.NewServeMux()
	mux.Handle(procedure, h)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, procedure string) error {
	t.Helper()
	client := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+procedure)
	_, err := client.CallUnary(context.Background(), connect.NewRequest(&commonv1.ErrorDetail{}))
	return err
}

func TestInterceptor_Off_AllowsEverything(t *testing.T) {
	srv := newServer(t, writeProcedure, connect.IdempotencyIdempotent, config.DegradedOff, nil)
	if err := call(t, srv, writeProcedure); err != nil {
		t.Fatalf("unexpected error in off mode: %v", err)
	}
}

func TestInterceptor_Readonly_BlocksMutating(t *testing.T) {
	srv := newServer(t, writeProcedure, connect.IdempotencyIdempotent, config.DegradedReadonly, nil)
	err := call(t, srv, writeProcedure)
	if err == nil {
		t.Fatal("expected mutating RPC to be blocked in readonly mode")
	}
	assertReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE, connect.CodeUnavailable)
}

func TestInterceptor_Readonly_AllowsNoSideEffects(t *testing.T) {
	srv := newServer(t, readProcedure, connect.IdempotencyNoSideEffects, config.DegradedReadonly, nil)
	if err := call(t, srv, readProcedure); err != nil {
		t.Fatalf("expected read-only RPC to pass in readonly mode: %v", err)
	}
}

func TestInterceptor_NoMedia_BlocksListedProcedure(t *testing.T) {
	media := degraded.NewProcedureSet(mediaProcedure)
	srv := newServer(t, mediaProcedure, connect.IdempotencyIdempotent, config.DegradedNoMedia, media)
	err := call(t, srv, mediaProcedure)
	if err == nil {
		t.Fatal("expected media RPC to be blocked in nomedia mode")
	}
	assertReason(t, err, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE, connect.CodeUnavailable)
}

func TestInterceptor_NoMedia_AllowsUnlistedProcedure(t *testing.T) {
	media := degraded.NewProcedureSet(mediaProcedure)
	srv := newServer(t, writeProcedure, connect.IdempotencyIdempotent, config.DegradedNoMedia, media)
	if err := call(t, srv, writeProcedure); err != nil {
		t.Fatalf("expected non-media RPC to pass in nomedia mode: %v", err)
	}
}

func assertReason(t *testing.T, err error, want commonv1.ErrorReason, wantCode connect.Code) {
	t.Helper()
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != wantCode {
		t.Fatalf("Code() = %v, want %v", cerr.Code(), wantCode)
	}
	for _, d := range cerr.Details() {
		msg, err := d.Value()
		if err != nil {
			continue
		}
		if detail, ok := msg.(*commonv1.ErrorDetail); ok {
			if detail.GetReason() == want {
				return
			}
		}
	}
	t.Fatalf("expected ErrorReason %v in details, got none matching", want)
}
