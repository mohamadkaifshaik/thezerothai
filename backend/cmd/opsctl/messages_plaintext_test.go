package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// fakePlaintext is a messaging.PlaintextPurger that answers from a script and records its calls.
type fakePlaintext struct {
	totals   messaging.PlaintextTotals
	countErr error
	pages    []messaging.PlaintextPage
	pageErr  error
	afters   []string
	modes    []messaging.PlaintextMode
	counts   int
}

func (f *fakePlaintext) CountPlaintext(context.Context) (messaging.PlaintextTotals, error) {
	f.counts++
	return f.totals, f.countErr
}

func (f *fakePlaintext) PurgePlaintextPage(_ context.Context, after string, mode messaging.PlaintextMode) (messaging.PlaintextPage, error) {
	f.afters = append(f.afters, after)
	f.modes = append(f.modes, mode)
	if f.pageErr != nil {
		return messaging.PlaintextPage{}, f.pageErr
	}
	p := f.pages[0]
	f.pages = f.pages[1:]
	return p, nil
}

// istNoon is 2026-11-26 06:30 UTC = 12:00 IST; istLate is 2026-11-25 20:00 UTC, already 2026-11-26 01:30 in IST.
var (
	istNoon = time.Date(2026, 11, 26, 6, 30, 0, 0, time.UTC)
	istLate = time.Date(2026, 11, 25, 20, 0, 0, 0, time.UTC)
)

// Message ids and texts the fake pages never return but a careless line could print; testConvID is the cursor.
const purgeCursor = "0123456789abcdef0123456789abcdef"

func plaintextPages() []messaging.PlaintextPage {
	return []messaging.PlaintextPage{
		{Last: strings.Repeat("a", 32), More: true, Conversations: 50, Messages: 120, Plaintext: 7, Purged: 6, Skipped: 1, Previews: 3, PreviewsSkipped: 1},
		{Last: purgeCursor, Conversations: 3, Messages: 9, Plaintext: 2, Purged: 2, Previews: 1},
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

func TestPurgePlaintext_RunsAndDryRuns(t *testing.T) {
	t.Parallel()
	for _, dry := range []bool{false, true} {
		p := &fakePlaintext{pages: plaintextPages()}
		args := []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26"}
		if dry {
			args = append(args, "--dry-run")
		}
		code, out, stderr, _ := runPlaintext(p, "", istNoon, args...)
		if code != 0 {
			t.Fatalf("dry=%v code=%d stderr=%q out=%q", dry, code, stderr, out)
		}
		want := messaging.PlaintextPurge
		if dry {
			want = messaging.PlaintextDryRun
		}
		if len(p.afters) != 2 || p.afters[0] != "" || p.afters[1] != strings.Repeat("a", 32) {
			t.Errorf("dry=%v afters = %v, want \"\" then the first page's last id", dry, p.afters)
		}
		for _, m := range p.modes {
			if m != want {
				t.Errorf("dry=%v ran a page in mode %d, want %d", dry, m, want)
			}
		}
		total := "conversations=53 messages=129 plaintext=9 purged=8 skipped=1 previews=4 previews_skipped=1"
		if !strings.Contains(out, total) {
			t.Errorf("dry=%v totals missing %q:\n%s", dry, total, out)
		}
		// The cursor is printed so a stopped run resumes with --after.
		if !strings.Contains(out, "after="+purgeCursor) {
			t.Errorf("dry=%v the cursor is not printed:\n%s", dry, out)
		}
	}
}

func TestPurgePlaintext_ResumesFromAfter(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pages: plaintextPages()[1:]}
	code, out, stderr, _ := runPlaintext(p, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--after", strings.Repeat("a", 32))
	if code != 0 || len(p.afters) != 1 || p.afters[0] != strings.Repeat("a", 32) {
		t.Errorf("code=%d afters=%v stderr=%q out=%q", code, p.afters, stderr, out)
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
		{"a bad cursor", []string{"purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26", "--after", "nope"}, "--after must be the conversation id"},
		{"confirm on the count", []string{"plaintext-count", "--project", "dzeroth-dev", "--confirm", "2026-11-26"}, "--confirm is for messages purge-plaintext only"},
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
	// --confirm on another command is refused too.
	if code, _, stderr, _ := runPlaintext(&fakePlaintext{}, "", istNoon, "takedown", testMsgTarget, "--project", "dzeroth-dev", "--confirm", "2026-11-26"); code != 2 || !strings.Contains(stderr, "--confirm is for") {
		t.Errorf("takedown --confirm: code=%d stderr=%q", code, stderr)
	}
}

// On prod the purge runs only with today's IST date AND the typed project id.
func TestPurgePlaintext_ProdNeedsBothConfirmations(t *testing.T) {
	t.Parallel()
	args := []string{"purge-plaintext", "--project", "dzeroth-prod", "--confirm", "2026-11-26"}
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

// No id or text in any audit line: counts only. The read-only count prints no id at all; the purge prints the
// conversation cursor only on the driver's per-call line (needed for --after), never on an audit line.
func TestPlaintext_NoIDOrTextInAuditLines(t *testing.T) {
	t.Parallel()
	ids := []string{strings.Repeat("a", 32), purgeCursor}
	check := func(name, out string, allowCursorLines bool) {
		t.Helper()
		audits := 0
		for _, line := range strings.Split(out, "\n") {
			isAudit := strings.HasPrefix(line, "audit:")
			if isAudit {
				audits++
				if !strings.Contains(line, "NOTICE") {
					t.Errorf("%s: audit line without NOTICE: %q", name, line)
				}
			}
			if !isAudit && allowCursorLines && strings.HasPrefix(line, "call ") {
				continue
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
	check("plaintext-count", out, false)
	_, out, _, _ = runPlaintext(&fakePlaintext{pages: plaintextPages()}, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26")
	check("purge-plaintext", out, true)
}

// A page that keeps failing stops the run with exit 1 after the driver's retries; the totals line still prints.
func TestPurgePlaintext_FailingPage(t *testing.T) {
	t.Parallel()
	p := &fakePlaintext{pageErr: errors.New("unavailable")}
	code, out, _, _ := runPlaintext(p, "", istNoon, "purge-plaintext", "--project", "dzeroth-dev", "--confirm", "2026-11-26")
	if code != 1 || len(p.afters) != maxConsecutiveErrors || !strings.Contains(out, "complete=false") {
		t.Errorf("code=%d calls=%d out=%q", code, len(p.afters), out)
	}
}
