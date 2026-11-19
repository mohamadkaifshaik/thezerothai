package apiserver

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// fakeCiphertextSweeper answers pages from a script (the last one repeats).
type fakeCiphertextSweeper struct {
	calls  int
	limit  int
	at     []time.Time
	budget time.Duration // the deadline left at the first call
	pages  []messaging.CiphertextSweepResult
	err    error
	panics bool
}

func (f *fakeCiphertextSweeper) SweepCiphertext(ctx context.Context, now time.Time, limit int) (messaging.CiphertextSweepResult, error) {
	f.calls++
	f.limit = limit
	f.at = append(f.at, now)
	if dl, ok := ctx.Deadline(); ok && f.calls == 1 {
		f.budget = time.Until(dl)
	}
	if f.panics {
		panic("boom")
	}
	if f.err == errUntilBudget {
		// The budget ends mid-page: the page is answered with what it had done (nothing swept) and the context's error.
		<-ctx.Done()
		return f.pages[min(f.calls, len(f.pages))-1], ctx.Err()
	}
	return f.pages[min(f.calls, len(f.pages))-1], f.err
}

// errUntilBudget makes fakeCiphertextSweeper wait for the step's own deadline and then fail with it.
var errUntilBudget = errors.New("wait for the budget to end")

var sweepClock = time.Date(2026, 12, 20, 3, 0, 0, 0, time.UTC)

func newCiphertextStep(sw messaging.CiphertextSweeper, readOnly bool, buf *bytes.Buffer) ciphertextSweepStep {
	return ciphertextSweepStep{sweeper: sw, limit: 9, readOnly: readOnly, log: slog.New(slog.NewJSONHandler(buf, nil)), now: func() time.Time { return sweepClock }}
}

// missingIndex is what Firestore answers a collection-group query whose index is not READY.
var missingIndex = status.Error(codes.FailedPrecondition, "The query requires an index. You can create it here: https://console.firebase.google.com/project/p/firestore/indexes?create_exemption=x")

// sweepLines parses the captured JSON log into its ciphertext_sweep records.
func sweepLines(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("log line %q: %v", line, err)
		}
		if rec["msg"] == ciphertextSweepEvent {
			out = append(out, rec)
		}
	}
	return out
}

// oneSweepLine is the run's single ciphertext_sweep record.
func oneSweepLine(t *testing.T, buf *bytes.Buffer) map[string]any {
	t.Helper()
	lines := sweepLines(t, buf)
	if len(lines) != 1 {
		t.Fatalf("%d ciphertext_sweep lines, want exactly one: %s", len(lines), buf.String())
	}
	return lines[0]
}

