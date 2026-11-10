package main

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
)

// fakeMediaBackfiller answers pages from a script; it records the checkpoints and options it was called with.
type fakeMediaBackfiller struct {
	pages   []media.OrphanBackfillPage
	err     error
	afters  []string
	dryRuns []bool
	checkAt []time.Time
}

func (f *fakeMediaBackfiller) BackfillOrphanChecks(_ context.Context, after string, limit int, checkAt time.Time, dryRun bool) (media.OrphanBackfillPage, error) {
	f.afters = append(f.afters, after)
	f.dryRuns = append(f.dryRuns, dryRun)
	f.checkAt = append(f.checkAt, checkAt)
	if f.err != nil {
		return media.OrphanBackfillPage{}, f.err
	}
	i := len(f.afters) - 1
	if i >= len(f.pages) {
		return media.OrphanBackfillPage{}, nil
	}
	return f.pages[i], nil
}

type fakeMediaSweeper struct {
	results []media.OrphanSweepResult
	err     error
	calls   int
}

func (f *fakeMediaSweeper) Sweep(context.Context, time.Time, int) (media.OrphanSweepResult, error) {
	f.calls++
	if f.calls > len(f.results) {
		return media.OrphanSweepResult{}, f.err
	}
	return f.results[f.calls-1], f.err
}

var opsNow = time.Unix(1_000_000, 0).UTC()

func runMedia(t *testing.T, b *backends, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut bytes.Buffer
	b.close = func() {}
	open := func(context.Context, string) (*backends, error) { return b, nil }
	code := run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, func() time.Time { return opsNow })
	return code, out.String(), errOut.String()
}

func TestBackfillMediaOrphans(t *testing.T) {
	full := media.OrphanBackfillPage{Scanned: mediaOrphanBackfillPage, Eligible: 3, Set: 3, Last: "0000000000000000100"}
	tail := media.OrphanBackfillPage{Scanned: 5, Eligible: 1, Set: 1, Conflicts: 1, Last: "0000000000000000105"}
	f := &fakeMediaBackfiller{pages: []media.OrphanBackfillPage{full, tail}}
	code, out, errOut := runMedia(t, &backends{mediaBackfill: f}, "backfill-media-orphans", "--project", "dzeroth-dev", "--after", "0000000000000000007")
	if code != 0 {
		t.Fatalf("code %d, stderr %s", code, errOut)
	}
	if !reflect.DeepEqual(f.afters, []string{"0000000000000000007", "0000000000000000100"}) {
		t.Errorf("checkpoints = %v", f.afters)
	}
	if !f.checkAt[0].Equal(opsNow.Add(media.OrphanAfter)) || f.dryRuns[0] {
		t.Errorf("checkAt %v dryRun %v", f.checkAt[0], f.dryRuns[0])
	}
	if !strings.Contains(out, "complete: scanned=105 set=4 conflicts=1") {
		t.Errorf("out = %s", out)
	}

	dry := &fakeMediaBackfiller{pages: []media.OrphanBackfillPage{{Scanned: 2, Eligible: 2, Last: "0000000000000000002"}}}
	if code, out, _ := runMedia(t, &backends{mediaBackfill: dry}, "backfill-media-orphans", "--project", "dzeroth-dev", "--dry-run"); code != 0 || !dry.dryRuns[0] || !strings.Contains(out, "would_set=2") {
		t.Fatalf("dry run: code %d out %s", code, out)
	}

	// The write cap stops a run and prints the checkpoint.
	var pages []media.OrphanBackfillPage
	for range mediaOrphanBackfillMaxWrites/mediaOrphanBackfillPage + 1 {
		pages = append(pages, media.OrphanBackfillPage{Scanned: mediaOrphanBackfillPage, Eligible: mediaOrphanBackfillPage, Set: mediaOrphanBackfillPage, Last: "0000000000000000999"})
	}
	capped := &fakeMediaBackfiller{pages: pages}
	if code, out, _ := runMedia(t, &backends{mediaBackfill: capped}, "backfill-media-orphans", "--project", "dzeroth-dev"); code != 0 || !strings.Contains(out, "write cap") || len(capped.afters) != mediaOrphanBackfillMaxWrites/mediaOrphanBackfillPage {
		t.Fatalf("cap: code %d pages %d out %s", code, len(capped.afters), out)
	}

	failing := &fakeMediaBackfiller{err: errors.New("unavailable")}
	if code, _, errOut := runMedia(t, &backends{mediaBackfill: failing}, "backfill-media-orphans", "--project", "dzeroth-dev"); code != 1 || !strings.Contains(errOut, "rerun with --after") {
		t.Fatalf("failure: code %d stderr %s", code, errOut)
	}
	if code, _, _ := runMedia(t, &backends{}, "backfill-media-orphans", "--project", "dzeroth-dev"); code != 1 {
		t.Fatalf("no repo: code %d", code)
	}
}

