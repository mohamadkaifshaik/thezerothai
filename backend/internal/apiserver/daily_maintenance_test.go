package apiserver

// W4-9b (ADR-0028 D7, F1 = B): the daily-maintenance wrapper. The status is the backstop's alone; the trends step is
// skipped below 3 s left, bounded to min(10 s, 28 s - elapsed), and a trends error or panic never changes the status.

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type trendsStepFake struct {
	calls    int
	err      error
	panicV   any
	deadline time.Duration // the budget the step was given
	onRun    func()
}

func (s *trendsStepFake) Refresh(ctx context.Context) error {
	s.calls++
	if dl, ok := ctx.Deadline(); ok {
		s.deadline = time.Until(dl)
	}
	if s.onRun != nil {
		s.onRun()
	}
	if s.panicV != nil {
		panic(s.panicV)
	}
	return s.err
}

type dmClock struct{ t time.Time }

func (c *dmClock) now() time.Time { return c.t }

func TestDailyMaintenance_StatusMatrix(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		backstop int // status the lifecycle handler writes (0 = writes nothing)
		step     trendsStepFake
		took     time.Duration // how long the backstop takes (fake dmClock)
		method   string
		want     int
		wantRuns int
		wantSkip string
	}{
		{"backstop ok, trends ok", http.StatusNoContent, trendsStepFake{}, time.Second, "POST", 204, 1, ""},
		{"backstop ok, trends fails", http.StatusNoContent, trendsStepFake{err: errors.New("first page")}, time.Second, "POST", 204, 1, ""},
		{"backstop ok, trends panics", http.StatusNoContent, trendsStepFake{panicV: "boom"}, time.Second, "POST", 204, 1, ""},
		{"backstop fails, trends ok: Scheduler must retry the backstop", http.StatusInternalServerError, trendsStepFake{}, time.Second, "POST", 500, 1, ""},
		{"backstop fails, trends fails", http.StatusInternalServerError, trendsStepFake{err: errors.New("x")}, time.Second, "POST", 500, 1, ""},
		{"backstop ok at 24.9 s: 3.1 s left, trends runs", http.StatusNoContent, trendsStepFake{}, 24900 * time.Millisecond, "POST", 204, 1, ""},
		{"backstop takes 26 s: trends skipped as deadline", http.StatusNoContent, trendsStepFake{}, 26 * time.Second, "POST", 204, 0, "deadline"},
		{"backstop fails after 26 s: still 500, trends skipped", http.StatusInternalServerError, trendsStepFake{}, 26 * time.Second, "POST", 500, 0, "deadline"},
		{"GET never starts the step and the backstop answers 405", http.StatusMethodNotAllowed, trendsStepFake{}, time.Second, "GET", 405, 0, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			clk := &dmClock{t: time.Date(2026, 10, 30, 3, 0, 0, 0, time.UTC)}
			step := tc.step
			var logs bytes.Buffer
			log := slog.New(slog.NewJSONHandler(&logs, nil))
			backstop := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				clk.t = clk.t.Add(tc.took)
				if tc.backstop != 0 {
					w.WriteHeader(tc.backstop)
				}
			})
			h := dailyMaintenanceHandler(backstop, &step, log, "p", clk.now)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(tc.method, "/internal/cron/daily-maintenance", nil))
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
			if step.calls != tc.wantRuns {
				t.Fatalf("trends step ran %d times, want %d", step.calls, tc.wantRuns)
			}
			if tc.wantSkip != "" && !strings.Contains(logs.String(), `"reason":"`+tc.wantSkip+`"`) {
				t.Errorf("want a trends_skipped line with reason %s: %s", tc.wantSkip, logs.String())
			}
			if tc.step.panicV != nil && !strings.Contains(logs.String(), "panic in trends step") {
				t.Errorf("a panic must be reported: %s", logs.String())
			}
		})
	}
}

// TestDailyMaintenance_StepDeadline: the step gets min(10 s, 28 s - elapsed).
func TestDailyMaintenance_StepDeadline(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		took time.Duration
		want time.Duration
	}{
		{time.Second, 10 * time.Second},
		{17 * time.Second, 10 * time.Second},
		{20 * time.Second, 8 * time.Second},
		{24 * time.Second, 4 * time.Second},
	} {
		clk := &dmClock{t: time.Date(2026, 10, 30, 3, 0, 0, 0, time.UTC)}
		step := &trendsStepFake{}
		backstop := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { clk.t = clk.t.Add(tc.took); w.WriteHeader(204) })
		dailyMaintenanceHandler(backstop, step, slog.New(slog.DiscardHandler), "p", clk.now).
			ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/", nil))
		if step.calls != 1 || step.deadline > tc.want || step.deadline < tc.want-time.Second {
			t.Errorf("took %v: step deadline %v, want about %v", tc.took, step.deadline, tc.want)
		}
	}
}

// TestDailyMaintenance_PassesThrough: the backstop's headers and body reach the client unchanged, a handler that writes
// nothing answers 200 as net/http does, and a nil step is the plain backstop.
func TestDailyMaintenance_PassesThrough(t *testing.T) {
	t.Parallel()
	backstop := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Test", "1")
		_, _ = w.Write([]byte("ok"))
	})
	rec := httptest.NewRecorder()
	dailyMaintenanceHandler(backstop, &trendsStepFake{}, slog.New(slog.DiscardHandler), "p", time.Now).ServeHTTP(rec, httptest.NewRequest("POST", "/", nil))
	if rec.Code != 200 || rec.Header().Get("X-Test") != "1" || rec.Body.String() != "ok" {
		t.Fatalf("code %d header %q body %q", rec.Code, rec.Header().Get("X-Test"), rec.Body.String())
	}
	rec = httptest.NewRecorder()
	dailyMaintenanceHandler(backstop, nil, slog.New(slog.DiscardHandler), "p", time.Now).ServeHTTP(rec, httptest.NewRequest("POST", "/", nil))
	if rec.Code != 200 {
		t.Fatalf("nil step: code %d", rec.Code)
	}
}
