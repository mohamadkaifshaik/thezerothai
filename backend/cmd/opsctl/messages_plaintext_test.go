package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// fakePlaintext is a messaging.PlaintextPurger that answers from a script and records its calls. A scripted page with
// err set is returned together with that error (a page that wrote part of its work, then failed).
type fakePlaintext struct {
	totals   messaging.PlaintextTotals
	countErr error
	pages    []fakePlaintextPage
	pageErr  error
	afters   []string
	modes    []messaging.PlaintextMode
	counts   int
	// onCall runs at the start of each PurgePlaintextPage call (n = 1 for the first).
	onCall func(n int)
}

type fakePlaintextPage struct {
	page messaging.PlaintextPage
	err  error
}

func (f *fakePlaintext) CountPlaintext(context.Context) (messaging.PlaintextTotals, error) {
	f.counts++
	return f.totals, f.countErr
}

func (f *fakePlaintext) PurgePlaintextPage(_ context.Context, after string, mode messaging.PlaintextMode) (messaging.PlaintextPage, error) {
	f.afters = append(f.afters, after)
	f.modes = append(f.modes, mode)
	if f.onCall != nil {
		f.onCall(len(f.afters))
	}
	if f.pageErr != nil {
		return messaging.PlaintextPage{}, f.pageErr
	}
	p := f.pages[0]
	f.pages = f.pages[1:]
	return p.page, p.err
}

// istNoon is 2026-11-26 06:30 UTC = 12:00 IST; istLate is 2026-11-25 20:00 UTC, already 2026-11-26 01:30 in IST.
var (
	istNoon = time.Date(2026, 11, 26, 6, 30, 0, 0, time.UTC)
	istLate = time.Date(2026, 11, 25, 20, 0, 0, 0, time.UTC)
)

var (
	firstCursor = strings.Repeat("a", 32)
	purgeCursor = "0123456789abcdef0123456789abcdef"
)

func plaintextPages() []fakePlaintextPage {
	return []fakePlaintextPage{
		{page: messaging.PlaintextPage{Last: firstCursor, More: true, Conversations: 50, Messages: 120, Plaintext: 7, Purged: 6, Skipped: 1, Previews: 3, PreviewsSkipped: 1}},
		{page: messaging.PlaintextPage{Last: purgeCursor, Conversations: 3, Messages: 9, Plaintext: 2, Purged: 2, Previews: 1}},
	}
}

func runPlaintext(p *fakePlaintext, in string, now time.Time, args ...string) (code int, stdout, stderr string, opened bool) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		opened = true
		return &backends{plaintext: p, close: func() {}}, nil
	}
	code = run(context.Background(), append([]string{"messages"}, args...), strings.NewReader(in), &out, &errOut, open, func() time.Time { return now })
	return code, out.String(), errOut.String(), opened
}

// purgeArgs is a write run on dev with today's IST date and a checkpoint file in a fresh temp directory.
func purgeArgs(t *testing.T, extra ...string) (args []string, checkpoint string) {
	t.Helper()
	checkpoint = filepath.Join(t.TempDir(), "purge.checkpoint.json")
	return append([]string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--checkpoint", checkpoint}, extra...), checkpoint
}

func readPlaintextCheckpoint(t *testing.T, path string) plaintextCheckpointFile {
	t.Helper()
	data, err := os.ReadFile(path) //nolint:gosec // test temp file
	if err != nil {
		t.Fatal(err)
	}
	var c plaintextCheckpointFile
	if err := json.Unmarshal(data, &c); err != nil {
		t.Fatal(err)
	}
	return c
}

// The confirm date must be today in IST, read from the injected clock: no sleep, and the UTC date is not enough.
func TestCheckPurgeConfirm_TodayInIST(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		date string
		now  time.Time
		ok   bool
	}{
		{"today in IST at noon", "2026-11-26", istNoon, true},
		{"after midnight IST the IST date counts", "2026-11-26", istLate, true},
		{"the UTC date is not today in IST", "2026-11-25", istLate, false},
		{"yesterday (a pasted old command)", "2026-11-25", istNoon, false},
		{"tomorrow", "2026-11-27", istNoon, false},
		{"missing", "", istNoon, false},
		{"another format", "26-11-2026", istNoon, false},
		{"not a date", "2026-13-40", istNoon, false},
	}
	for _, tt := range tests {
		err := checkPurgeConfirm(tt.date, tt.now)
		if (err == nil) != tt.ok {
			t.Errorf("%s: err = %v, want ok=%v", tt.name, err, tt.ok)
		}
		var ue *usageError
		if err != nil && !errors.As(err, &ue) {
			t.Errorf("%s: %v is not a usage error", tt.name, err)
		}
	}
}

