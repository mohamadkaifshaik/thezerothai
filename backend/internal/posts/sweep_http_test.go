package posts

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeSweeper is a Sweeper for the route tests.
type fakeSweeper struct {
	res      SweepResult
	err      error
	panicVal any
	reads    int64
	calls    int
	deadline time.Time
	hadCount bool
}

func (f *fakeSweeper) Sweep(ctx context.Context) (SweepResult, error) {
	f.calls++
	f.deadline, _ = ctx.Deadline()
	f.hadCount = budget.FromContext(ctx) != nil
	if f.panicVal != nil {
		panic(f.panicVal)
	}
	budget.FromContext(ctx).AddReads(f.reads)
	return f.res, f.err
}

func serveSweep(t *testing.T, sw Sweeper, method string) (*httptest.ResponseRecorder, *lockedBuffer) {
	t.Helper()
	logs := &lockedBuffer{}
	h := NewSweepHandler(sw, slog.New(slog.NewJSONHandler(logs, nil)), "demo-project")
	req := httptest.NewRequest(method, "/internal/cron/publish-scheduled", nil)
	req.Header.Set("X-Cloud-Trace-Context", "trace123/1;o=1")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec, logs
}

func lastJSONLine(t *testing.T, logs *lockedBuffer) map[string]any {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(logs.String()), "\n")
	var m map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &m); err != nil {
		t.Fatalf("log line is not JSON: %v\n%s", err, logs.String())
	}
	return m
}

func TestSweepHandler_MethodAndDeadline(t *testing.T) {
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		sw := &fakeSweeper{}
		rec, _ := serveSweep(t, sw, m)
		if rec.Code != http.StatusMethodNotAllowed || sw.calls != 0 {
			t.Errorf("%s: status %d, sweep calls %d, want 405 and no run", m, rec.Code, sw.calls)
		}
	}
	sw := &fakeSweeper{res: SweepResult{Outcome: SweepOK}}
	rec, _ := serveSweep(t, sw, http.MethodPost)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	if d := time.Until(sw.deadline); d < 24*time.Second || d > sweepRunDeadline {
		t.Errorf("the run's deadline is %v away, want about 25 s", d)
	}
	if !sw.hadCount {
		t.Error("the run has no budget counter (system reads must not be charged to a user)")
	}
}

func TestSweepHandler_OneLinePerRunWith204EvenWhenItemsFail(t *testing.T) {
	sw := &fakeSweeper{reads: 17, res: SweepResult{
		Outcome: SweepOK, Due: 9, Published: 4, Cancelled: 1, Transient: 1, Deferred: 2, Noop: 1, SkippedBadPath: 1, Undecodable: 1,
		MaxLateness: 7 * time.Minute, Failed: map[ScheduledFailure]int{FailureMediaUnavailable: 2, FailureExpired: 1},
	}}
	rec, logs := serveSweep(t, sw, http.MethodPost)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 although items failed", rec.Code)
	}
	lines := logs.lines("scheduled_sweep")
	if len(lines) != 1 {
		t.Fatalf("scheduled_sweep lines = %d, want exactly 1:\n%s", len(lines), logs.String())
	}
	m := lastJSONLine(t, logs)
	want := map[string]float64{
		"due": 9, "published": 4, "cancelled": 1, "expired": 1, "transient": 1, "deferred": 2, "noop": 1, "skipped_bad_path": 1,
		"undecodable": 1, "max_lateness_ms": 420000, "fs_reads": 17, "fs_writes": 0, "failed_total": 3,
	}
	for k, v := range want {
		if got, ok := m[k].(float64); !ok || got != v {
			t.Errorf("%s = %v, want %v", k, m[k], v)
		}
	}
	if m["outcome"] != "ok" || m["msg"] != "scheduled_sweep" || m["logging.googleapis.com/trace"] != "projects/demo-project/traces/trace123" {
		t.Errorf("line = %v", m)
	}
	if failed, _ := m["failed"].(map[string]any); failed["media_unavailable"] != float64(2) || failed["expired"] != float64(1) {
		t.Errorf("failed = %v, want the per-reason counts", m["failed"])
	}
	if strings.Contains(logs.String(), `"level":"ERROR"`) {
		t.Errorf("a completed run raised an error entry: %s", logs.String())
	}
}

func TestSweepHandler_NoOpOutcomesAre204WithZeroReads(t *testing.T) {
	for _, outcome := range []string{SweepFlagOff, SweepDegraded} {
		sw := &fakeSweeper{res: SweepResult{Outcome: outcome}}
		rec, logs := serveSweep(t, sw, http.MethodPost)
		m := lastJSONLine(t, logs)
		if rec.Code != http.StatusNoContent || m["outcome"] != outcome || m["fs_reads"] != float64(0) {
			t.Errorf("%s: status %d line %v, want 204, the outcome and 0 reads", outcome, rec.Code, m)
		}
	}
}

func TestSweepHandler_QueryFailureIs500WithAnErrorReport(t *testing.T) {
	sw := &fakeSweeper{res: SweepResult{Outcome: SweepError}, err: errors.New("posts: sweep due query: unavailable")}
	rec, logs := serveSweep(t, sw, http.MethodPost)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 so Cloud Scheduler retries", rec.Code)
	}
	m := lastJSONLine(t, logs)
	if m["level"] != "ERROR" || m["@type"] == nil || m["rpc"] != "cron/publish-scheduled" || m["outcome"] != "error" {
		t.Errorf("line = %v, want an Error Reporting entry", m)
	}
	if len(logs.lines(`"msg":"scheduled_sweep"`)) != 0 {
		t.Error("a failed run also wrote the success line")
	}
}

// Route-level recovery: a panic on the handler goroutine is a 500 and an Error Reporting entry, never a crash.
func TestSweepHandler_PanicIsRecovered(t *testing.T) {
	sw := &fakeSweeper{panicVal: "secret uid-123"}
	rec, logs := serveSweep(t, sw, http.MethodPost) // must not panic
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
	out := logs.String()
	if !strings.Contains(out, "panic of type string") || strings.Contains(out, "secret uid-123") {
		t.Errorf("log = %s, want the panic type only", out)
	}
}
