package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

type fakeEraser struct {
	calls   []graph.Checkpoint
	steps   []graph.Checkpoint // checkpoints returned in order; the call after the last returns done
	failFor int                // number of leading calls that fail
	failAll bool
}

func (f *fakeEraser) PurgeUser(_ context.Context, _ string, cp graph.Checkpoint) (graph.Checkpoint, bool, error) {
	f.calls = append(f.calls, cp)
	if f.failAll || len(f.calls) <= f.failFor {
		return graph.Checkpoint{}, false, errors.New("transient")
	}
	i := len(f.calls) - 1 - f.failFor
	if i >= len(f.steps) {
		return graph.Checkpoint{}, true, nil
	}
	return f.steps[i], false, nil
}

// fakePostsEraser returns the scripted checkpoints; the call after the last one is done. failFor leading calls fail.
type fakePostsEraser struct {
	calls   []posts.Checkpoint
	steps   []posts.Checkpoint
	failFor int
}

func (f *fakePostsEraser) PurgeUser(_ context.Context, _ string, cp posts.Checkpoint) (posts.Checkpoint, bool, error) {
	f.calls = append(f.calls, cp)
	if len(f.calls) <= f.failFor {
		return posts.Checkpoint{}, false, errors.New("transient")
	}
	i := len(f.calls) - 1 - f.failFor
	if i >= len(f.steps) {
		return cp, true, nil
	}
	return f.steps[i], false, nil
}

type fakeBackend struct {
	pEraser *fakePostsEraser
	pPlan   posts.PurgePlan
	pExport string
	eraser  *fakeEraser
	plan    graph.PurgePlan
	export  graph.Export
	prof    identity.Profile
	profEr  error
	opened  int
}

func (f *fakeBackend) open(context.Context, string) (*backends, error) {
	f.opened++
	return &backends{
		eraser:        f.eraser,
		planner:       f,
		exporter:      f,
		postsEraser:   f.pEraser,
		postsPlanner:  fakePostsPlanner{f.pPlan},
		postsExporter: fakePostsExporter{f.pExport},
		profile:       func(context.Context, string) (identity.Profile, error) { return f.prof, f.profEr },
		close:         func() {},
	}, nil
}

func (f *fakeBackend) PlanPurge(context.Context, string) (graph.PurgePlan, error) { return f.plan, nil }

type fakePostsPlanner struct{ plan posts.PurgePlan }

func (f fakePostsPlanner) PlanPurge(context.Context, string) (posts.PurgePlan, error) {
	return f.plan, nil
}

type fakePostsExporter struct{ body string }

func (f fakePostsExporter) ExportUser(_ context.Context, _ string, w io.Writer) error {
	_, err := io.WriteString(w, f.body)
	return err
}

func (f *fakeBackend) ExportUser(context.Context, string) (graph.Export, error) {
	return f.export, nil
}

func do(t *testing.T, fb *fakeBackend, stdin string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errOut bytes.Buffer
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, fb.open, now)
	return code, out.String(), errOut.String()
}

func TestRun_UsageErrors(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no command", nil, "usage"},
		{"unknown command", []string{"nuke"}, "unknown command"},
		{"purge without project", []string{"purge-graph", "--uid", "u1"}, "--project is required"},
		{"export without project", []string{"export-graph", "--uid", "u1"}, "--project is required"},
		{"missing uid", []string{"purge-graph", "--project", "dzeroth-dev"}, "--uid is required"},
		{"bad uid", []string{"purge-graph", "--project", "dzeroth-dev", "--uid", "bad id!"}, "not a valid user id"},
		{"bad flag", []string{"purge-graph", "--nope"}, "flag provided but not defined"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fb := &fakeBackend{eraser: &fakeEraser{}}
			code, _, stderr := do(t, fb, "", tt.args...)
			if code == 0 {
				t.Fatal("exit code 0, want non-zero")
			}
			if !strings.Contains(stderr, tt.want) {
				t.Errorf("stderr = %q, want it to contain %q", stderr, tt.want)
			}
			if fb.opened != 0 {
				t.Error("backends must not be opened for a usage error")
			}
		})
	}
}