func TestPurgePlaintext_Runs(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: plaintextPages()}
	args, cp := purgeArgs(t)
	code, out, stderr, _ := runPlaintext(p, "", istNoon, args...)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q out=%q", code, stderr, out)
	}
	if len(p.afters) != 2 || p.afters[0] != "" || p.afters[1] != firstCursor {
		t.Errorf("afters = %v, want \"\" then the first page's last id", p.afters)
	}
	for _, m := range p.modes {
		if m != messaging.PlaintextPurge {
			t.Errorf("a page ran in mode %d", m)
		}
	}
	if total := "conversations=53 messages=129 plaintext=9 purged=8 skipped=1 previews=4 previews_skipped=1"; !strings.Contains(out, total) {
		t.Errorf("totals missing %q:\n%s", total, out)
	}
	// The resume point is in the checkpoint file only.
	if c := readPlaintextCheckpoint(t, cp); c.After != purgeCursor || c.State != "complete" || c.Project != "dzeroth-dev" || c.Command != plaintextCheckpointCommand {
		t.Errorf("checkpoint = %+v", c)
	}
	if !strings.Contains(out, "do not share it") || !strings.Contains(out, "messages plaintext-count") {
		t.Errorf("the header must warn about the checkpoint and the end must point at plaintext-count:\n%s", out)
	}
}

// A clean run tells the operator to confirm with plaintext-count instead of claiming nothing is left.
func TestPurgePlaintext_SuccessLinePointsAtTheCount(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: []fakePlaintextPage{{page: messaging.PlaintextPage{Last: purgeCursor, Conversations: 1, Messages: 1, Plaintext: 1, Purged: 1}}}}
	args, _ := purgeArgs(t)
	code, out, _, _ := runPlaintext(p, "", istNoon, args...)
	if code != 0 || !strings.Contains(out, "confirm nothing readable is left with `opsctl messages plaintext-count --project dzeroth-dev`") || strings.Contains(out, "is left\n") {
		t.Errorf("code=%d out:\n%s", code, out)
	}
}

func TestPurgePlaintext_DryRunWritesNoCheckpoint(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: plaintextPages()}
	code, out, stderr, _ := runPlaintext(p, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--dry-run")
	if code != 0 || len(p.modes) != 2 || p.modes[0] != messaging.PlaintextDryRun || !strings.Contains(out, "dry-run: would purge 9 message(s)") {
		t.Errorf("code=%d modes=%v stderr=%q out=%q", code, p.modes, stderr, out)
	}
	if _, err := os.Stat(defaultPlaintextCheckpoint); err == nil {
		t.Errorf("a dry run wrote %s", defaultPlaintextCheckpoint)
	}
}

