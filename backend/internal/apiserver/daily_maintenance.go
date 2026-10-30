package apiserver

import (
	"bytes"
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/search"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// Cut-offs of the daily-maintenance request (ADR-0028 D7, A5). The job has no attempt_deadline_seconds, so Cloud
// Scheduler's attempt deadline is the module default 30 s, equal to Cloud Run's 30 s request timeout; 28 s leaves 2 s of
// margin. The backstop runs under its own 25 s deadline, so it leaves at least 3 s.
const (
	dailyMaintenanceCutoff = 28 * time.Second
	trendsStepMax          = 10 * time.Second
	trendsStepMin          = 3 * time.Second
	trendsStepOp           = "cron/daily-maintenance/trends"
)

// trendsStep is what the wrapper runs after the backstop (search.Refresher satisfies it).
type trendsStep interface {
	Refresh(ctx context.Context) error
}

// dailyMaintenanceHandler is the `/internal/cron/daily-maintenance` route (ADR-0028 D7, F1 = B): it calls the account
// lifecycle backstop handler unchanged through a status-capturing writer, then runs the trends step, then writes the
// BACKSTOP'S captured status only (204, or 500 so Scheduler retries the backstop). A trends failure, panic or skip is
// logged and reported to Error Reporting, never turned into a status; a retry after a good run is cheap because the step
// skips itself as `fresh`. The step gets min(10 s, 28 s - elapsed) and is skipped as `deadline` below 3 s. A non-POST
// request goes to the backstop handler alone (it answers 405) and never starts the step. now is the clock (tests).
func dailyMaintenanceHandler(backstop http.Handler, step trendsStep, log *slog.Logger, projectID string, now func() time.Time) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || step == nil {
			backstop.ServeHTTP(w, r)
			return
		}
		started := now()
		rec := &statusRecorder{header: http.Header{}}
		backstop.ServeHTTP(rec, r)

		ctx := logger.WithTrace(r.Context(), logger.TraceFromRequest(r, projectID))
		runTrendsStep(ctx, step, log, started, now)

		for k, v := range rec.header {
			w.Header()[k] = v
		}
		w.WriteHeader(rec.statusCode())
		_, _ = w.Write(rec.body.Bytes())
	})
}

// runTrendsStep never returns an error and never panics out: its outcome is for the logs only.
func runTrendsStep(ctx context.Context, step trendsStep, log *slog.Logger, started time.Time, now func() time.Time) {
	left := dailyMaintenanceCutoff - now().Sub(started)
	if left < trendsStepMin {
		log.InfoContext(ctx, "trends_skipped", append([]any{"reason", search.SkipDeadline, "left_ms", left.Milliseconds()}, logger.TraceAttrs(ctx)...)...)
		return
	}
	// The step runs under its own deadline; the request
	// context stays the parent so a client abort still stops it.
	sctx, cancel := context.WithTimeout(ctx, min(trendsStepMax, left))
	defer cancel()
	defer func() {
		if v := recover(); v != nil {
			mw.ReportError(sctx, log.With(logger.TraceAttrs(sctx)...), trendsStepOp, logger.ScrubErr(panicError{v}))
		}
	}()
	// Refresh writes its own trends_refresh / trends_skipped line and reports its own errors; the error is dropped here on
	// purpose (the status is the backstop's).
	_ = step.Refresh(sctx)
}

type panicError struct{ v any }

func (p panicError) Error() string { return "panic in trends step" }

// statusRecorder buffers what the backstop handler writes so the wrapper can send it after the step.
type statusRecorder struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (s *statusRecorder) Header() http.Header { return s.header }
func (s *statusRecorder) WriteHeader(code int) {
	if s.status == 0 {
		s.status = code
	}
}
func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.body.Write(b)
}
func (s *statusRecorder) statusCode() int {
	if s.status == 0 {
		return http.StatusOK // a handler that wrote nothing answers 200, as net/http does
	}
	return s.status
}
