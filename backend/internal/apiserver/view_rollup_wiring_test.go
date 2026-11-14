package apiserver

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

type fakeRollupRunner struct {
	err   error
	calls int
	panic bool
	ctx   context.Context
}

func (f *fakeRollupRunner) Run(ctx context.Context) (posts.ViewRollupResult, error) {
	f.calls++
	f.ctx = ctx
	if f.panic {
		panic("boom")
	}
	return posts.ViewRollupResult{Outcome: posts.ViewRollupRan}, f.err
}

func quietLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestViewRollupHandler(t *testing.T) {
	for _, tc := range []struct {
		name   string
		method string
		runner *fakeRollupRunner
		want   int
		calls  int
	}{
		{"ok", http.MethodPost, &fakeRollupRunner{}, http.StatusNoContent, 1},
		{"failure is 500", http.MethodPost, &fakeRollupRunner{err: errors.New("down")}, http.StatusInternalServerError, 1},
		{"panic is 500", http.MethodPost, &fakeRollupRunner{panic: true}, http.StatusInternalServerError, 1},
		{"GET is 405", http.MethodGet, &fakeRollupRunner{}, http.StatusMethodNotAllowed, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := viewRollupHandler(viewRollupStep{rollup: tc.runner, log: quietLog()}, quietLog(), "p")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest(tc.method, "/internal/cron/view-rollup", nil))
			if w.Code != tc.want || tc.runner.calls != tc.calls {
				t.Fatalf("status %d (calls %d), want %d (%d)", w.Code, tc.runner.calls, tc.want, tc.calls)
			}
		})
	}
}

// TestWithViewRollup: the route's status is the inner handler's whatever the rollup does; the step is skipped when the
// inner handler used up the budget, and never runs for a non-POST.
func TestWithViewRollup(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusAccepted) })
	t.Run("runs after inner, inner's status", func(t *testing.T) {
		r := &fakeRollupRunner{err: errors.New("rollup failed")}
		h := withViewRollup(inner, viewRollupStep{rollup: r, log: quietLog()}, "p", time.Now)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", nil))
		if w.Code != http.StatusAccepted || r.calls != 1 {
			t.Fatalf("status %d calls %d", w.Code, r.calls)
		}
		if dl, ok := r.ctx.Deadline(); !ok || time.Until(dl) > viewRollupStepMax {
			t.Fatalf("step deadline %v, want at most %v", dl, viewRollupStepMax)
		}
	})
	t.Run("skipped at the cutoff", func(t *testing.T) {
		r := &fakeRollupRunner{}
		base := time.Now()
		calls := 0
		clock := func() time.Time { calls++; return base.Add(time.Duration(calls-1) * 27 * time.Second) }
		h := withViewRollup(inner, viewRollupStep{rollup: r, log: quietLog()}, "p", clock)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", nil))
		if w.Code != http.StatusAccepted || r.calls != 0 {
			t.Fatalf("status %d calls %d, want inner's status and no run", w.Code, r.calls)
		}
	})
	t.Run("GET goes to inner alone", func(t *testing.T) {
		r := &fakeRollupRunner{}
		w := httptest.NewRecorder()
		withViewRollup(inner, viewRollupStep{rollup: r, log: quietLog()}, "p", time.Now).ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
		if r.calls != 0 || w.Code != http.StatusAccepted {
			t.Fatalf("calls %d status %d", r.calls, w.Code)
		}
	})
}

func TestNewViewRollups(t *testing.T) {
	tick, route := newViewRollups(nil, func() bool { return false }, true)
	if tick.MinInterval != viewRollupTickInterval || route.MinInterval != viewRollupRouteInterval || !tick.ReadOnly || !route.ReadOnly {
		t.Fatalf("tick %+v route %+v", tick, route)
	}
}