// --resume continues from the checkpoint's resume point; --force starts over; neither overwrites by accident.
func TestPurgePlaintext_ResumeAndForce(t *testing.T) {
	t.Parallel()
	args, cp := purgeArgs(t)
	if err := writeCheckpointFile(cp, plaintextCheckpointFile{Version: plaintextCheckpointVersion, Command: plaintextCheckpointCommand, Project: "dzeroth-dev", After: firstCursor, State: "failed"}); err != nil {
		t.Fatal(err)
	}
	if code, _, stderr, opened := runPlaintext(&fakePlaintext{}, "", istNoon, args...); code != 2 || opened || !strings.Contains(stderr, "exists: pass --resume") {
		t.Errorf("existing checkpoint: code=%d opened=%v stderr=%q", code, opened, stderr)
	}
	p := &fakePlaintext{pages: plaintextPages()[1:]}
	if code, out, stderr, _ := runPlaintext(p, "", istNoon, append(args, "--resume")...); code != 0 || len(p.afters) != 1 || p.afters[0] != firstCursor {
		t.Errorf("--resume: code=%d afters=%v stderr=%q out=%q", code, p.afters, stderr, out)
	}
	p = &fakePlaintext{pages: plaintextPages()}
	if code, _, stderr, _ := runPlaintext(p, "", istNoon, append(args, "--force")...); code != 0 || len(p.afters) != 2 || p.afters[0] != "" {
		t.Errorf("--force: code=%d afters=%v stderr=%q", code, p.afters, stderr)
	}
	// A checkpoint of another project or command is refused.
	if err := writeCheckpointFile(cp, plaintextCheckpointFile{Version: plaintextCheckpointVersion, Command: plaintextCheckpointCommand, Project: "dzeroth-other", After: firstCursor}); err != nil {
		t.Fatal(err)
	}
	if code, _, stderr, _ := runPlaintext(&fakePlaintext{}, "", istNoon, append(args, "--resume")...); code != 2 || !strings.Contains(stderr, "not \"dzeroth-dev\"") {
		t.Errorf("other project: code=%d stderr=%q", code, stderr)
	}
	if err := writeCheckpointFile(cp, plaintextCheckpointFile{Version: plaintextCheckpointVersion, Command: plaintextCheckpointCommand, Project: "dzeroth-dev", After: "../x"}); err != nil {
		t.Fatal(err)
	}
	if code, _, stderr, _ := runPlaintext(&fakePlaintext{}, "", istNoon, append(args, "--resume")...); code != 2 || !strings.Contains(stderr, "not a conversation id") {
		t.Errorf("bad resume point: code=%d stderr=%q", code, stderr)
	}
}

