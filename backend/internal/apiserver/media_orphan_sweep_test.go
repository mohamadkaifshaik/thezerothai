package apiserver

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// fakeOrphanSweeper answers pages from a script (the last one repeats).
type fakeOrphanSweeper struct {
	calls  int
	limit  int
	budget time.Duration // the deadline left when Sweep was first called
	pages  []media.OrphanSweepResult
	err    error
	panics bool
	// cut, when set, ends the parent context during the first Sweep (the budget running out mid-page): Sweep then answers
	// the context's error with cutRes.
	cut    context.CancelFunc
	cutRes media.OrphanSweepResult
}

func (f *fakeOrphanSweeper) Sweep(ctx context.Context, _ time.Time, limit int) (media.OrphanSweepResult, error) {
	f.calls++
	f.limit = limit
	if dl, ok := ctx.Deadline(); ok && f.calls == 1 {
		f.budget = time.Until(dl)
	}
	if f.panics {
		panic("boom")
	}
	if f.cut != nil {
		f.cut()
		<-ctx.Done()
		return f.cutRes, ctx.Err()
	}
	res := f.pages[min(f.calls, len(f.pages))-1]
	return res, f.err
}

func newStep(sw *fakeOrphanSweeper, mode config.MediaOrphanSweep, readOnly bool, buf *bytes.Buffer) mediaOrphanSweepStep {
	return mediaOrphanSweepStep{sweeper: sw, mode: mode, limit: 7, readOnly: readOnly, log: slog.New(slog.NewJSONHandler(buf, nil)), now: time.Now}
}

// The orphan sweep step logs counts, never fails the maintenance request, never panics out, does nothing while
// MEDIA_ORPHAN_SWEEP is off (one line says so), is skipped in readonly and when the chain has less than a second left,
// and never takes more than its own cap.
func TestMediaOrphanSweepStep(t *testing.T) {
	t.Parallel()
	one := media.OrphanSweepResult{Due: 3, Marked: 1, Deleted: 1, Held: 1}
	tests := []struct {
		name      string
		mode      config.MediaOrphanSweep
		readOnly  bool
		deadline  time.Duration // 0 = none
		err       error
		panics    bool
		wantCalls int
		wantLog   string
	}{
		{"ok", config.MediaOrphanSweepDelete, false, 0, nil, false, 1, `"msg":"media_orphan_sweep"`},
		{"mark mode runs", config.MediaOrphanSweepMark, false, 0, nil, false, 1, `"mode":"mark"`},
		{"off does nothing and says so", config.MediaOrphanSweepOff, false, 0, nil, false, 0, `"outcome":"disabled"`},
		{"the zero mode is off", "", false, 0, nil, false, 0, `"outcome":"disabled"`},
		{"failure is logged, not returned", config.MediaOrphanSweepDelete, false, 0, errors.New("firestore down"), false, 1, "media_orphan_sweep_failed"},
		{"a panic is recovered", config.MediaOrphanSweepDelete, false, 0, nil, true, 1, ""},
		{"readonly skips", config.MediaOrphanSweepDelete, true, 0, nil, false, 0, "skipped_readonly"},
		{"too little time skips", config.MediaOrphanSweepDelete, false, 500 * time.Millisecond, nil, false, 0, "skipped_deadline"},
		{"a long chain deadline is capped", config.MediaOrphanSweepDelete, false, time.Minute, nil, false, 1, `"outcome":"ok"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeOrphanSweeper{pages: []media.OrphanSweepResult{one}, err: tt.err, panics: tt.panics}
			ctx := context.Background()
			if tt.deadline > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, tt.deadline)
				defer cancel()
			}
			if err := newStep(sw, tt.mode, tt.readOnly, &buf).Refresh(ctx); err != nil {
				t.Fatalf("Refresh = %v, want nil", err)
			}
			if sw.calls != tt.wantCalls || !strings.Contains(buf.String(), tt.wantLog) {
				t.Fatalf("calls %d, log %s", sw.calls, buf.String())
			}
			if sw.calls == 1 && (sw.limit != 7 || sw.budget > mediaOrphanSweepMax) {
				t.Errorf("limit %d budget %v, want 7 and at most %v", sw.limit, sw.budget, mediaOrphanSweepMax)
			}
			if tt.name == "ok" && (!strings.Contains(buf.String(), `"deleted":1`) || !strings.Contains(buf.String(), `"marked":1`)) {
				t.Errorf("counts missing from %s", buf.String())
			}
			// One step line per run (Error Reporting adds its own entry on a failure).
			if n := strings.Count(buf.String(), `"msg":"media_orphan_sweep`); n != 1 && !tt.panics {
				t.Errorf("%d step lines, want exactly one per run: %s", n, buf.String())
			}
		})
	}
}

