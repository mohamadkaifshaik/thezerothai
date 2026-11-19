package apiserver

import (
	"bytes"
	"context"
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
	return f.pages[min(f.calls, len(f.pages))-1], f.err
}

var sweepClock = time.Date(2026, 12, 20, 3, 0, 0, 0, time.UTC)

func newCiphertextStep(sw messaging.CiphertextSweeper, readOnly bool, buf *bytes.Buffer) ciphertextSweepStep {
	return ciphertextSweepStep{sweeper: sw, limit: 9, readOnly: readOnly, log: slog.New(slog.NewJSONHandler(buf, nil)), now: func() time.Time { return sweepClock }}
}

// missingIndex is what Firestore answers a collection-group query whose index is not deployed.
var missingIndex = status.Error(codes.FailedPrecondition, "The query requires an index. You can create it here: https://console.firebase.google.com/project/p/firestore/indexes?create_exemption=x")

// The ciphertext sweep step logs counts, never fails the maintenance request, never panics out, does nothing in readonly or
// with less than a second left, takes at most its own budget, and passes its limit and the injected clock.
func TestCiphertextSweepStep(t *testing.T) {
	t.Parallel()
	one := messaging.CiphertextSweepResult{Due: 3, Swept: 2, Skipped: 1}
	tests := []struct {
		name      string
		readOnly  bool
		deadline  time.Duration // 0 = none
		err       error
		panics    bool
		wantCalls int
		wantLog   string
	}{
		{"ok", false, 0, nil, false, 1, `"outcome":"ok"`},
		{"a missing index is logged, not returned", false, 0, missingIndex, false, 1, "ciphertext_sweep_failed"},
		{"a panic is recovered", false, 0, nil, true, 1, ""},
		{"readonly does nothing", true, 0, nil, false, 0, "skipped_readonly"},
		{"too little time skips", false, 500 * time.Millisecond, nil, false, 0, "skipped_deadline"},
		{"a long chain deadline is capped", false, time.Minute, nil, false, 1, `"outcome":"ok"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeCiphertextSweeper{pages: []messaging.CiphertextSweepResult{one}, err: tt.err, panics: tt.panics}
			ctx := context.Background()
			if tt.deadline > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, tt.deadline)
				defer cancel()
			}
			if err := newCiphertextStep(sw, tt.readOnly, &buf).Refresh(ctx); err != nil {
				t.Fatalf("Refresh = %v, want nil", err)
			}
			out := buf.String()
			if sw.calls != tt.wantCalls || !strings.Contains(out, tt.wantLog) {
				t.Fatalf("calls %d, log %s", sw.calls, out)
			}
			if sw.calls == 1 && (sw.limit != 9 || sw.budget > ciphertextSweepMax || !sw.at[0].Equal(sweepClock)) {
				t.Errorf("limit %d budget %v now %v, want 9, at most %v, the injected clock", sw.limit, sw.budget, sw.at[0], ciphertextSweepMax)
			}
			if tt.name == "ok" && !strings.Contains(out, `"due":3,"swept":2,"skipped":1`) {
				t.Errorf("counts missing from %s", out)
			}
			if tt.panics {
				return
			}
			if n := strings.Count(out, `"msg":"ciphertext_sweep`); n != 1 {
				t.Errorf("%d step lines, want exactly one per run: %s", n, out)
			}
		})
	}
}

// The step pages while a page is full and swept something, stops at the page cap with "partial" and more = true, and the
// counts of every page add up in one line.
func TestCiphertextSweepStep_Pages(t *testing.T) {
	t.Parallel()
	full := messaging.CiphertextSweepResult{Due: 9, Swept: 8, Skipped: 1, More: true}
	stuck := messaging.CiphertextSweepResult{Due: 9, Skipped: 9, More: true}
	tests := []struct {
		name      string
		pages     []messaging.CiphertextSweepResult
		wantCalls int
		wantLog   string
	}{
		{"until a short page", []messaging.CiphertextSweepResult{full, full, {Due: 2, Swept: 2}}, 3, `"pages":3,"due":20,"swept":18,"skipped":2,"more":false,"outcome":"ok"`},
		{"stops on a page that swept nothing", []messaging.CiphertextSweepResult{full, stuck, full}, 2, `"pages":2`},
		{"nothing due", []messaging.CiphertextSweepResult{{}}, 1, `"pages":1,"due":0`},
		{"the cap ends a backlog run", []messaging.CiphertextSweepResult{full}, ciphertextSweepMaxPages, `"more":true,"outcome":"partial"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeCiphertextSweeper{pages: tt.pages}
			if err := newCiphertextStep(sw, false, &buf).Refresh(context.Background()); err != nil {
				t.Fatal(err)
			}
			if sw.calls != tt.wantCalls || !strings.Contains(buf.String(), tt.wantLog) {
				t.Fatalf("calls %d, log %s", sw.calls, buf.String())
			}
		})
	}
}

// okStep counts its runs.
type okStep struct{ runs *atomic.Int32 }

func (s okStep) Refresh(context.Context) error { s.runs.Add(1); return nil }

// At the end of the real chain shape, a ciphertext sweep whose query fails (the index not deployed) or panics changes
// nothing: every earlier step ran, the request answers the backstop's status, one failure line names no id.
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
			if tc.name == "missing index" && !strings.Contains(buf.String(), "ciphertext_sweep_failed") {
				t.Errorf("no failure line: %s", buf.String())
			}
		})
	}
}