func TestPurge_DryRunWritesNothing(t *testing.T) {
	fb := &fakeBackend{eraser: &fakeEraser{}, plan: graph.PurgePlan{OutgoingEdges: 3, IncomingEdges: 2, Blocked: 1, BlockedBy: 1}}
	code, stdout, _ := do(t, fb, "", "purge-graph", "--project", "dzeroth-dev", "--uid", "u1", "--dry-run")
	if code != 0 || !strings.Contains(stdout, "outgoing_edges=3 incoming_edges=2 blocked=1 blocked_by=1") {
		t.Fatalf("code=%d stdout=%q", code, stdout)
	}
	if len(fb.eraser.calls) != 0 {
		t.Error("dry-run must not call PurgeUser")
	}
}

func TestPurge_StartGate(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	tests := []struct {
		name      string
		prof      identity.Profile
		profErr   error
		args      []string
		wantCode  int
		wantCalls bool
		wantErr   string
	}{
		{"deleting long enough", identity.Profile{Status: identity.AccountStatusDeleting, UpdatedAt: now.Add(-3 * time.Minute)}, nil, nil, 0, true, ""},
		{"deleting too recently", identity.Profile{Status: identity.AccountStatusDeleting, UpdatedAt: now.Add(-30 * time.Second)}, nil, nil, 1, false, "wait another"},
		{"still active", identity.Profile{Status: identity.AccountStatusActive}, nil, nil, 1, false, "not in status DELETING"},
		{"profile unreadable", identity.Profile{}, errors.New("nope"), nil, 1, false, "cannot read the profile"},
		{"gate skipped", identity.Profile{Status: identity.AccountStatusActive}, nil, []string{"--skip-start-gate"}, 0, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fb := &fakeBackend{eraser: &fakeEraser{}, prof: tt.prof, profEr: tt.profErr}
			args := append([]string{"purge-graph", "--project", "dzeroth-dev", "--uid", "u1"}, tt.args...)
			code, _, stderr := do(t, fb, "", args...)
			if code != tt.wantCode {
				t.Fatalf("code = %d (stderr %q), want %d", code, stderr, tt.wantCode)
			}
			if !strings.Contains(stderr, tt.wantErr) {
				t.Errorf("stderr = %q, want %q", stderr, tt.wantErr)
			}
			if (len(fb.eraser.calls) > 0) != tt.wantCalls {
				t.Errorf("PurgeUser calls = %d, wantCalls = %v", len(fb.eraser.calls), tt.wantCalls)
			}
		})
	}
}

func TestPurge_ResumesFromReturnedCheckpointsAndRetries(t *testing.T) {
	er := &fakeEraser{failFor: 1, steps: []graph.Checkpoint{{Step: 2}, {Step: 3, Offset: 500}}}
	fb := &fakeBackend{eraser: er}
	code, stdout, stderr := do(t, fb, "", "purge-graph", "--project", "dzeroth-dev", "--uid", "u1", "--skip-start-gate")
	if code != 0 {
		t.Fatalf("code = %d stderr=%q", code, stderr)
	}
	want := []graph.Checkpoint{{}, {}, {Step: 2}, {Step: 3, Offset: 500}}
	if len(er.calls) != len(want) {
		t.Fatalf("calls = %+v, want %+v", er.calls, want)
	}
	for i := range want {
		if er.calls[i] != want[i] {
			t.Errorf("call %d checkpoint = %+v, want %+v", i, er.calls[i], want[i])
		}
	}
	if !strings.Contains(stdout, "purged: reads=") {
		t.Errorf("stdout = %q, want the ops summary", stdout)
	}
}

func TestPurge_GivesUpAfterRepeatedErrors(t *testing.T) {
	fb := &fakeBackend{eraser: &fakeEraser{failAll: true}}
	code, _, stderr := do(t, fb, "", "purge-graph", "--project", "dzeroth-dev", "--uid", "u1", "--skip-start-gate")
	if code != 1 || !strings.Contains(stderr, "giving up") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if len(fb.eraser.calls) != maxConsecutiveErrors {
		t.Errorf("calls = %d, want %d", len(fb.eraser.calls), maxConsecutiveErrors)
	}
}

