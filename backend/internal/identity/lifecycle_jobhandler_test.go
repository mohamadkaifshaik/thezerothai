package identity

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type recordingJobHandler struct {
	got     [][]byte
	outcome string
	err     error
}

func (r *recordingJobHandler) Handle(_ context.Context, data []byte) (string, error) {
	r.got = append(r.got, append([]byte(nil), data...))
	return r.outcome, r.err
}

// TestRegisterJobHandler (P4): another module's job kind rides the account jobs endpoint. Account kinds cannot be
// taken over, registration is a startup-time act, and the handler's ack/nack decides the HTTP answer.
func TestRegisterJobHandler(t *testing.T) {
	h := newHarness(t)
	rec := &recordingJobHandler{outcome: "done"}
	tests := []struct {
		name    string
		kind    string
		h       JobHandler
		wantErr string
	}{
		{"ok", "post_delete", rec, ""},
		{"duplicate", "post_delete", rec, "twice"},
		{"empty kind", "", rec, "empty or reserved"},
		{"reserved account_delete", JobKindAccountDelete, rec, "empty or reserved"},
		{"reserved account_export", JobKindAccountExport, rec, "empty or reserved"},
		{"nil handler", "other", nil, "no handler"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := h.l.RegisterJobHandler(tt.kind, tt.h)
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("err = %v", err)
			case tt.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tt.wantErr)):
				t.Fatalf("err = %v, want %q", err, tt.wantErr)
			}
		})
	}

	// A registered kind reaches its handler with the raw payload; the account paths are untouched.
	if code := h.deliverRaw(envelope(map[string]any{"kind": "post_delete", "uid": "u1", "postId": "x"}, 1)); code != http.StatusNoContent {
		t.Fatalf("status = %d", code)
	}
	if len(rec.got) != 1 || !strings.Contains(string(rec.got[0]), `"post_delete"`) {
		t.Fatalf("handler got %q", rec.got)
	}
	if h.repo.reads != 0 || h.repo.writes != 0 {
		t.Error("a module job touched the identity repo")
	}

	// A handler error nacks (500) so Pub/Sub redelivers; the error text never reaches the response.
	rec.err = errors.New("storage unavailable for uid u1")
	rr := newRecorder()
	req := httptest.NewRequest(http.MethodPost, "/internal/pubsub/jobs", strings.NewReader(envelope(map[string]any{"kind": "post_delete", "uid": "u1"}, 1)))
	h.l.JobsHandler().ServeHTTP(rr, req)
	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rr.Code)
	}
	if strings.Contains(rr.Body.String(), "u1") {
		t.Errorf("response leaks the error: %q", rr.Body.String())
	}

	// After the first job ran the registries are sealed.
	if err := h.l.RegisterJobHandler("late", rec); err == nil || !strings.Contains(err.Error(), "after the first job") {
		t.Fatalf("late registration err = %v", err)
	}
}
