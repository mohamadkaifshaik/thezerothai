package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const testBeaconID = "1234567890123456780"

// fakeBeacons is a beacons.Moderator over one in-memory beacon.
type fakeBeacons struct {
	exists bool
	hidden bool
	err    error
	sets   int
}

func (f *fakeBeacons) SetHidden(_ context.Context, _ string, hidden bool, _ time.Time) (bool, error) {
	if f.err != nil {
		return false, f.err
	}
	if !f.exists {
		return false, beacons.ErrNotFound
	}
	if f.hidden == hidden {
		return false, nil
	}
	f.hidden = hidden
	f.sets++
	return true, nil
}

func (f *fakeBeacons) Get(_ context.Context, id string) (beacons.Beacon, error) {
	if !f.exists {
		return beacons.Beacon{}, beacons.ErrNotFound
	}
	return beacons.Beacon{ID: id, Title: "SECRET TITLE", Venue: "SECRET VENUE", OrganiserID: "secret-organiser", Hidden: f.hidden}, nil
}

func runBeacon(f *fakeBeacons, ops *fakeOps, stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{beacons: f, reports: ops, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestBeacon_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no sub-command", []string{"beacon", "--project", "dzeroth-dev"}, "beacon needs a sub-command"},
		{"unknown sub-command", []string{"beacon", "purge", "--project", "dzeroth-dev"}, "beacon needs a sub-command"},
		{"hide without an id", []string{"beacon", "hide", "--project", "dzeroth-dev"}, "needs the beacon id"},
		{"restore without an id", []string{"beacon", "restore", "--project", "dzeroth-dev"}, "needs the beacon id"},
		{"short id", []string{"beacon", "hide", "123", "--project", "dzeroth-dev"}, "19 digits"},
		{"letters in the id", []string{"beacon", "hide", "123456789012345678x", "--project", "dzeroth-dev"}, "19 digits"},
		{"two ids", []string{"beacon", "hide", testBeaconID, testBeaconID, "--project", "dzeroth-dev"}, "unexpected argument"},
		{"no project", []string{"beacon", "hide", testBeaconID}, "--project is required"},
		{"report on restore", []string{"beacon", "restore", testBeaconID, "--report", testListReportID, "--project", "dzeroth-dev"}, "--report is for beacon hide only"},
		{"note without report", []string{"beacon", "hide", testBeaconID, "--note", "x", "--project", "dzeroth-dev"}, "needs --report"},
		{"bad report id", []string{"beacon", "hide", testBeaconID, "--report", "xyz", "--project", "dzeroth-dev"}, "32-character report id"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := &fakeBeacons{exists: true}
			code, _, errOut := runBeacon(f, &fakeOps{}, "", tt.args...)
			if code != 2 || !strings.Contains(errOut, tt.want) {
				t.Fatalf("code=%d stderr=%q, want 2 containing %q", code, errOut, tt.want)
			}
			if f.sets != 0 {
				t.Errorf("a usage error did work: sets=%d", f.sets)
			}
		})
	}
}