func TestProdConfirmation(t *testing.T) {
	tests := []struct {
		name     string
		stdin    string
		wantCode int
	}{
		{"typed project id", "dzeroth-prod\n", 0},
		{"wrong text", "yes\n", 1},
		{"eof", "", 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fb := &fakeBackend{eraser: &fakeEraser{}}
			code, _, _ := do(t, fb, tt.stdin, "purge-graph", "--project", "dzeroth-prod", "--uid", "u1", "--dry-run")
			if code != tt.wantCode {
				t.Errorf("code = %d, want %d", code, tt.wantCode)
			}
			if tt.wantCode != 0 && fb.opened != 0 {
				t.Error("must not open backends before confirmation")
			}
		})
	}
	// Non-prod never prompts.
	fb := &fakeBackend{eraser: &fakeEraser{}}
	if code, _, _ := do(t, fb, "", "export-graph", "--project", "dzeroth-dev", "--uid", "u1"); code != 0 {
		t.Errorf("dev export code = %d, want 0 without a prompt", code)
	}
}

func TestExport_NeverContainsBlockedBy(t *testing.T) {
	fb := &fakeBackend{eraser: &fakeEraser{}, export: graph.Export{
		UserID:    "u1",
		Following: []graph.ExportUser{{UserID: "f1", Handle: "fone"}},
		Followers: []graph.ExportUser{{UserID: "g1", Handle: "gone"}},
		Blocked:   []graph.ExportUser{{UserID: "b1", Handle: "bone"}},
		Muted:     []graph.ExportUser{{UserID: "m1"}},
	}}
	code, stdout, stderr := do(t, fb, "", "export-graph", "--project", "dzeroth-dev", "--uid", "u1")
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(stdout), &m); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, stdout)
	}
	for k := range m {
		if strings.Contains(strings.ToLower(k), "blockedby") {
			t.Errorf("export has key %q", k)
		}
	}
	for _, k := range []string{"following", "followers", "blocked", "muted"} {
		if _, ok := m[k]; !ok {
			t.Errorf("export is missing %q", k)
		}
	}
}

func TestExport_OutFile(t *testing.T) {
	fb := &fakeBackend{eraser: &fakeEraser{}, export: graph.Export{UserID: "u1"}}
	path := filepath.Join(t.TempDir(), "export.json")
	if code, _, stderr := do(t, fb, "", "export-graph", "--project", "dzeroth-dev", "--uid", "u1", "--out", path); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	data, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(data), "\"userId\": \"u1\"") {
		t.Fatalf("file = %q, %v", data, err)
	}
	// Refuses to overwrite an existing export.
	if code, _, _ := do(t, fb, "", "export-graph", "--project", "dzeroth-dev", "--uid", "u1", "--out", path); code != 1 {
		t.Errorf("second export code = %d, want 1 (no overwrite)", code)
	}
}

// ---- purge-posts / export-posts (ADR-0010 T10) ----

func TestPurgePosts_DryRunWritesNothing(t *testing.T) {
	fb := &fakeBackend{pEraser: &fakePostsEraser{}, pPlan: posts.PurgePlan{Posts: 1203}}
	code, stdout, stderr := do(t, fb, "", "purge-posts", "--project", "dzeroth-dev", "--uid", "u1", "--dry-run")
	if code != 0 || !strings.Contains(stdout, "dry-run: posts=1203 (nothing written)") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if len(fb.pEraser.calls) != 0 {
		t.Fatalf("a dry run called the eraser %d times", len(fb.pEraser.calls))
	}
}

func TestPurgePosts_ResumesFromCheckpointsAndRetries(t *testing.T) {
	er := &fakePostsEraser{failFor: 1, steps: []posts.Checkpoint{{Deleted: 500}, {Deleted: 1000}}}
	fb := &fakeBackend{pEraser: er}
	code, stdout, stderr := do(t, fb, "", "purge-posts", "--project", "dzeroth-dev", "--uid", "u1", "--skip-start-gate")
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	want := []posts.Checkpoint{{}, {}, {Deleted: 500}, {Deleted: 1000}}
	if len(er.calls) != len(want) {
		t.Fatalf("calls = %+v, want %+v", er.calls, want)
	}
	for i := range want {
		if er.calls[i] != want[i] {
			t.Errorf("call %d checkpoint = %+v, want %+v", i, er.calls[i], want[i])
		}
	}
	if !strings.Contains(stdout, "purged: reads=") || !strings.Contains(stdout, "deleted=500") {
		t.Errorf("stdout = %q", stdout)
	}
}

