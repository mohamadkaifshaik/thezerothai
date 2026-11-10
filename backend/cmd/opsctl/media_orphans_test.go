package main

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
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

// sweeperFactory returns a newMediaSweeper that hands out sw and records the switches it was built with.
type sweeperFactory struct {
	sw      *fakeMediaSweeper
	err     error
	built   int
	retire  config.ProfileMediaRetire
	dryRuns []bool
}

func (f *sweeperFactory) build(retire config.ProfileMediaRetire, dryRun bool) (mediaOrphanSweeper, error) {
	f.built++
	f.retire = retire
	f.dryRuns = append(f.dryRuns, dryRun)
	if f.err != nil {
		return nil, f.err
	}
	return f.sw, nil
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
		args      []string
		wantCode  int
		wantCalls int
		want      string
	}{
		{"runs until a short page", &fakeMediaSweeper{results: []media.OrphanSweepResult{more, last}}, nil, 0, 2, "due=103 marked=10 deleted=3"},
		{"stops on a page without progress", &fakeMediaSweeper{results: []media.OrphanSweepResult{{Due: media.OrphanSweepPage, More: true, Conflicts: media.OrphanSweepPage}, more}}, nil, 0, 1, "media-orphan-sweep: due="},
		{"stops at the page cap", &fakeMediaSweeper{results: func() []media.OrphanSweepResult {
			var r []media.OrphanSweepResult
			for range mediaOrphanSweepMaxPages + 5 {
				r = append(r, more)
			}
			return r
		}()}, nil, 0, mediaOrphanSweepMaxPages, "media-orphan-sweep: due="},
		{"an error stops it", &fakeMediaSweeper{err: errors.New("boom")}, nil, 1, 1, ""},
		{"a dry run reads exactly one page", &fakeMediaSweeper{results: []media.OrphanSweepResult{more, more}}, []string{"--dry-run"}, 0, 1, "dry-run: one page"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &sweeperFactory{sw: tt.sw}
			args := append([]string{"media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "banner"}, tt.args...)
			code, out, errOut := runMedia(t, &backends{newMediaSweeper: f.build}, args...)
			if code != tt.wantCode || tt.sw.calls != tt.wantCalls || !strings.Contains(out, tt.want) {
				t.Fatalf("code %d calls %d out %s err %s", code, tt.sw.calls, out, errOut)
			}
			if f.built != 1 || f.retire != config.ProfileMediaRetireBanner || f.dryRuns[0] != slices.Contains(tt.args, "--dry-run") {
				t.Fatalf("built %d retire %q dryRuns %v", f.built, f.retire, f.dryRuns)
			}
		})
	}
	if code, _, _ := runMedia(t, &backends{}, "media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "off"); code != 1 {
		t.Fatalf("no sweeper: code %d", code)
	}
	failing := &sweeperFactory{err: errors.New("no buckets")}
	if code, _, _ := runMedia(t, &backends{newMediaSweeper: failing.build}, "media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "off"); code != 1 {
		t.Fatalf("factory error: code %d", code)
	}
}

// TestMediaOrphanSweepCommand_ProfileRetireIsExplicit: the mode comes from --profile-retire only, never from the
// operator's shell, and the effective mode, project and clock are printed before anything runs (before the prod prompt).
func TestMediaOrphanSweepCommand_ProfileRetireIsExplicit(t *testing.T) {
	t.Setenv("PROFILE_MEDIA_RETIRE", "all")
	f := &sweeperFactory{sw: &fakeMediaSweeper{results: []media.OrphanSweepResult{{Due: 1, Held: 1}}}}
	code, out, errOut := runMedia(t, &backends{newMediaSweeper: f.build}, "media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "off")
	if code != 0 || f.retire != config.ProfileMediaRetireOff {
		t.Fatalf("code %d retire %q (err %s), want the flag's off, not the shell's all", code, f.retire, errOut)
	}
	header := "media-orphan-sweep: project=dzeroth-dev sweep=delete profile-retire=off dry-run=false clock=" + opsNow.Format(time.RFC3339)
	if !strings.HasPrefix(out, header) || strings.Index(out, "page 1") < strings.Index(out, header) {
		t.Fatalf("out = %q, want it to start with %q", out, header)
	}

	// Prod: the header is printed before the typed confirmation, and a wrong answer opens nothing.
	var buf, errBuf bytes.Buffer
	prod := &sweeperFactory{sw: &fakeMediaSweeper{}}
	b := &backends{newMediaSweeper: prod.build, close: func() {}}
	opened := false
	open := func(context.Context, string) (*backends, error) { opened = true; return b, nil }
	code = run(context.Background(), []string{"media-orphan-sweep", "--project", "dzeroth-prod", "--profile-retire", "all"}, strings.NewReader("nope\n"), &buf, &errBuf, open, func() time.Time { return opsNow })
	h, p := strings.Index(buf.String(), "profile-retire=all"), strings.Index(buf.String(), "PRODUCTION project")
	if code != 1 || opened || prod.built != 0 || h < 0 || p < 0 || h > p {
		t.Fatalf("code %d opened %v built %d out %q", code, opened, prod.built, buf.String())
	}
}

func TestMediaOrphanCommands_UsageErrors(t *testing.T) {
	for _, args := range [][]string{
		{"backfill-media-orphans"},
		{"media-orphan-sweep", "--project", "dzeroth-dev"},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", ""},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "avatar"},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "ALL"},
		{"media-orphan-sweep", "--project", "dzeroth-dev", "--profile-retire", "off", "--after", "1"},
		{"backfill-media-orphans", "--project", "dzeroth-dev", "--profile-retire", "off"},
		{"check-t26", "--project", "dzeroth-dev", "--profile-retire", "off"},
		{"backfill-media-orphans", "--project", "dzeroth-dev", "--after", "a/b"},
	} {
		f := &sweeperFactory{sw: &fakeMediaSweeper{}}
		if code, _, _ := runMedia(t, &backends{newMediaSweeper: f.build}, args...); code != 2 || f.built != 0 {
			t.Errorf("%v: code %d built %d, want 2 and nothing built", args, code, f.built)
		}
	}
}
