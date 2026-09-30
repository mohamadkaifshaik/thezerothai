package mw_test

import (
	"bytes"
	"context"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// TestLogging_EmitsModuleFields: fields recorded via logger.SetRequestField by a handler (graph_op,
// outcome, txn_attempts, ...) land on the single request line, and re-setting a key replaces it.
func TestLogging_EmitsModuleFields(t *testing.T) {
	var buf bytes.Buffer
	log := slog.New(slog.NewJSONHandler(&buf, nil))

	srv := newTestServer(t, testProcedure, func(ctx context.Context, _ *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		logger.SetRequestField(ctx, "graph_op", "follow")
		logger.SetRequestField(ctx, "txn_attempts", 2)
		logger.SetRequestField(ctx, "txn_attempts", 3)
		return connect.NewResponse(&commonv1.ErrorDetail{}), nil
	}, mw.Logging(log, "demo-project"))

	if _, err := callTestServer(t, srv, testProcedure); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	out := buf.String()
	for _, want := range []string{`"graph_op":"follow"`, `"txn_attempts":3`} {
		if !strings.Contains(out, want) {
			t.Errorf("log output missing %q; got: %s", want, out)
		}
	}
	if strings.Count(out, `"txn_attempts"`) != 1 {
		t.Errorf("txn_attempts should appear once: %s", out)
	}
}
