package main

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// backfillStep is one scripted answer of fakeBackfiller.
type backfillStep struct {
	cp    posts.BackfillCheckpoint
	state posts.BackfillState
}

// fakeBackfiller returns the scripted steps in order; the first failFor calls fail instead. It records what it was
// called with, so the tests can check the checkpoint chain and the options.
type fakeBackfiller struct {
	steps   []backfillStep
	failFor int
	calls   []posts.BackfillCheckpoint
	opts    []posts.BackfillOptions
}

func (f *fakeBackfiller) BackfillHasMedia(_ context.Context, cp posts.BackfillCheckpoint, opts posts.BackfillOptions) (posts.BackfillCheckpoint, posts.BackfillState, error) {
	f.calls = append(f.calls, cp)
	f.opts = append(f.opts, opts)
	if len(f.calls) <= f.failFor {
		return cp, posts.BackfillMore, errors.New("transient")
	}
	i := len(f.calls) - 1 - f.failFor
	if i >= len(f.steps) {
		return cp, posts.BackfillDone, nil
	}
	return f.steps[i].cp, f.steps[i].state, nil
}

// doBackfill runs opsctl with a backends that holds only the fake backfiller; opened counts the opener calls.
func doBackfill(t *testing.T, f *fakeBackfiller, opened *int, stdin string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		*opened++
		return &backends{backfiller: f, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestBackfillHasMedia_UsageErrors(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no project", []string{"backfill-has-media"}, "--project is required"},
		{"after with a path separator", []string{"backfill-has-media", "--project", "dzeroth-dev", "--after", "a/b"}, "--after must be a post id"},
		{"after on another command", []string{"check-t26", "--project", "dzeroth-dev", "--after", "123"}, "--after is not supported by check-t26"},
		{"after on purge-posts", []string{"purge-posts", "--project", "dzeroth-dev", "--uid", "u1", "--after", "123"}, "--after is not supported by purge-posts"},
		{"dry-run is still rejected on commands without one", []string{"check-t26", "--project", "dzeroth-dev", "--dry-run"}, "--dry-run is not supported by check-t26"},
		{"stray argument", []string{"backfill-has-media", "--project", "dzeroth-dev", "extra"}, "unexpected argument"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f, opened := &fakeBackfiller{}, 0
			code, _, stderr := doBackfill(t, f, &opened, "", tt.args...)
			if code != 2 {
				t.Fatalf("exit code = %d, want 2; stderr=%q", code, stderr)
			}
			if !strings.Contains(stderr, tt.want) {
				t.Errorf("stderr = %q, want it to contain %q", stderr, tt.want)
			}
			if opened != 0 || len(f.calls) != 0 {
				t.Errorf("opened=%d calls=%d, want neither for a usage error", opened, len(f.calls))
			}
		})
	}
}

// TestBackfillHasMedia_NeedsNoUID: the command scans every post, so --uid is not required.
func TestBackfillHasMedia_NeedsNoUID(t *testing.T) {
	f, opened := &fakeBackfiller{}, 0
	if code, _, stderr := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev"); code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr)
	}
}

func TestBackfillHasMedia_ProdNeedsTypedConfirmation(t *testing.T) {
	for _, dry := range []bool{false, true} {
		args := []string{"backfill-has-media", "--project", "dzeroth-prod"}
		if dry {
			args = append(args, "--dry-run") // the dry run asks too, like purge-posts
		}
		f, opened := &fakeBackfiller{}, 0
		if code, _, stderr := doBackfill(t, f, &opened, "wrong\n", args...); code != 1 || opened != 0 || !strings.Contains(stderr, "confirmation did not match") {
			t.Errorf("dry=%v wrong confirmation: code=%d opened=%d stderr=%q", dry, code, opened, stderr)
		}
		if code, stdout, stderr := doBackfill(t, f, &opened, "dzeroth-prod\n", args...); code != 0 || opened != 1 || !strings.Contains(stdout, "PRODUCTION project") {
			t.Errorf("dry=%v right confirmation: code=%d opened=%d stdout=%q stderr=%q", dry, code, opened, stdout, stderr)
		}
	}
}

// TestBackfillHasMedia_Complete: the checkpoint chains from call to call, --after seeds the first one, the options are
// the production ones (zero value), and the run ends with the "complete" line.
func TestBackfillHasMedia_Complete(t *testing.T) {
	f := &fakeBackfiller{steps: []backfillStep{
		{posts.BackfillCheckpoint{After: "0200", Scanned: 500, Missing: 12, Updated: 12}, posts.BackfillMore},
		{posts.BackfillCheckpoint{After: "0300", Scanned: 700, Missing: 12, Updated: 12}, posts.BackfillDone},
	}}
	opened := 0
	code, stdout, stderr := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev", "--after", "0100")
	if code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr)
	}
	wantCalls := []posts.BackfillCheckpoint{{After: "0100"}, f.steps[0].cp}
	if !reflect.DeepEqual(f.calls, wantCalls) {
		t.Errorf("calls = %+v, want %+v", f.calls, wantCalls)
	}
	for _, o := range f.opts {
		if o != (posts.BackfillOptions{}) {
			t.Errorf("options = %+v, want the zero value (production page size and cap, real run)", o)
		}
	}
	for _, want := range []string{
		"call 1: scanned=0 missing=0 updated=0 checkpoint=0100 -> scanned=500 missing=12 updated=12 checkpoint=0200 done=false",
		"call 2: scanned=500 missing=12 updated=12 checkpoint=0200 -> scanned=700 missing=12 updated=12 checkpoint=0300 done=true",
		"backfill-has-media: reads=0 writes=0 deletes=0",
		"backfill-has-media: complete: scanned=700 updated=12 checkpoint=0300",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "write cap") {
		t.Errorf("a finished run must not mention the write cap:\n%s", stdout)
	}
}

