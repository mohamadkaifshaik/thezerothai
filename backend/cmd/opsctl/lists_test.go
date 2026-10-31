package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const testListID = "1234567890123456789"

// fakeLists is a lists.Moderator over one in-memory list.
type fakeLists struct {
	exists bool
	hidden bool
	err    error
	sets   int
}

func (f *fakeLists) SetHidden(ctx context.Context, id string, hidden bool, _ time.Time) (bool, error) {
	budget.FromContext(ctx).AddReads(1)
	if f.err != nil {
		return false, f.err
	}
	if !f.exists {
		return false, lists.ErrNotFound
	}
	if f.hidden == hidden {
		return false, nil
	}
	f.hidden = hidden
	f.sets++
	budget.FromContext(ctx).AddWrites(1)
	return true, nil
}

func (f *fakeLists) Get(ctx context.Context, id string) (lists.List, error) {
	budget.FromContext(ctx).AddReads(1)
	if !f.exists {
		return lists.List{}, lists.ErrNotFound
	}
	return lists.List{ID: id, Name: "SECRET NAME", Hidden: f.hidden}, nil
}

func runLists(f *fakeLists, stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{lists: f, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestLists_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no sub-command", []string{"lists", "--project", "dzeroth-dev"}, "lists needs a sub-command"},
		{"unknown sub-command", []string{"lists", "purge", "--project", "dzeroth-dev"}, "lists needs a sub-command"},
		{"hide without an id", []string{"lists", "hide", "--project", "dzeroth-dev"}, "needs the list id"},
		{"restore without an id", []string{"lists", "restore", "--project", "dzeroth-dev"}, "needs the list id"},
		{"short id", []string{"lists", "hide", "123", "--project", "dzeroth-dev"}, "19 digits"},
		{"letters in the id", []string{"lists", "hide", "123456789012345678x", "--project", "dzeroth-dev"}, "19 digits"},
		{"a path in the id", []string{"lists", "hide", "lists/" + testListID, "--project", "dzeroth-dev"}, "19 digits"},
		{"two ids", []string{"lists", "hide", testListID, testListID, "--project", "dzeroth-dev"}, "unexpected argument"},
		{"no project", []string{"lists", "hide", testListID}, "--project is required"},
		{"uid is not needed or accepted as a substitute", []string{"lists", "hide", "--uid", "u1", "--project", "dzeroth-dev"}, "needs the list id"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := &fakeLists{exists: true}
			code, out, errOut := runLists(f, "", tt.args...)
			if code != 2 || !strings.Contains(errOut, tt.want) {
				t.Fatalf("code=%d stderr=%q, want 2 containing %q", code, errOut, tt.want)
			}
			if f.sets != 0 || strings.Contains(out, "cost:") {
				t.Errorf("a usage error did work: sets=%d out=%q", f.sets, out)
			}
		})
	}
}

func TestLists_HideRestoreCostAndOutput(t *testing.T) {
	t.Parallel()
	f := &fakeLists{exists: true}
	hash := logger.HashUID(testListID)
	steps := []struct {
		name string
		args []string
		want []string
		not  []string
	}{
		{"hide", []string{"lists", "hide", testListID}, []string{"hidden: list_hash=" + hash, "within 60 s", "wrote=true", "cost: reads=1 writes=1"}, nil},
		{"hide again", []string{"lists", "hide", testListID}, []string{"already hidden", "wrote=false", "cost: reads=1 writes=0"}, nil},
		{"dry-run restore writes nothing", []string{"lists", "restore", testListID, "--dry-run"}, []string{"currently hidden=true", "would write", "cost: reads=1 writes=0"}, []string{"audit:"}},
		{"restore", []string{"lists", "restore", testListID}, []string{"restored: list_hash=" + hash, "wrote=true", "cost: reads=1 writes=1"}, nil},
		{"restore again", []string{"lists", "restore", testListID}, []string{"not hidden", "wrote=false", "cost: reads=1 writes=0"}, nil},
	}
	for _, s := range steps {
		code, out, errOut := runLists(f, "", append(s.args, "--project", "dzeroth-dev")...)
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
		// Only hashed ids, and never the list's text.
		if strings.Contains(out, testListID) || strings.Contains(out, "SECRET NAME") {
			t.Errorf("%s: output carries the plain list id or the name:\n%s", s.name, out)
		}
	}
	if f.sets != 2 {
		t.Errorf("writes = %d, want 2 (hide, restore)", f.sets)
	}
}

func TestLists_MissingListIsRefused(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{{"lists", "hide", testListID}, {"lists", "restore", testListID}, {"lists", "hide", testListID, "--dry-run"}} {
		f := &fakeLists{}
		code, out, errOut := runLists(f, "", append(args, "--project", "dzeroth-dev")...)
		if code != 1 || !strings.Contains(errOut, "no such list") || strings.Contains(out, "audit:") || !strings.Contains(out, "writes=0") {
			t.Errorf("%v: code=%d stdout=%q stderr=%q", args, code, out, errOut)
		}
	}
}

func TestLists_StoreErrorIsAFailureNotAUsageError(t *testing.T) {
	t.Parallel()
	f := &fakeLists{exists: true, err: errors.New("deadline")}
	if code, _, errOut := runLists(f, "", "lists", "hide", testListID, "--project", "dzeroth-dev"); code != 1 || !strings.Contains(errOut, "deadline") {
		t.Errorf("code=%d stderr=%q", code, errOut)
	}
}