// Each outcome with its level: ok INFO; partial, stalled and skipped_deadline WARN; skipped_readonly INFO; failed (a
// missing index, a panic) ERROR; WARN at least whenever lag_h > 24. lag_h is now - OldestDue in hours; the step passes its
// limit and the injected clock, takes at most its own budget and always returns nil.
func TestCiphertextSweepStep_OutcomesAndLevels(t *testing.T) {
	t.Parallel()
	due := func(lag time.Duration) time.Time { return sweepClock.Add(-lag) }
	full := messaging.CiphertextSweepResult{Due: 9, Swept: 9, More: true, OldestDue: due(2 * time.Hour)}
	tests := []struct {
		name      string
		pages     []messaging.CiphertextSweepResult
		err       error
		panics    bool
		readOnly  bool
		deadline  time.Duration // 0 = none
		wantCalls int
		outcome   string
		level     string
		lag       float64 // -1 = no lag_h field
		capped    bool
	}{
		{"nothing due", []messaging.CiphertextSweepResult{{}}, nil, false, false, 0, 1, "ok", "INFO", 0, false},
		{"all swept", []messaging.CiphertextSweepResult{{Due: 3, Swept: 2, Skipped: 1, OldestDue: due(90 * time.Minute)}}, nil, false, false, 0, 1, "ok", "INFO", 1.5, false},
		{"ok but more than a day behind", []messaging.CiphertextSweepResult{{Due: 1, Swept: 1, OldestDue: due(30 * time.Hour)}}, nil, false, false, 0, 1, "ok", "WARN", 30, false},
		{"page cap with more due", []messaging.CiphertextSweepResult{full}, nil, false, false, 0, ciphertextSweepMaxPages, "partial", "WARN", 2, true},
		{"stalled: a page swept nothing", []messaging.CiphertextSweepResult{full, {Due: 9, Skipped: 9, More: true}}, nil, false, false, 0, 2, "stalled", "WARN", 2, false},
		{"stalled: a short page all skipped", []messaging.CiphertextSweepResult{{Due: 2, Skipped: 2, OldestDue: due(time.Hour)}}, nil, false, false, 0, 1, "stalled", "WARN", 1, false},
		// The budget ends mid-page (nothing of it swept yet): partial, not stalled; the next run continues.
		{"budget ends mid-page", []messaging.CiphertextSweepResult{{Due: 5, More: true, OldestDue: due(time.Hour)}}, errUntilBudget, false, false, 1100 * time.Millisecond, 1, "partial", "WARN", 1, false},
		{"missing index", []messaging.CiphertextSweepResult{{}}, missingIndex, false, false, 0, 1, "failed", "ERROR", 0, false},
		{"panic", []messaging.CiphertextSweepResult{{}}, nil, true, false, 0, 1, "failed", "ERROR", -1, false},
		{"readonly does nothing", nil, nil, false, true, 0, 0, "skipped_readonly", "INFO", -1, false},
		{"too little time", nil, nil, false, false, 500 * time.Millisecond, 0, "skipped_deadline", "WARN", -1, false},
		{"a long deadline is capped", []messaging.CiphertextSweepResult{{}}, nil, false, false, time.Minute, 1, "ok", "INFO", 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeCiphertextSweeper{pages: tt.pages, err: tt.err, panics: tt.panics}
			ctx := context.Background()
			if tt.deadline > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, tt.deadline)
				defer cancel()
			}
			if err := newCiphertextStep(sw, tt.readOnly, &buf).Refresh(ctx); err != nil {
				t.Fatalf("Refresh = %v, want nil", err)
			}
			rec := oneSweepLine(t, &buf)
			if sw.calls != tt.wantCalls || rec["outcome"] != tt.outcome || rec["level"] != tt.level {
				t.Fatalf("calls %d outcome %v level %v, want %d %s %s: %s", sw.calls, rec["outcome"], rec["level"], tt.wantCalls, tt.outcome, tt.level, buf.String())
			}
			if tt.lag >= 0 && (rec["lag_h"] != tt.lag || rec["cap_reached"] != tt.capped) {
				t.Errorf("lag_h %v cap_reached %v, want %v %v", rec["lag_h"], rec["cap_reached"], tt.lag, tt.capped)
			}
			if sw.calls > 0 && (sw.limit != 9 || sw.budget > ciphertextSweepMax || !sw.at[0].Equal(sweepClock)) {
				t.Errorf("limit %d budget %v now %v, want 9, at most %v, the injected clock", sw.limit, sw.budget, sw.at[0], ciphertextSweepMax)
			}
		})
	}
}

// The counts of every page add up in one line; a run stops on a short page.
func TestCiphertextSweepStep_Pages(t *testing.T) {
	t.Parallel()
	full := messaging.CiphertextSweepResult{Due: 9, Swept: 8, Skipped: 1, More: true, OldestDue: sweepClock.Add(-time.Hour)}
	var buf bytes.Buffer
	sw := &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{full, full, {Due: 2, Swept: 2}}}
	if err := newCiphertextStep(sw, false, &buf).Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	rec := oneSweepLine(t, &buf)
	if sw.calls != 3 || rec["pages"] != 3.0 || rec["due"] != 20.0 || rec["swept"] != 18.0 || rec["skipped"] != 2.0 || rec["more"] != false || rec["lag_h"] != 1.0 || rec["outcome"] != "ok" {
		t.Fatalf("calls %d, line %v", sw.calls, rec)
	}
}

func TestLagHours(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		oldest time.Time
		want   float64
	}{
		{time.Time{}, 0},
		{sweepClock, 0},
		{sweepClock.Add(time.Minute), 0},
		{sweepClock.Add(-36 * time.Minute), 0.6},
		{sweepClock.Add(-49 * time.Hour), 49},
	} {
		if got := lagHours(sweepClock, tc.oldest); got != tc.want {
			t.Errorf("lagHours(%v) = %v, want %v", tc.oldest, got, tc.want)
		}
	}
}

// okStep counts its runs.
type okStep struct{ runs *atomic.Int32 }

func (s okStep) Refresh(context.Context) error { s.runs.Add(1); return nil }

// At the end of the real chain shape, a ciphertext sweep whose query fails (the index not READY) or panics changes
// nothing: every earlier step ran and the request answers the backstop's status.
func TestCiphertextSweepStep_InMaintenanceChain(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name   string
		sw     *fakeCiphertextSweeper
		status int
	}{
		{"missing index", &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}, err: missingIndex}, http.StatusNoContent},
		{"panic", &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}, panics: true}, http.StatusNoContent},
		{"backstop 500 stays 500", &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{Due: 1, Swept: 1}}}, http.StatusInternalServerError},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			runs := &atomic.Int32{}
			backstop := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(tc.status) })
			chain := stepChain{okStep{runs}, okStep{runs}, okStep{runs}, newCiphertextStep(tc.sw, false, &buf)}
			log := slog.New(slog.NewJSONHandler(&buf, nil))
			rec := httptest.NewRecorder()
			dailyMaintenanceHandler(backstop, chain, log, "p", time.Now).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/cron/daily-maintenance", nil))
			if rec.Code != tc.status || runs.Load() != 3 || tc.sw.calls != 1 {
				t.Fatalf("status %d (want %d), earlier steps %d, sweep calls %d; log %s", rec.Code, tc.status, runs.Load(), tc.sw.calls, buf.String())
			}
		})
	}
}