func TestBeacon_HideRestoreAndOutput(t *testing.T) {
	t.Parallel()
	f := &fakeBeacons{exists: true}
	hash := logger.HashUID(testBeaconID)
	steps := []struct {
		name string
		args []string
		want []string
		not  []string
	}{
		// R18: hidden is invisible, not frozen. The organiser still sees and manages the beacon; the printed line must say so.
		{"hide", []string{"beacon", "hide", testBeaconID}, []string{"hidden: beacon_hash=" + hash, "wrote=true", "everyone but its organiser", "the organiser still sees it"}, []string{"the organiser too"}},
		{"hide again", []string{"beacon", "hide", testBeaconID}, []string{"already hidden", "wrote=false"}, nil},
		{"dry-run restore writes nothing", []string{"beacon", "restore", testBeaconID, "--dry-run"}, []string{"currently hidden=true", "would write"}, []string{"audit:"}},
		{"restore", []string{"beacon", "restore", testBeaconID}, []string{"restored: beacon_hash=" + hash, "wrote=true"}, nil},
		{"restore again", []string{"beacon", "restore", testBeaconID}, []string{"not hidden", "wrote=false"}, nil},
	}
	for _, s := range steps {
		code, out, errOut := runBeacon(f, &fakeOps{}, "", append(s.args, "--project", "dzeroth-dev")...)
		if code != 0 {
			t.Fatalf("%s: code %d stderr %q", s.name, code, errOut)
		}
		for _, w := range s.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\n%s", s.name, w, out)
			}
		}
		for _, n := range s.not {
			if strings.Contains(out, n) {
				t.Errorf("%s: output has %q:\n%s", s.name, n, out)
			}
		}
		// Only hashed ids, and never the beacon's text or organiser.
		for _, secret := range []string{testBeaconID, "SECRET TITLE", "SECRET VENUE", "secret-organiser"} {
			if strings.Contains(out, secret) {
				t.Errorf("%s: output carries %q:\n%s", s.name, secret, out)
			}
		}
	}
	if f.sets != 2 {
		t.Errorf("writes = %d, want 2 (hide, restore)", f.sets)
	}
}

func TestBeacon_MissingBeaconIsRefused(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{{"beacon", "hide", testBeaconID}, {"beacon", "restore", testBeaconID}, {"beacon", "hide", testBeaconID, "--dry-run"}} {
		f := &fakeBeacons{}
		code, out, errOut := runBeacon(f, &fakeOps{}, "", append(args, "--project", "dzeroth-dev")...)
		if code != 1 || !strings.Contains(errOut, "no such beacon") || strings.Contains(out, "audit:") || f.sets != 0 {
			t.Errorf("%v: code=%d stdout=%q stderr=%q", args, code, out, errOut)
		}
	}
}

func TestBeacon_StoreErrorIsAFailureNotAUsageError(t *testing.T) {
	t.Parallel()
	f := &fakeBeacons{exists: true, err: errors.New("deadline")}
	if code, _, errOut := runBeacon(f, &fakeOps{}, "", "beacon", "hide", testBeaconID, "--project", "dzeroth-dev"); code != 1 || !strings.Contains(errOut, "deadline") {
		t.Errorf("code=%d stderr=%q", code, errOut)
	}
}

func TestBeacon_ProdNeedsTypedConfirmation(t *testing.T) {
	t.Parallel()
	f := &fakeBeacons{exists: true}
	if code, _, _ := runBeacon(f, &fakeOps{}, "nope\n", "beacon", "hide", testBeaconID, "--project", "dzeroth-prod"); code != 1 || f.sets != 0 {
		t.Errorf("wrong confirmation: code=%d sets=%d", code, f.sets)
	}
	if code, _, _ := runBeacon(f, &fakeOps{}, "dzeroth-prod\n", "beacon", "hide", testBeaconID, "--project", "dzeroth-prod"); code != 0 || f.sets != 1 {
		t.Errorf("right confirmation: code=%d sets=%d", code, f.sets)
	}
}

func beaconReport(target string, status moderation.Status) *moderation.Report {
	return &moderation.Report{TargetType: moderation.TargetBeacon, TargetID: target, TargetOwnerID: "u2", Status: status}
}