// A production project asks for the typed confirmation before anything is opened; a wrong answer aborts with 0 work.
func TestLists_ProdNeedsTypedConfirmation(t *testing.T) {
	t.Parallel()
	f := &fakeLists{exists: true}
	if code, _, _ := runLists(f, "nope\n", "lists", "hide", testListID, "--project", "dzeroth-prod"); code != 1 || f.sets != 0 {
		t.Errorf("wrong confirmation: code=%d sets=%d", code, f.sets)
	}
	if code, _, _ := runLists(f, "dzeroth-prod\n", "lists", "hide", testListID, "--project", "dzeroth-prod"); code != 0 || f.sets != 1 {
		t.Errorf("right confirmation: code=%d sets=%d", code, f.sets)
	}
}

const testListReportID = "0123456789abcdef0123456789abcdef"

func runListsWithReports(f *fakeLists, ops *fakeOps, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{lists: f, reports: ops, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), append(args, "--project", "dzeroth-dev"), strings.NewReader(""), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func listReport(target string, status moderation.Status) *moderation.Report {
	return &moderation.Report{TargetType: moderation.TargetList, TargetID: target, TargetOwnerID: "u2", Status: status}
}

// --report on hide: the report must be a LIST report of exactly this list (checked before the write), and a success resolves
// it TAKEDOWN with the note, also when the list was already hidden.
func TestLists_HideWithReport(t *testing.T) {
	t.Parallel()
	t.Run("resolves TAKEDOWN with the note", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeLists{exists: true}, &fakeOps{report: listReport(testListID, moderation.StatusOpen)}
		code, out, errOut := runListsWithReports(f, ops, "lists", "hide", testListID, "--report", testListReportID, "--note", "slur in the name")
		if code != 0 || f.sets != 1 {
			t.Fatalf("code=%d sets=%d stderr=%q", code, f.sets, errOut)
		}
		if ops.resolved[testListReportID] != moderation.ResolutionTakedown || ops.notes[testListReportID] != "slur in the name" {
			t.Errorf("resolved=%v notes=%v", ops.resolved, ops.notes)
		}
		if !strings.Contains(out, "report="+testListReportID) {
			t.Errorf("audit line lacks the report id:\n%s", out)
		}
	})
	t.Run("already hidden still resolves", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeLists{exists: true, hidden: true}, &fakeOps{report: listReport(testListID, moderation.StatusOpen)}
		code, _, _ := runListsWithReports(f, ops, "lists", "hide", testListID, "--report", testListReportID)
		if code != 0 || f.sets != 0 || ops.resolved[testListReportID] != moderation.ResolutionTakedown {
			t.Errorf("code=%d sets=%d resolved=%v", code, f.sets, ops.resolved)
		}
	})
	for name, rep := range map[string]*moderation.Report{
		"a POST report":           {TargetType: moderation.TargetPost, TargetID: testListID, Status: moderation.StatusOpen},
		"another list's report":   listReport("0000000000000000001", moderation.StatusOpen),
		"an account report on id": {TargetType: moderation.TargetAccount, TargetID: testListID, Status: moderation.StatusOpen},
	} {
		t.Run("refuses "+name+" with 0 writes", func(t *testing.T) {
			t.Parallel()
			f, ops := &fakeLists{exists: true}, &fakeOps{report: rep}
			code, _, errOut := runListsWithReports(f, ops, "lists", "hide", testListID, "--report", testListReportID)
			if code != 1 || !strings.Contains(errOut, "refusing (nothing written)") || f.sets != 0 || len(ops.resolved) != 0 {
				t.Errorf("code=%d sets=%d resolved=%v stderr=%q", code, f.sets, ops.resolved, errOut)
			}
		})
	}
	t.Run("dry-run checks but resolves nothing", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeLists{exists: true}, &fakeOps{report: listReport(testListID, moderation.StatusOpen)}
		code, out, _ := runListsWithReports(f, ops, "lists", "hide", testListID, "--report", testListReportID, "--dry-run")
		if code != 0 || f.sets != 0 || len(ops.resolved) != 0 || !strings.Contains(out, "would resolve report") {
			t.Errorf("code=%d sets=%d resolved=%v out=%q", code, f.sets, ops.resolved, out)
		}
	})
	t.Run("dry-run with a wrong report is still refused", func(t *testing.T) {
		t.Parallel()
		f, ops := &fakeLists{exists: true}, &fakeOps{report: listReport("0000000000000000001", moderation.StatusOpen)}
		if code, _, _ := runListsWithReports(f, ops, "lists", "hide", testListID, "--report", testListReportID, "--dry-run"); code != 1 {
			t.Errorf("code=%d, want 1", code)
		}
	})
}

func TestLists_ReportFlagValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"restore takes no report", []string{"lists", "restore", testListID, "--report", testListReportID}, "lists hide only"},
		{"bad report id", []string{"lists", "hide", testListID, "--report", "xyz"}, "32-character report id"},
		{"note needs a report", []string{"lists", "hide", testListID, "--note", "x"}, "needs --report"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f, ops := &fakeLists{exists: true}, &fakeOps{}
			code, _, errOut := runListsWithReports(f, ops, tt.args...)
			if code != 2 || !strings.Contains(errOut, tt.want) || f.sets != 0 {
				t.Errorf("code=%d stderr=%q", code, errOut)
			}
		})
	}
}
