package apiserver

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
)

type fakeOrphanSweeper struct {
	calls  int
	limit  int
	budget time.Duration // the deadline left when Sweep was called
	res    media.OrphanSweepResult
	err    error
	panics bool
	// cut, when set, ends the parent context during Sweep (the budget running out mid-page): Sweep then answers the
	// context's error with partial counts.
	cut context.CancelFunc
}

func (f *fakeOrphanSweeper) Sweep(ctx context.Context, _ time.Time, limit int) (media.OrphanSweepResult, error) {
	f.calls++
	f.limit = limit
	if dl, ok := ctx.Deadline(); ok {
		f.budget = time.Until(dl)
	}
	if f.panics {
		panic("boom")
	}
	if f.cut != nil {
		f.cut()
		<-ctx.Done()
		return media.OrphanSweepResult{Due: 2, Deleted: 1, Failed: 1}, ctx.Err()
	}
	return f.res, f.err
}

// The orphan sweep step logs counts, never fails the maintenance request, never panics out, is skipped in readonly and
// when the chain has less than a second left, and never takes more than its own cap.
func TestMediaOrphanSweepStep(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		readOnly  bool
		deadline  time.Duration // 0 = none
		err       error
		panics    bool
		wantCalls int
		wantLog   string
	}{
		{"ok", false, 0, nil, false, 1, `"msg":"media_orphan_sweep"`},
		{"failure is logged, not returned", false, 0, errors.New("firestore down"), false, 1, "media_orphan_sweep_failed"},
		{"a panic is recovered", false, 0, nil, true, 1, ""},
		{"readonly skips", true, 0, nil, false, 0, "skipped_readonly"},
		{"too little time skips", false, 500 * time.Millisecond, nil, false, 0, "skipped_deadline"},
		{"a long chain deadline is capped", false, time.Minute, nil, false, 1, `"outcome":"ok"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var buf bytes.Buffer
			sw := &fakeOrphanSweeper{res: media.OrphanSweepResult{Due: 3, Marked: 1, Deleted: 1, Held: 1}, err: tt.err, panics: tt.panics}
			step := mediaOrphanSweepStep{sweeper: sw, limit: 7, readOnly: tt.readOnly, log: slog.New(slog.NewJSONHandler(&buf, nil)), now: time.Now}
			ctx := context.Background()
			if tt.deadline > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, tt.deadline)
				defer cancel()
			}
			if err := step.Refresh(ctx); err != nil {
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
		})
	}
}

// A page cut off by the budget is a partial run: an Info line with the counts, no failure line, no Error Reporting.
func TestMediaOrphanSweepStep_PartialRunIsNotAFailure(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sw := &fakeOrphanSweeper{cut: cancel}
	step := mediaOrphanSweepStep{sweeper: sw, limit: 7, log: slog.New(slog.NewJSONHandler(&buf, nil)), now: time.Now}
	if err := step.Refresh(ctx); err != nil {
		t.Fatalf("Refresh = %v", err)
	}
	out := buf.String()
	if sw.calls != 1 || !strings.Contains(out, `"outcome":"partial"`) || !strings.Contains(out, `"deleted":1`) || strings.Contains(out, "media_orphan_sweep_failed") || strings.Contains(out, `"level":"ERROR"`) {
		t.Fatalf("log = %s", out)
	}
}

type fakeHolds struct {
	m   map[string]bool
	err error
}

func (f fakeHolds) PendingScheduledMediaHolds(context.Context, string, []string) (map[string]bool, error) {
	return copyHolds(f.m), f.err
}
func (f fakeHolds) DraftCoverHolds(context.Context, string, []string) (map[string]bool, error) {
	return copyHolds(f.m), f.err
}

func copyHolds(m map[string]bool) map[string]bool {
	out := map[string]bool{}
	for k, v := range m {
		out[k] = v
	}
	return out
}

// draftMediaHolds is the union of both holders, and either one's error is the answer (never "free").
func TestDraftMediaHolds(t *testing.T) {
	t.Parallel()
	h := draftMediaHolds{scheduled: fakeHolds{m: map[string]bool{"a": true}}, articles: fakeHolds{m: map[string]bool{"b": true}}}
	got, err := h.HeldByDrafts(context.Background(), "uid", []string{"a", "b", "c"})
	if err != nil || !reflect.DeepEqual(got, map[string]bool{"a": true, "b": true}) {
		t.Fatalf("held = %v, %v", got, err)
	}
	boom := errors.New("boom")
	for _, h := range []draftMediaHolds{
		{scheduled: fakeHolds{err: boom}, articles: fakeHolds{}},
		{scheduled: fakeHolds{}, articles: fakeHolds{err: boom}},
	} {
		if _, err := h.HeldByDrafts(context.Background(), "uid", []string{"a"}); !errors.Is(err, boom) {
			t.Errorf("err = %v, want boom", err)
		}
	}
}
