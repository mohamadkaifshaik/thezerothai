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
	before := time.Now()
	rec, _ := serveSweep(t, sw, http.MethodPost)
	after := time.Now()
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	// The deadline is set inside the handler, so it is exactly sweepRunDeadline after some instant between before and after;
	// bracketing it that way does not depend on how long the request took or how loaded the machine is.
	if sw.deadline.Before(before.Add(sweepRunDeadline)) || sw.deadline.After(after.Add(sweepRunDeadline)) {
		t.Errorf("the run's deadline is %v after the request started, want exactly %v", sw.deadline.Sub(before), sweepRunDeadline)
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
	sw := &fakeSweeper{reads: 1, res: SweepResult{Outcome: SweepError}, err: errors.New("posts: sweep due query: unavailable")}
	rec, logs := serveSweep(t, sw, http.MethodPost)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 so Cloud Scheduler retries", rec.Code)
	}
	// The scheduled_sweep line is written for a failed run too (outcome=error, with the counts and the run's reads)...
	lines := logs.lines(`"msg":"scheduled_sweep"`)
	if len(lines) != 1 {
		t.Fatalf("scheduled_sweep lines = %d, want exactly 1 on a failed run too:\n%s", len(lines), logs.String())
	}
	var run map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &run); err != nil {
		t.Fatal(err)
	}
	if run["outcome"] != "error" || run["level"] != "WARN" || run["fs_reads"] != float64(1) || run["due"] != float64(0) {
		t.Errorf("run line = %v, want outcome=error at WARN with the counts and 1 read", run)
	}
	// ...and a SEPARATE Error Reporting entry carries only the scrubbed error, no counts.
	m := lastJSONLine(t, logs)
	if m["level"] != "ERROR" || m["@type"] == nil || m["rpc"] != "cron/publish-scheduled" || m["msg"] == "scheduled_sweep" {
		t.Errorf("last line = %v, want the Error Reporting entry", m)
	}
	if _, has := m["due"]; has {
		t.Errorf("the Error Reporting entry carries the run counts: %v", m)
	}
}

// A later page failing is the same two lines but a 204.
func TestSweepHandler_LaterPageErrorIsReportedWith204(t *testing.T) {
	sw := &fakeSweeper{res: SweepResult{Outcome: SweepError, Published: 2, LaterPageErr: errors.New("posts: sweep due query: unavailable")}}
	rec, logs := serveSweep(t, sw, http.MethodPost)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 (the earlier pages were processed; a retry would burn attempts)", rec.Code)
	}
	if n := len(logs.lines(`"msg":"scheduled_sweep"`)); n != 1 {
		t.Errorf("scheduled_sweep lines = %d, want 1", n)
	}
	if m := lastJSONLine(t, logs); m["level"] != "ERROR" || m["@type"] == nil {
		t.Errorf("last line = %v, want an Error Reporting entry", m)
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

// A due-query page that fails AFTER page 1 was processed must not make Cloud Scheduler re-run the sweep (review M1): the
// retry comes seconds later and would burn the 3-attempt ladder of any item that failed transiently. Page 1 failing
// processes nothing, so there the 500 and the retry are wanted.
func TestSweepHandler_LaterPageFailureIs204FirstPageFailureIs500(t *testing.T) {
	serve := func(e *sweepEnv) *httptest.ResponseRecorder {
		h := NewSweepHandler(e.svc, slog.New(slog.NewJSONHandler(e.logs, nil)), "demo-project")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/cron/publish-scheduled", nil))
		return rec
	}
	pageTwoErr := errors.New("rpc error: code = Unavailable desc = on documents/users/uid-b/scheduled/x")

	t.Run("page two fails: 204, page one processed exactly once, its transient item bumped once", func(t *testing.T) {
		e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.Limit = 1 })
		a := e.dueItem("uid-a", 1)
		b := e.dueItem("uid-b", 2)
		e.repo.dueErr, e.repo.dueErrAt = pageTwoErr, 2
		e.repo.publish = func(context.Context, PublishParams) (PublishResult, error) {
			return PublishResult{}, errors.New("rpc error: code = Unavailable desc = overloaded")
		}

		rec := serve(e)
		if rec.Code != http.StatusNoContent {
			t.Fatalf("status = %d, want 204: a 5xx would make Cloud Scheduler re-run the sweep seconds later", rec.Code)
		}
		if got := e.repo.callsOf("publish"); len(got) != 1 || got[0].uid != "uid-a" {
			t.Errorf("publish calls = %+v, want exactly one, for the page-one item", got)
		}
		if got := e.repo.doc("uid-a", a.ID); got.Attempts != 1 || got.Status != ScheduledPending {
			t.Errorf("page-one item = %+v, want PENDING with attempts 1 (one run, one attempt)", got)
		}
		if got := e.repo.doc("uid-b", b.ID); got.Attempts != 0 {
			t.Errorf("the item on the failed page has attempts %d, want 0", got.Attempts)
		}
		var sweepLine map[string]any
		for _, line := range strings.Split(e.logs.String(), "\n") {
			var m map[string]any
			if json.Unmarshal([]byte(line), &m) == nil && m["msg"] == "scheduled_sweep" {
				sweepLine = m
			}
		}
		if sweepLine == nil || sweepLine["outcome"] != "error" || sweepLine["transient"] != float64(1) {
			t.Errorf("scheduled_sweep line = %v, want outcome=error with the counts", sweepLine)
		}
		if len(e.logs.lines("ReportedErrorEvent")) < 1 {
			t.Error("the page failure raised no Error Reporting entry")
		}
		if strings.Contains(e.logs.String(), "uid-b") {
			t.Errorf("a uid reached the logs:\n%s", e.logs.String())
		}
	})

	t.Run("page one fails: 500, nothing processed", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem("uid-a", 1)
		e.repo.dueErr, e.repo.dueErrAt = pageTwoErr, 1

		if rec := serve(e); rec.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500 so Cloud Scheduler retries (nothing was processed)", rec.Code)
		}
		if n := len(e.repo.callsOf("publish")); n != 0 {
			t.Errorf("%d items ran although the first page failed", n)
		}
	})
}