// --report on hide (Review Focus 4): the report must be a BEACON report of exactly this beacon (checked before the write),
// and a success resolves it TAKEDOWN with the note, also when the beacon was already hidden.
func TestBeacon_HideWithReport(t *testing.T) {
	t.Parallel()
	t.Run("resolves TAKEDOWN with the note", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeBeacons{exists: true}, &fakeOps{report: beaconReport(testBeaconID, moderation.StatusOpen)}
		code, out, errOut := runBeacon(f, ops, "", "beacon", "hide", testBeaconID, "--report", testListReportID, "--note", "fake meetup", "--project", "dzeroth-dev")
		if code != 0 || f.sets != 1 {
			t.Fatalf("code=%d sets=%d stderr=%q", code, f.sets, errOut)
		}
		if ops.resolved[testListReportID] != moderation.ResolutionTakedown || ops.notes[testListReportID] != "fake meetup" {
			t.Errorf("resolved=%v notes=%v", ops.resolved, ops.notes)
		}
		if !strings.Contains(out, "report="+testListReportID) {
			t.Errorf("audit line lacks the report id:\n%s", out)
		}
	})
	t.Run("already hidden still resolves", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeBeacons{exists: true, hidden: true}, &fakeOps{report: beaconReport(testBeaconID, moderation.StatusOpen)}
		code, _, _ := runBeacon(f, ops, "", "beacon", "hide", testBeaconID, "--report", testListReportID, "--project", "dzeroth-dev")
		if code != 0 || f.sets != 0 || ops.resolved[testListReportID] != moderation.ResolutionTakedown {
			t.Errorf("code=%d sets=%d resolved=%v", code, f.sets, ops.resolved)
		}
	})
	for name, rep := range map[string]*moderation.Report{
		"a LIST report":           {TargetType: moderation.TargetList, TargetID: testBeaconID, Status: moderation.StatusOpen},
		"another beacon's report": beaconReport("0000000000000000001", moderation.StatusOpen),
	} {
		t.Run("refuses "+name+" with 0 writes", func(t *testing.T) {
			t.Parallel()
			f, ops := &fakeBeacons{exists: true}, &fakeOps{report: rep}
			code, _, errOut := runBeacon(f, ops, "", "beacon", "hide", testBeaconID, "--report", testListReportID, "--project", "dzeroth-dev")
			if code != 1 || !strings.Contains(errOut, "refusing (nothing written)") || f.sets != 0 || len(ops.resolved) != 0 {
				t.Errorf("code=%d sets=%d resolved=%v stderr=%q", code, f.sets, ops.resolved, errOut)
			}
		})
	}
	t.Run("dry-run checks but resolves nothing", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeBeacons{exists: true}, &fakeOps{report: beaconReport(testBeaconID, moderation.StatusOpen)}
		code, out, _ := runBeacon(f, ops, "", "beacon", "hide", testBeaconID, "--report", testListReportID, "--dry-run", "--project", "dzeroth-dev")
		if code != 0 || f.sets != 0 || len(ops.resolved) != 0 || !strings.Contains(out, "would resolve report") {
			t.Errorf("code=%d sets=%d resolved=%v out=%q", code, f.sets, ops.resolved, out)
		}
	})
}

// `reports show` renders the BEACON evidence (R16: the organiser's handle, title, details, venue, creation time as the
// reporter saw them), the only triage surface there is; a report without evidence says so.
func TestReportsShow_BeaconEvidence(t *testing.T) {
	t.Parallel()
	ops := &fakeOps{report: &moderation.Report{
		TargetType: moderation.TargetBeacon, TargetID: testBeaconID, TargetOwnerID: "owner", Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{AuthorHandle: "mallory", PostCreatedAt: time.Date(2026, 11, 6, 10, 0, 0, 0, time.UTC),
			BeaconTitle: "Fake meetup", BeaconDetails: "bring cash", BeaconVenue: "Platform 9"},
	}}
	f := &modFixture{ops: ops, mod: &fakeModerator{}, acc: &fakeAccounts{}}
	code, out, errOut := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	for _, w := range []string{`evidence beacon by @mallory created 2026-11-06T10:00:00Z`, `title "Fake meetup"`, `details "bring cash"`, `venue "Platform 9"`} {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
	if strings.Contains(out, "evidence post") {
		t.Errorf("beacon evidence rendered as a post:\n%s", out)
	}
	ops.report.Evidence = nil
	if _, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); !strings.Contains(out, "evidence none") || strings.Contains(out, "evidence post") {
		t.Errorf("no evidence: %q", out)
	}
}