// The step pages while the budget lasts: on while a page is full and moved something, and the counts of every page add
// up in one line.
func TestMediaOrphanSweepStep_Pages(t *testing.T) {
	t.Parallel()
	full := media.OrphanSweepResult{Due: 7, More: true, Marked: 7}
	stuck := media.OrphanSweepResult{Due: 7, More: true, Conflicts: 7}
	tests := []struct {
		name      string
		pages     []media.OrphanSweepResult
		wantCalls int
		wantLog   string
	}{
		{"until a short page", []media.OrphanSweepResult{full, full, {Due: 2, Deleted: 2}}, 3, `"marked":14,"deleted":2`},
		{"stops on a page that moved nothing", []media.OrphanSweepResult{full, stuck, full}, 2, `"pages":2`},
		{"one short page", []media.OrphanSweepResult{{Due: 1, Held: 1}}, 1, `"pages":1`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeOrphanSweeper{pages: tt.pages}
			if err := newStep(sw, config.MediaOrphanSweepDelete, false, &buf).Refresh(context.Background()); err != nil {
				t.Fatal(err)
			}
			if sw.calls != tt.wantCalls || !strings.Contains(buf.String(), tt.wantLog) || !strings.Contains(buf.String(), `"outcome":"ok"`) {
				t.Fatalf("calls %d, log %s", sw.calls, buf.String())
			}
		})
	}
	// A sweeper that always has more stops at the page cap (a bound on one run's writes), and says there is more.
	var buf bytes.Buffer
	sw := &fakeOrphanSweeper{pages: []media.OrphanSweepResult{full}}
	if err := newStep(sw, config.MediaOrphanSweepDelete, false, &buf).Refresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	if sw.calls != mediaOrphanSweepMaxPages || !strings.Contains(buf.String(), `"more":true`) {
		t.Fatalf("calls %d log %s, want %d pages then a stop", sw.calls, buf.String(), mediaOrphanSweepMaxPages)
	}
	// And a context that ends between pages stops the loop before the next page.
	buf.Reset()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cancelAfterFirst := &cancelingSweeper{fakeOrphanSweeper: fakeOrphanSweeper{pages: []media.OrphanSweepResult{full}}, cancel: cancel}
	step := newStep(nil, config.MediaOrphanSweepDelete, false, &buf)
	step.sweeper = cancelAfterFirst
	if err := step.Refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if cancelAfterFirst.calls != 1 {
		t.Fatalf("calls %d, want the loop to stop once the budget is gone", cancelAfterFirst.calls)
	}
}

// cancelingSweeper ends the run's context after answering its first page.
type cancelingSweeper struct {
	fakeOrphanSweeper
	cancel context.CancelFunc
}

func (c *cancelingSweeper) Sweep(ctx context.Context, now time.Time, limit int) (media.OrphanSweepResult, error) {
	res, err := c.fakeOrphanSweeper.Sweep(ctx, now, limit)
	c.cancel()
	return res, err
}

// A page cut off by the budget with no failure is a partial run: an Info line with the counts, no failure line. With a
// failure in it, the line is an Error whatever the context says.
func TestMediaOrphanSweepStep_PartialRun(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		cut       media.OrphanSweepResult
		wantError bool
	}{
		{"cut without failures is partial", media.OrphanSweepResult{Due: 2, Deleted: 1, Skipped: 1}, false},
		{"cut with a failure is an error", media.OrphanSweepResult{Due: 2, Deleted: 1, Failed: 1}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			sw := &fakeOrphanSweeper{cut: cancel, cutRes: tt.cut}
			if err := newStep(sw, config.MediaOrphanSweepDelete, false, &buf).Refresh(ctx); err != nil {
				t.Fatalf("Refresh = %v", err)
			}
			out := buf.String()
			if sw.calls != 1 || !strings.Contains(out, `"deleted":1`) {
				t.Fatalf("log = %s", out)
			}
			isError := strings.Contains(out, "media_orphan_sweep_failed") && strings.Contains(out, `"level":"ERROR"`)
			if isError != tt.wantError {
				t.Fatalf("error line = %v, want %v: %s", isError, tt.wantError, out)
			}
			if !tt.wantError && !strings.Contains(out, `"outcome":"partial"`) {
				t.Fatalf("log = %s, want a partial line", out)
			}
		})
	}
}