// Refusals happen before anything is opened or confirmed.
func TestPurgePlaintext_Refusals(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no confirm", []string{"purge-plaintext", "--project", "dzeroth-dev"}, "needs --confirm 2026-11-26"},
		{"a pasted old date", []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-12"}, "not today's date in IST"},
		{"a prod run with an old date", []string{"purge-plaintext", "--project", "dzeroth-prod", "--confirm", "2026-11-25"}, "not today's date in IST"},
		{"no --after any more", []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--after", purgeCursor}, "--after is not supported"},
		{"resume and force", []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--resume", "--force"}, "exclusive"},
		{"a dry run with a checkpoint", []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--dry-run", "--resume"}, "not even a checkpoint"},
		{"confirm on the count", []string{"plaintext-count", "--project", "dzeroth-dev", "--confirm", "2026-11-26"}, "--confirm is for messages purge-plaintext only"},
		{"checkpoint on the count", []string{"plaintext-count", "--project", "dzeroth-dev", "--resume"}, "--resume is not supported"},
		{"dry-run on the count", []string{"plaintext-count", "--project", "dzeroth-dev", "--dry-run"}, "read-only"},
		{"after on the count", []string{"plaintext-count", "--project", "dzeroth-dev", "--after", purgeCursor}, "--after is not supported"},
		{"no project", []string{"purge-plaintext", "--confirm", "2026-11-26"}, "--project is required"},
	}
	for _, tt := range tests {
		p := &fakePlaintext{}
		code, _, stderr, opened := runPlaintext(p, "dzeroth-prod\n", istNoon, tt.args...)
		if code != 2 || opened || !strings.Contains(stderr, tt.want) {
			t.Errorf("%s: code=%d opened=%v stderr=%q, want exit 2 with %q and nothing opened", tt.name, code, opened, stderr, tt.want)
		}
	}
	if code, _, stderr, _ := runPlaintext(&fakePlaintext{}, "", istNoon, "takedown", testMsgTarget, "--project", "dzeroth-dev", "--confirm", "2026-11-26"); code != 2 || !strings.Contains(stderr, "--confirm is for") {
		t.Errorf("takedown --confirm: code=%d stderr=%q", code, stderr)
	}
}

// On prod the purge runs only with today's IST date AND the typed project id.
func TestPurgePlaintext_ProdNeedsBothConfirmations(t *testing.T) {
	t.Parallel()
	cp := filepath.Join(t.TempDir(), "prod.checkpoint.json")
	args := []string{"purge-plaintext", "--project", "dzeroth-prod", "--confirm", "2026-11-26", "--checkpoint", cp}
	p := &fakePlaintext{}
	if code, _, stderr, opened := runPlaintext(p, "dzeroth-dev\n", istNoon, args...); code != 1 || opened || !strings.Contains(stderr, "aborted") {
		t.Errorf("wrong typed id: code=%d opened=%v stderr=%q", code, opened, stderr)
	}
	p = &fakePlaintext{pages: plaintextPages()}
	if code, out, stderr, _ := runPlaintext(p, "dzeroth-prod\n", istNoon, args...); code != 0 || len(p.afters) != 2 {
		t.Errorf("confirmed prod run: code=%d calls=%v stderr=%q out=%q", code, p.afters, stderr, out)
	}
}

// The count is allowed on prod (after the typed project id) and stops after the aggregation when both counts are 0.
func TestPlaintextCount(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{}
	code, out, stderr, _ := runPlaintext(p, "dzeroth-prod\n", istNoon, "plaintext-count", "--project", "dzeroth-prod")
	if code != 0 || p.counts != 1 || len(p.afters) != 0 || !strings.Contains(out, "plaintext=0") || !strings.Contains(out, "no readable direct message") {
		t.Errorf("empty prod: code=%d counts=%d pages=%v stderr=%q out=%q", code, p.counts, p.afters, stderr, out)
	}

	p = &fakePlaintext{totals: messaging.PlaintextTotals{Conversations: 53, Messages: 129}, pages: plaintextPages()}
	code, out, stderr, _ = runPlaintext(p, "", istNoon, "plaintext-count", "--project", "dzeroth-dev")
	if code != 0 || len(p.afters) != 2 || !strings.Contains(out, "plaintext=9") || !strings.Contains(out, "9 readable direct message(s)") {
		t.Errorf("non-empty: code=%d pages=%v stderr=%q out=%q", code, p.afters, stderr, out)
	}
	for _, m := range p.modes {
		if m != messaging.PlaintextCountOnly {
			t.Errorf("the count ran a page in mode %d", m)
		}
	}

	p = &fakePlaintext{countErr: errors.New("boom")}
	if code, _, _, _ := runPlaintext(p, "", istNoon, "plaintext-count", "--project", "dzeroth-dev"); code != 1 {
		t.Errorf("a failing aggregation must exit 1, got %d", code)
	}
}

// No id or text on any output line of either command: page numbers and counts only (the resume point is in the file).
func TestPlaintext_NoIDOrTextInOutput(t *testing.T) {
	t.Parallel()
	ids := []string{firstCursor, purgeCursor}
	check := func(name, out string) {
		t.Helper()
		audits := 0
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "audit:") {
				audits++
				if !strings.Contains(line, "NOTICE") {
					t.Errorf("%s: audit line without NOTICE: %q", name, line)
				}
			}
			for _, id := range ids {
				if strings.Contains(line, id) {
					t.Errorf("%s: line %q holds an id", name, line)
				}
			}
		}
		if audits < 3 { // one per page (2) and the final totals
			t.Errorf("%s: %d audit lines, want one per page plus the totals:\n%s", name, audits, out)
		}
	}
	_, out, _, _ := runPlaintext(&fakePlaintext{totals: messaging.PlaintextTotals{Conversations: 1}, pages: plaintextPages()}, "", istNoon, "plaintext-count", "--project", "dzeroth-dev")
	check("plaintext-count", out)
	args, _ := purgeArgs(t)
	_, out, _, _ = runPlaintext(&fakePlaintext{pages: plaintextPages()}, "", istNoon, args...)
	check("purge-plaintext", out)
}

// A page that keeps failing stops the run with exit 1 after the driver's retries; the totals line still prints and the
// checkpoint says failed at the last good page.
func TestPurgePlaintext_FailingPage(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pageErr: errors.New("unavailable")}
	args, cp := purgeArgs(t)
	code, out, stderr, _ := runPlaintext(p, "", istNoon, args...)
	if code != 1 || len(p.afters) != maxConsecutiveErrors || !strings.Contains(out, "complete=false") || !strings.Contains(stderr, "rerun with --resume") {
		t.Errorf("code=%d calls=%d out=%q stderr=%q", code, len(p.afters), out, stderr)
	}
	if c := readPlaintextCheckpoint(t, cp); c.State != "failed" || c.After != "" {
		t.Errorf("checkpoint = %+v, want failed at the start", c)
	}
}