// routeClock advances only when told to (the route's elapsed time).
type routeClock struct{ t atomic.Int64 }

func (c *routeClock) now() time.Time          { return time.Unix(0, c.t.Load()) }
func (c *routeClock) advance(d time.Duration) { c.t.Add(int64(d)) }

func newRouteClock(at time.Time) *routeClock {
	c := &routeClock{}
	c.t.Store(at.UnixNano())
	return c
}

// The hourly placement on the trends-refresh route: the refresh runs first and its response (status, header, body) is the
// route's, whatever the sweep does; the sweep runs after it on the leftover time only (at most 2 s, never more than the
// 28 s cutoff leaves) and is skipped with a WARN skipped_deadline line when less than a second is left; a non-POST never
// starts it.
func TestCiphertextSweep_HourlyPlacement(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		took        time.Duration // the refresh's elapsed time on the route clock
		status      int
		sw          *fakeCiphertextSweeper
		wantCalls   int
		maxBudget   time.Duration
		wantOutcome string
		wantLevel   string
	}{
		{"fast refresh: up to 2 s", time.Second, http.StatusNoContent, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}}, 1, ciphertextHourlyMax, "ok", "INFO"},
		{"slow refresh: only what is left", 26*time.Second + 500*time.Millisecond, http.StatusNoContent, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}}, 1, 1500 * time.Millisecond, "ok", "INFO"},
		{"refresh used it all: skipped", 27*time.Second + 500*time.Millisecond, http.StatusNoContent, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}}, 0, 0, "skipped_deadline", "WARN"},
		{"refresh failed: 500 kept", time.Second, http.StatusInternalServerError, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}}, 1, ciphertextHourlyMax, "ok", "INFO"},
		{"sweep fails: 204 kept", time.Second, http.StatusNoContent, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}, err: missingIndex}, 1, ciphertextHourlyMax, "failed", "ERROR"},
		{"sweep panics: 204 kept", time.Second, http.StatusNoContent, &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}, panics: true}, 1, ciphertextHourlyMax, "failed", "ERROR"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			clock := newRouteClock(sweepClock)
			refreshed := false
			inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				refreshed = true
				clock.advance(tt.took)
				w.Header().Set("X-Refresh", "yes")
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte("refresh body"))
			})
			step := newCiphertextStep(tt.sw, false, &buf)
			step.sweeper = &orderCheck{fakeCiphertextSweeper: tt.sw, refreshed: &refreshed, t: t}
			rec := httptest.NewRecorder()
			withCiphertextSweep(inner, step, "p", clock.now).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/cron/trends-refresh", nil))
			if rec.Code != tt.status || rec.Header().Get("X-Refresh") != "yes" || rec.Body.String() != "refresh body" {
				t.Fatalf("response %d %q %q, want the refresh's own", rec.Code, rec.Header().Get("X-Refresh"), rec.Body.String())
			}
			line := oneSweepLine(t, &buf)
			if tt.sw.calls != tt.wantCalls || line["outcome"] != tt.wantOutcome || line["level"] != tt.wantLevel {
				t.Fatalf("calls %d line %v, want %d %s %s", tt.sw.calls, line, tt.wantCalls, tt.wantOutcome, tt.wantLevel)
			}
			if tt.sw.calls > 0 && (tt.sw.budget > tt.maxBudget || tt.sw.budget <= 0) {
				t.Errorf("the sweep got %v, want at most %v", tt.sw.budget, tt.maxBudget)
			}
		})
	}
	// A GET goes to the refresh alone (it answers 405) and never starts the sweep.
	var buf bytes.Buffer
	sw := &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{{}}}
	inner := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusMethodNotAllowed) })
	rec := httptest.NewRecorder()
	withCiphertextSweep(inner, newCiphertextStep(sw, false, &buf), "p", time.Now).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/internal/cron/trends-refresh", nil))
	if rec.Code != http.StatusMethodNotAllowed || sw.calls != 0 || buf.Len() != 0 {
		t.Fatalf("GET: %d, calls %d, log %s", rec.Code, sw.calls, buf.String())
	}
}

// orderCheck fails the test when the sweep starts before the refresh finished.
type orderCheck struct {
	*fakeCiphertextSweeper
	refreshed *bool
	t         *testing.T
}

func (o *orderCheck) SweepCiphertext(ctx context.Context, now time.Time, limit int) (messaging.CiphertextSweepResult, error) {
	if !*o.refreshed {
		o.t.Error("the sweep ran before the refresh")
	}
	return o.fakeCiphertextSweeper.SweepCiphertext(ctx, now, limit)
}