func TestMediaOrphanSweepCommand(t *testing.T) {
	more := media.OrphanSweepResult{Due: media.OrphanSweepPage, More: true, Marked: 10}
	last := media.OrphanSweepResult{Due: 3, Deleted: 3}
	tests := []struct {
		name      string
		sw        *fakeMediaSweeper
		retireErr error
		wantCode  int
		wantCalls int
		want      string
	}{
		{"runs until a short page", &fakeMediaSweeper{results: []media.OrphanSweepResult{more, last}}, nil, 0, 2, "due=103 marked=10 deleted=3"},
		{"stops on a page without progress", &fakeMediaSweeper{results: []media.OrphanSweepResult{{Due: media.OrphanSweepPage, More: true, Conflicts: media.OrphanSweepPage}, more}}, nil, 0, 1, "media-orphan-sweep:"},
		{"stops at the page cap", &fakeMediaSweeper{results: func() []media.OrphanSweepResult {
			var r []media.OrphanSweepResult
			for range mediaOrphanSweepMaxPages + 5 {
				r = append(r, more)
			}
			return r
		}()}, nil, 0, mediaOrphanSweepMaxPages, "media-orphan-sweep:"},
		{"an error stops it", &fakeMediaSweeper{err: errors.New("boom")}, nil, 1, 1, ""},
		{"a bad PROFILE_MEDIA_RETIRE is refused", &fakeMediaSweeper{}, errors.New("invalid"), 1, 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out, errOut := runMedia(t, &backends{mediaSweeper: tt.sw, retireErr: tt.retireErr}, "media-orphan-sweep", "--project", "dzeroth-dev")
			if code != tt.wantCode || tt.sw.calls != tt.wantCalls || !strings.Contains(out, tt.want) {
				t.Fatalf("code %d calls %d out %s err %s", code, tt.sw.calls, out, errOut)
			}
		})
	}
	if code, _, _ := runMedia(t, &backends{}, "media-orphan-sweep", "--project", "dzeroth-dev"); code != 1 {
		t.Fatalf("no sweeper: code %d", code)
	}
}

func TestMediaOrphanCommands_UsageErrors(t *testing.T) {
	for _, args := range [][]string{
		{"backfill-media-orphans"},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--dry-run"},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--after", "1"},
		{"backfill-media-orphans", "--project", "dzeroth-dev", "--after", "a/b"},
	} {
		if code, _, _ := runMedia(t, &backends{}, args...); code != 2 {
			t.Errorf("%v: code %d, want 2", args, code)
		}
	}
}

type fakeHoldsSource struct {
	m   map[string]bool
	err error
}

func (f fakeHoldsSource) PendingScheduledMediaHolds(context.Context, string, []string) (map[string]bool, error) {
	return map[string]bool{"a": f.m["a"]}, f.err
}
func (f fakeHoldsSource) DraftCoverHolds(context.Context, string, []string) (map[string]bool, error) {
	return map[string]bool{"b": f.m["b"]}, f.err
}

func TestDraftHolds(t *testing.T) {
	h := draftHolds{scheduled: fakeHoldsSource{m: map[string]bool{"a": true}}, articles: fakeHoldsSource{m: map[string]bool{"b": true}}}
	got, err := h.HeldByDrafts(context.Background(), "u", []string{"a", "b"})
	if err != nil || !got["a"] || !got["b"] {
		t.Fatalf("held = %v, %v", got, err)
	}
	boom := errors.New("boom")
	for _, h := range []draftHolds{{scheduled: fakeHoldsSource{err: boom}, articles: fakeHoldsSource{}}, {scheduled: fakeHoldsSource{}, articles: fakeHoldsSource{err: boom}}} {
		if _, err := h.HeldByDrafts(context.Background(), "u", nil); !errors.Is(err, boom) {
			t.Errorf("err = %v", err)
		}
	}
}