// `reports show` renders the article snapshot of a POST report on an article root after the post evidence.
func TestReportsShow_ArticleEvidence(t *testing.T) {
	t.Parallel()
	ops := &fakeOps{report: &moderation.Report{
		TargetType: moderation.TargetPost, TargetID: "1000000000000000001", TargetOwnerID: "owner", Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{AuthorHandle: "alice", Text: "Read my article", PostCreatedAt: time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC),
			ArticleID: "article-0000000000000001", ArticleTitle: "Title", ArticleRevision: 4, ArticleBody: "Body text", ArticleBodyTruncated: true},
	}}
	f := &modFixture{ops: ops, mod: &fakeModerator{}, acc: &fakeAccounts{}}
	code, out, errOut := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	for _, w := range []string{`evidence post by @alice`, `evidence article article-0000000000000001 revision 4: title "Title", body "Body text" (truncated)`} {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
	ops.report.Evidence.ArticleID = ""
	if _, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); strings.Contains(out, "evidence article") {
		t.Errorf("plain post rendered an article: %q", out)
	}
}

// fakeBeaconStats is a beacons.Stats answering fixed counts.
type fakeBeaconStats struct {
	counts beacons.Counts
	err    error
	calls  int
}

func (f *fakeBeaconStats) Counts(context.Context) (beacons.Counts, error) {
	f.calls++
	return f.counts, f.err
}

func runBeaconCounts(s *fakeBeaconStats, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{beacons: &fakeBeacons{exists: true}, beaconStats: s, reports: &fakeOps{}, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(""), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

// TestBeaconCounts_PrintsAggregatesOnly (PR 8 R44): `opsctl beacon counts` prints the five aggregate counts, one
// key=value per line in a fixed order, and nothing else (no id, title, uid or hash).
func TestBeaconCounts_PrintsAggregatesOnly(t *testing.T) {
	t.Parallel()
	s := &fakeBeaconStats{counts: beacons.Counts{Open: 3, Full: 1, Cancelled: 2, Hidden: 1, Ended: 2}}
	code, out, errOut := runBeaconCounts(s, "beacon", "counts", "--project", "dzeroth-dev")
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	want := "beacons_open=3\nbeacons_full=1\nbeacons_cancelled=2\nbeacons_hidden=1\nbeacons_ended=2\n"
	if out != want {
		t.Fatalf("output = %q, want %q", out, want)
	}
	if s.calls != 1 {
		t.Fatalf("Counts called %d times, want 1", s.calls)
	}
}

// TestBeaconCounts_StoreErrorPrintsNothing: a failing read is a failure (exit 1) with no partial counts on stdout.
func TestBeaconCounts_StoreErrorPrintsNothing(t *testing.T) {
	t.Parallel()
	s := &fakeBeaconStats{err: errors.New("firestore down")}
	code, out, errOut := runBeaconCounts(s, "beacon", "counts", "--project", "dzeroth-dev")
	if code != 1 || out != "" || !strings.Contains(errOut, "firestore down") {
		t.Fatalf("code=%d stdout=%q stderr=%q, want 1, empty stdout and the error", code, out, errOut)
	}
}

// TestBeaconCounts_Usage: counts takes --project only; an id, --dry-run, --report or --note is a usage error and
// nothing is read.
func TestBeaconCounts_Usage(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no project", []string{"beacon", "counts"}, "--project is required"},
		{"positional id", []string{"beacon", "counts", testBeaconID, "--project", "dzeroth-dev"}, "unexpected argument"},
		{"dry-run", []string{"beacon", "counts", "--dry-run", "--project", "dzeroth-dev"}, "counts is read-only"},
		{"report", []string{"beacon", "counts", "--report", testListReportID, "--project", "dzeroth-dev"}, "counts is read-only"},
		{"note", []string{"beacon", "counts", "--note", "x", "--project", "dzeroth-dev"}, "counts is read-only"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			s := &fakeBeaconStats{}
			code, _, errOut := runBeaconCounts(s, tt.args...)
			if code != 2 || !strings.Contains(errOut, tt.want) {
				t.Fatalf("code=%d stderr=%q, want 2 containing %q", code, errOut, tt.want)
			}
			if s.calls != 0 {
				t.Errorf("a usage error read the counts: calls=%d", s.calls)
			}
		})
	}
}