// A page that wrote part of its work and then failed: its write counts reach the totals (those writes happened), its read
// counts do not (the retry reads the page again), and the retry's own counts add on top.
func TestPurgePlaintext_PartialPageWritesAreCounted(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: []fakePlaintextPage{
		{page: messaging.PlaintextPage{Conversations: 10, Messages: 40, Plaintext: 5, Purged: 3, Skipped: 1, Previews: 2, PreviewsSkipped: 1}, err: errors.New("deadline")},
		{page: messaging.PlaintextPage{Last: purgeCursor, Conversations: 20, Messages: 60, Plaintext: 2, Purged: 2, Previews: 1}},
	}}
	args, _ := purgeArgs(t)
	code, out, stderr, _ := runPlaintext(p, "", istNoon, args...)
	if code != 0 || len(p.afters) != 2 || p.afters[1] != "" {
		t.Fatalf("code=%d afters=%v stderr=%q out=%q", code, p.afters, stderr, out)
	}
	if want := "conversations=20 messages=60 plaintext=2 purged=5 skipped=1 previews=3 previews_skipped=1"; !strings.Contains(out, want) {
		t.Errorf("totals missing %q:\n%s", want, out)
	}
}

// A dry run's failed attempt adds nothing: its "would rewrite" counts are recounted by the retry.
func TestPurgePlaintext_DryRunPartialPageIsNotCounted(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: []fakePlaintextPage{
		{page: messaging.PlaintextPage{Conversations: 10, Messages: 40, Plaintext: 5, Previews: 2}, err: errors.New("deadline")},
		{page: messaging.PlaintextPage{Last: purgeCursor, Conversations: 20, Messages: 60, Plaintext: 5, Previews: 2}},
	}}
	code, out, stderr, _ := runPlaintext(p, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--dry-run")
	if code != 0 || len(p.afters) != 2 {
		t.Fatalf("code=%d afters=%v stderr=%q out=%q", code, p.afters, stderr, out)
	}
	if want := "conversations=20 messages=60 plaintext=5 purged=0 skipped=0 previews=2 previews_skipped=0"; !strings.Contains(out, want) {
		t.Errorf("totals missing %q:\n%s", want, out)
	}
}

// A checkpoint that cannot be saved after a page stops the run at once: no retry, no further page, exit 1, and the
// message names the checkpoint path (no id).
func TestPurgePlaintext_CheckpointSaveFailureIsFatal(t *testing.T) {
	t.Parallel()
	dir := filepath.Join(t.TempDir(), "cp")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	cp := filepath.Join(dir, "purge.checkpoint.json")
	p := &fakePlaintext{pages: plaintextPages(), onCall: func(n int) {
		if n == 1 {
			// The run saved its first checkpoint; the directory goes away, so the save after this page fails.
			if err := os.RemoveAll(dir); err != nil {
				t.Error(err)
			}
		}
	}}
	code, out, stderr, _ := runPlaintext(p, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--checkpoint", cp)
	if code != 1 || len(p.afters) != 1 {
		t.Fatalf("code=%d page calls=%d, want exit 1 after the one page (no retry, no next page)\nstdout=%s\nstderr=%s", code, len(p.afters), out, stderr)
	}
	if !strings.Contains(stderr, "checkpoint "+cp+" could not be saved") || !strings.Contains(out, "complete=false") {
		t.Errorf("stderr=%q out=%q", stderr, out)
	}
	for _, id := range []string{firstCursor, purgeCursor} {
		if strings.Contains(stderr, id) || strings.Contains(out, id) {
			t.Errorf("output holds an id:\nstdout=%s\nstderr=%s", out, stderr)
		}
	}
}