// TestBackfillHasMedia_CleanRerun: a run that finds nothing to write ends "complete ... updated=0".
func TestBackfillHasMedia_CleanRerun(t *testing.T) {
	f := &fakeBackfiller{steps: []backfillStep{{posts.BackfillCheckpoint{After: "0300", Scanned: 700}, posts.BackfillDone}}}
	opened := 0
	code, stdout, _ := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(stdout, "backfill-has-media: complete: scanned=700 updated=0 checkpoint=0300") {
		t.Fatalf("code=%d stdout=%s", code, stdout)
	}
}

func TestBackfillHasMedia_Capped(t *testing.T) {
	f := &fakeBackfiller{steps: []backfillStep{
		{posts.BackfillCheckpoint{After: "0450", Scanned: 4000, Missing: 3000, Updated: 3000}, posts.BackfillMore},
		{posts.BackfillCheckpoint{After: "0777", Scanned: 7000, Missing: 5000, Updated: 5000}, posts.BackfillCapped},
	}}
	opened := 0
	code, stdout, stderr := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev")
	if code != 0 {
		t.Fatalf("a capped run is a normal stop: exit code = %d, stderr=%q", code, stderr)
	}
	for _, want := range []string{
		"backfill-has-media: write cap of 5000 reached: scanned=7000 updated=5000 checkpoint=0777",
		"rerun on another day with --after 0777",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "complete") {
		t.Errorf("a capped run must not say complete:\n%s", stdout)
	}
	if len(f.calls) != 2 {
		t.Errorf("calls = %d, want 2 (the loop stops at the cap)", len(f.calls))
	}
}

func TestBackfillHasMedia_DryRun(t *testing.T) {
	f := &fakeBackfiller{steps: []backfillStep{{posts.BackfillCheckpoint{After: "0300", Scanned: 12_000, Missing: 11_000}, posts.BackfillDone}}}
	opened := 0
	code, stdout, stderr := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev", "--dry-run")
	if code != 0 {
		t.Fatalf("exit code = %d, stderr=%q", code, stderr)
	}
	if !f.opts[0].DryRun {
		t.Error("--dry-run must reach the backfiller")
	}
	want := "dry-run: scanned=12000 missing=11000 would_update=11000 runs_needed=3 (nothing written)"
	if !strings.Contains(stdout, want) {
		t.Errorf("stdout missing %q:\n%s", want, stdout)
	}
	if strings.Contains(stdout, "complete") {
		t.Errorf("a dry run must not say complete:\n%s", stdout)
	}
}

func TestBackfillHasMedia_RetriesAFailedPageThenGivesUp(t *testing.T) {
	// Two transient failures, then success: the same checkpoint is retried.
	f := &fakeBackfiller{failFor: 2, steps: []backfillStep{{posts.BackfillCheckpoint{After: "0100", Scanned: 3, Missing: 1, Updated: 1}, posts.BackfillDone}}}
	opened := 0
	code, stdout, stderr := doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev")
	if code != 0 {
		t.Fatalf("exit code = %d, stderr=%q stdout=%q", code, stderr, stdout)
	}
	if len(f.calls) != 3 || f.calls[0] != f.calls[1] || f.calls[1] != f.calls[2] {
		t.Errorf("calls = %+v, want the same checkpoint three times", f.calls)
	}
	if !strings.Contains(stdout, "error: transient") {
		t.Errorf("stdout should show the failed pages:\n%s", stdout)
	}

	f = &fakeBackfiller{failFor: 100}
	code, _, stderr = doBackfill(t, f, &opened, "", "backfill-has-media", "--project", "dzeroth-dev")
	if code != 1 || !strings.Contains(stderr, "giving up after 5 consecutive errors") || len(f.calls) != 5 {
		t.Errorf("code=%d calls=%d stderr=%q, want exit 1 after 5 attempts", code, len(f.calls), stderr)
	}
}

func TestRunsNeeded(t *testing.T) {
	tests := []struct{ missing, want int }{
		{0, 0}, {1, 1}, {4999, 1}, {5000, 1}, {5001, 2}, {10_000, 2}, {10_001, 3},
	}
	for _, tt := range tests {
		if got := runsNeeded(tt.missing); got != tt.want {
			t.Errorf("runsNeeded(%d) = %d, want %d", tt.missing, got, tt.want)
		}
	}
}

func TestBackfillHasMedia_NoBackfiller(t *testing.T) {
	var out bytes.Buffer
	if err := backfillHasMedia(context.Background(), &backends{}, "", false, &out); err == nil {
		t.Fatal("a backends without a backfiller must be an error, not a nil dereference")
	}
}
