package mw_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// reportError is the safety net under callers that forgot to redact: a Firestore document path or a composite edge id in the
// cause chain never reaches the ERROR line, while the rest of the message (what Error Reporting groups on) and an already
// hashed id stay readable.
func TestReportError_ScrubsUnredactedIdentifiers(t *testing.T) {
	t.Parallel()
	const uid = "AbCdEfGhIjKlMnOpQrStUvWxYz12"
	const other = "ZyXwVuTsRqPoNmLkJiHgFeDcBa98"
	tests := []struct {
		name     string
		err      error
		mustNot  []string
		mustKeep []string
	}{
		{
			name:     "document path in a wrapped cause",
			err:      fmt.Errorf("graph: follow: %w", errors.New("rpc error: code = Internal desc = documents/users/"+uid+"/following/"+other+" failed")),
			mustNot:  []string{uid, other},
			mustKeep: []string{"graph: follow", "<redacted>"},
		},
		{
			name:     "edge id",
			err:      errors.New("commit follows/" + uid + "_" + other + ": aborted"),
			mustNot:  []string{uid, other},
			mustKeep: []string{"commit follows/", "aborted"},
		},
		{
			name:     "already hashed id kept",
			err:      errors.New("graph: purge abcdef0123456789: deadline exceeded"),
			mustKeep: []string{"graph: purge abcdef0123456789: deadline exceeded"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			log := slog.New(slog.NewJSONHandler(&buf, nil))
			mw.ReportError(context.Background(), log, "jobs/test", tt.err)
			out := buf.String()
			for _, s := range tt.mustNot {
				if strings.Contains(out, s) {
					t.Errorf("ERROR line carries %q: %s", s, out)
				}
			}
			for _, s := range tt.mustKeep {
				if !strings.Contains(out, s) {
					t.Errorf("ERROR line lost %q: %s", s, out)
				}
			}
		})
	}
}

// The same net on the interceptor path: an Internal apierr whose hidden cause names a document is scrubbed before logging,
// and the client still sees only the client-safe message.
func TestErrorMapping_ScrubsDocumentPathInCause(t *testing.T) {
	t.Parallel()
	const uid = "AbCdEfGhIjKlMnOpQrStUvWxYz12"
	var buf bytes.Buffer
	log := newCloudLoggingTestLogger(&buf)
	cause := errors.New("rpc error: documents/users/" + uid + " unavailable")
	srv := newTestServer(t, testProcedure, func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
		return nil, apierr.New(connect.CodeInternal, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "internal error").WithCause(cause)
	}, mw.ErrorMapping(log))

	_, err := callTestServer(t, srv, testProcedure)
	if connect.CodeOf(err) != connect.CodeInternal {
		t.Fatalf("code = %v, want Internal", connect.CodeOf(err))
	}
	out := buf.String()
	if strings.Contains(out, uid) {
		t.Errorf("ERROR line carries the raw uid: %s", out)
	}
	if !strings.Contains(out, "rpc error: <redacted>") {
		t.Errorf("ERROR line lost the scrubbed cause: %s", out)
	}
	if strings.Contains(err.Error(), "documents/") {
		t.Errorf("client error leaks the cause: %v", err)
	}
}