func TestPurgePosts_GivesUpAndStartGate(t *testing.T) {
	// Always failing eraser: gives up after maxConsecutiveErrors.
	fb := &fakeBackend{pEraser: &fakePostsEraser{failFor: 1 << 20}}
	code, _, stderr := do(t, fb, "", "purge-posts", "--project", "dzeroth-dev", "--uid", "u1", "--skip-start-gate")
	if code != 1 || !strings.Contains(stderr, "giving up") || len(fb.pEraser.calls) != maxConsecutiveErrors {
		t.Fatalf("code=%d stderr=%q calls=%d", code, stderr, len(fb.pEraser.calls))
	}
	// The start gate applies like purge-graph: an ACTIVE account is refused before any call.
	fb = &fakeBackend{pEraser: &fakePostsEraser{}, prof: identity.Profile{Status: identity.AccountStatusActive}}
	code, _, stderr = do(t, fb, "", "purge-posts", "--project", "dzeroth-dev", "--uid", "u1")
	if code != 1 || !strings.Contains(stderr, "not in status DELETING") || len(fb.pEraser.calls) != 0 {
		t.Fatalf("code=%d stderr=%q calls=%d", code, stderr, len(fb.pEraser.calls))
	}
}

func TestPostsCommands_RequireProjectAndUID(t *testing.T) {
	for _, cmd := range []string{"purge-posts", "export-posts"} {
		fb := &fakeBackend{pEraser: &fakePostsEraser{}}
		if code, _, stderr := do(t, fb, "", cmd, "--uid", "u1"); code != 2 || !strings.Contains(stderr, "--project is required") || fb.opened != 0 {
			t.Errorf("%s without --project: code=%d stderr=%q opened=%d", cmd, code, stderr, fb.opened)
		}
		if code, _, stderr := do(t, fb, "", cmd, "--project", "dzeroth-dev"); code != 2 || !strings.Contains(stderr, "--uid is required") {
			t.Errorf("%s without --uid: code=%d stderr=%q", cmd, code, stderr)
		}
		if code, _, _ := do(t, fb, "", cmd, "--project", "dzeroth-prod", "--uid", "u1", "--dry-run"); code != 1 || fb.opened != 0 {
			t.Errorf("%s on prod without confirmation: code=%d opened=%d", cmd, code, fb.opened)
		}
	}
}

func TestExportPosts_StdoutAndOutFile(t *testing.T) {
	body := `{"userId":"u1","posts":[]}` + "\n"
	fb := &fakeBackend{pEraser: &fakePostsEraser{}, pExport: body}
	code, stdout, stderr := do(t, fb, "", "export-posts", "--project", "dzeroth-dev", "--uid", "u1")
	if code != 0 || stdout != body {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	path := filepath.Join(t.TempDir(), "posts.json")
	if code, _, stderr := do(t, fb, "", "export-posts", "--project", "dzeroth-dev", "--uid", "u1", "--out", path); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != body {
		t.Fatalf("file = %q, %v", data, err)
	}
	if code, _, _ := do(t, fb, "", "export-posts", "--project", "dzeroth-dev", "--uid", "u1", "--out", path); code != 1 {
		t.Errorf("second export code = %d, want 1 (no overwrite)", code)
	}
}

// TestWriteOut_RemovesPartialFileOnFailure: a mid-stream failure must not leave a truncated export that looks
// complete; a pre-existing file is never touched (O_EXCL refuses before write runs).
func TestWriteOut_RemovesPartialFileOnFailure(t *testing.T) {
	boom := errors.New("stream broke")
	path := filepath.Join(t.TempDir(), "posts.json")
	err := writeOut(path, io.Discard, func(w io.Writer) error {
		_, _ = io.WriteString(w, `{"userId":"u1","posts":[`)
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("err = %v, want the write error", err)
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("partial file still exists (stat err = %v)", statErr)
	}

	if err := os.WriteFile(path, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	called := false
	if err := writeOut(path, io.Discard, func(io.Writer) error { called = true; return nil }); err == nil || called {
		t.Fatalf("existing file: err=%v called=%v, want refusal before writing", err, called)
	}
	if data, _ := os.ReadFile(path); string(data) != "keep" {
		t.Fatalf("existing file was modified: %q", data)
	}
}
