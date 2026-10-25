package mw_test

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// secretPanic is a panic value whose text must never reach the log: only its type is reported.
type secretPanic struct{ uid string }

func (p secretPanic) String() string { return "uid " + p.uid }

func TestRecoverHTTP(t *testing.T) {
	var nilMap map[string]int // written to below: a runtime error panic

	tests := []struct {
		name       string
		handler    http.HandlerFunc
		wantStatus int
		wantLogged bool
	}{
		{"panic becomes 500 and an Error Reporting entry", func(http.ResponseWriter, *http.Request) { panic(secretPanic{uid: "uid-secret-123"}) }, http.StatusInternalServerError, true},
		{"a runtime error panic is a 500 too", func(http.ResponseWriter, *http.Request) { nilMap["x"] = 1 }, http.StatusInternalServerError, true},
		{"no panic passes through", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }, http.StatusNoContent, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var buf bytes.Buffer
			log := slog.New(slog.NewJSONHandler(&buf, nil))
			h := mw.RecoverHTTP(log, "demo-project", "cron/test", tc.handler)

			req := httptest.NewRequest(http.MethodPost, "/internal/cron/test", nil)
			req.Header.Set("X-Cloud-Trace-Context", "abc123/1;o=1")
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req) // must not panic

			if rec.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			out := buf.String()
			if logged := strings.Contains(out, `"level":"ERROR"`); logged != tc.wantLogged {
				t.Fatalf("error logged = %v, want %v; output: %s", logged, tc.wantLogged, out)
			}
			if !tc.wantLogged {
				return
			}
			for _, want := range []string{"ReportedErrorEvent", `"rpc":"cron/test"`, "panic of type", "projects/demo-project/traces/abc123"} {
				if !strings.Contains(out, want) {
					t.Errorf("log output missing %q: %s", want, out)
				}
			}
			if strings.Contains(out, "uid-secret-123") {
				t.Errorf("the panic value reached the log: %s", out)
			}
		})
	}
}
