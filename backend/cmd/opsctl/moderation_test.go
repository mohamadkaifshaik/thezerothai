package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

const (
	testPostID   = "0000000000000000042"
	testReportID = "0123456789abcdef0123456789abcdef"
)

type fakeOps struct {
	list     []moderation.Report
	listSt   moderation.Status
	resolved map[string]moderation.Resolution
	getErr   error
}

func (f *fakeOps) List(_ context.Context, st moderation.Status, _ int) ([]moderation.Report, error) {
	f.listSt = st
	return f.list, nil
}

func (f *fakeOps) Get(_ context.Context, id string) (moderation.Report, error) {
	if f.getErr != nil {
		return moderation.Report{}, f.getErr
	}
	return moderation.Report{ID: id, ReporterID: "", TargetType: moderation.TargetPost, TargetID: testPostID,
		Reason: moderation.ReasonSpam, Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{Text: "evidence", AuthorHandle: "bob"}}, nil
}

func (f *fakeOps) Resolve(_ context.Context, id string, res moderation.Resolution, _ string, now time.Time) (moderation.Report, error) {
	if f.resolved == nil {
		f.resolved = map[string]moderation.Resolution{}
	}
	f.resolved[id] = res
	return moderation.Report{ID: id, Status: moderation.StatusResolved, Resolution: res, ExpireAt: now.Add(moderation.Retention)}, nil
}

type fakeModerator struct {
	takedowns, restores []string
	hideCalls, restCall int
	err                 error
}

func (f *fakeModerator) Takedown(_ context.Context, id string, _ time.Time) (posts.ModerationResult, error) {
	f.takedowns = append(f.takedowns, id)
	return posts.ModerationResult{AuthorID: "u2", Before: posts.ModerationNone, After: posts.ModerationTakenDown}, f.err
}

func (f *fakeModerator) Restore(_ context.Context, id string) (posts.ModerationResult, error) {
	f.restores = append(f.restores, id)
	return posts.ModerationResult{AuthorID: "u2", Before: posts.ModerationSuspendedAuthor, After: posts.ModerationSuspendedAuthor}, f.err
}

func (f *fakeModerator) HideAuthor(_ context.Context, _ string, cp posts.ModerationCheckpoint, _ time.Time) (posts.ModerationCheckpoint, bool, error) {
	f.hideCalls++
	if f.hideCalls%2 == 1 {
		return posts.ModerationCheckpoint{Changed: cp.Changed + 500}, false, nil
	}
	return posts.ModerationCheckpoint{Changed: cp.Changed + 3}, true, nil
}

func (f *fakeModerator) RestoreAuthor(_ context.Context, _ string, cp posts.ModerationCheckpoint) (posts.ModerationCheckpoint, bool, error) {
	f.restCall++
	return posts.ModerationCheckpoint{Changed: cp.Changed + 2}, true, nil
}

type fakeAccounts struct {
	calls []string
	err   error
	same  bool
}

func (f *fakeAccounts) SetAccountStatus(_ context.Context, uid string, from, to identity.AccountStatus, _ time.Time) (bool, error) {
	f.calls = append(f.calls, uid+":"+statusName(from)+">"+statusName(to))
	return !f.same, f.err
}

type modFixture struct {
	ops *fakeOps
	mod *fakeModerator
	acc *fakeAccounts
}

func newModFixture() *modFixture {
	return &modFixture{ops: &fakeOps{}, mod: &fakeModerator{}, acc: &fakeAccounts{}}
}

func (m *modFixture) run(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{
			reports: m.ops, moderator: m.mod, accounts: m.acc,
			postsPlanner: fakePostsPlanner{posts.PurgePlan{Posts: 7}},
			profile: func(context.Context, string) (identity.Profile, error) {
				return identity.Profile{Status: identity.AccountStatusActive}, nil
			},
			close: func() {},
		}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestModeration_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"reports without sub-command", []string{"reports", "--project", "dzeroth-dev"}, "needs a sub-command"},
		{"reports show bad id", []string{"reports", "show", "--project", "dzeroth-dev", "--id", "../x"}, "32-character report id"},
		{"reports resolve bad resolution", []string{"reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "BAN"}, "--resolution must be"},
		{"reports list bad status", []string{"reports", "list", "--project", "dzeroth-dev", "--status", "OLD"}, "OPEN or RESOLVED"},
		{"takedown bad post", []string{"takedown-post", "--project", "dzeroth-dev", "--post", "a/b"}, "19-digit post id"},
		{"takedown bad report", []string{"takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", "zz"}, "32-character report id"},
		{"suspend without uid", []string{"suspend-user", "--project", "dzeroth-dev"}, "--uid is required"},
		{"takedown without project", []string{"takedown-post", "--post", testPostID}, "--project is required"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newModFixture()
			code, _, stderr := f.run("", tt.args...)
			if code == 0 || !strings.Contains(stderr, tt.want) {
				t.Fatalf("code=%d stderr=%q, want it to contain %q", code, stderr, tt.want)
			}
			if len(f.mod.takedowns)+len(f.acc.calls) != 0 {
				t.Error("a rejected command must not write")
			}
		})
	}
}

func TestReports_ListShowResolve(t *testing.T) {
	t.Parallel()
	f := newModFixture()
	f.ops.list = []moderation.Report{{ID: testReportID, TargetType: moderation.TargetPost, TargetID: testPostID, Reason: moderation.ReasonHate, CreatedAt: time.Unix(5, 0).UTC()}}
	code, out, stderr := f.run("", "reports", "list", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "1 OPEN report(s)") || !strings.Contains(out, testReportID) || f.ops.listSt != moderation.StatusOpen {
		t.Fatalf("list: code=%d out=%q err=%q st=%q", code, out, stderr, f.ops.listSt)
	}
	code, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 || !strings.Contains(out, "reporter - (reporter deleted)") || !strings.Contains(out, "evidence post by @bob") {
		t.Fatalf("show: code=%d out=%q", code, out)
	}
	code, out, _ = f.run("", "reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "dismissed")
	if code != 0 || f.ops.resolved[testReportID] != moderation.ResolutionDismissed || !strings.Contains(out, "RESOLVED") {
		t.Fatalf("resolve: code=%d out=%q resolved=%v", code, out, f.ops.resolved)
	}
	f.ops.getErr = moderation.ErrNotFound
	if code, _, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); code != 1 {
		t.Errorf("show missing: code=%d, want 1", code)
	}
}

func TestTakedownRestore(t *testing.T) {
	t.Parallel()
	f := newModFixture()
	code, out, stderr := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if len(f.mod.takedowns) != 1 || f.ops.resolved[testReportID] != moderation.ResolutionTakedown {
		t.Errorf("takedowns=%v resolved=%v", f.mod.takedowns, f.ops.resolved)
	}
	if !strings.Contains(out, "VISIBLE -> TAKEN_DOWN") {
		t.Errorf("out=%q", out)
	}
	code, out, _ = f.run("", "restore-post", "--project", "dzeroth-dev", "--post", testPostID)
	if code != 0 || !strings.Contains(out, "unsuspend-user restores it") {
		t.Errorf("restore: code=%d out=%q", code, out)
	}
	f.mod.err = posts.ErrNotFound
	if code, _, _ = f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID); code != 1 {
		t.Errorf("unknown post: code=%d, want 1", code)
	}
}

func TestSuspendUnsuspend(t *testing.T) {
	t.Parallel()
	t.Run("dry run writes nothing", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
		if code != 0 || !strings.Contains(out, "nothing written") || len(f.acc.calls) != 0 || f.mod.hideCalls != 0 {
			t.Fatalf("code=%d out=%q acc=%v hide=%d", code, out, f.acc.calls, f.mod.hideCalls)
		}
	})
	t.Run("suspend sets status first then hides all pages and resolves the report", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--report", testReportID)
		if code != 0 {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if len(f.acc.calls) != 1 || f.acc.calls[0] != "u2:ACTIVE>SUSPENDED" || f.mod.hideCalls != 2 {
			t.Errorf("acc=%v hideCalls=%d", f.acc.calls, f.mod.hideCalls)
		}
		if f.ops.resolved[testReportID] != moderation.ResolutionSuspended || !strings.Contains(out, "hidden=503") {
			t.Errorf("resolved=%v out=%q", f.ops.resolved, out)
		}
	})
	t.Run("already suspended still finishes the posts", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.acc.same = true
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || !strings.Contains(out, "already SUSPENDED") || f.mod.hideCalls != 2 {
			t.Fatalf("code=%d out=%q hide=%d", code, out, f.mod.hideCalls)
		}
	})
	t.Run("a deleting account is refused before any post is touched", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.acc.err = identity.ErrStatusConflict
		code, _, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 1 || !strings.Contains(stderr, "refusing") || f.mod.hideCalls != 0 {
			t.Fatalf("code=%d stderr=%q hide=%d", code, stderr, f.mod.hideCalls)
		}
	})
	t.Run("unknown user", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.acc.err = identity.ErrNotFound
		code, _, stderr := f.run("", "unsuspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 1 || !strings.Contains(stderr, "no such user") {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
	})
	t.Run("unsuspend restores", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "unsuspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || f.acc.calls[0] != "u2:SUSPENDED>ACTIVE" || f.mod.restCall != 1 || !strings.Contains(out, "restored=2") {
			t.Fatalf("code=%d out=%q acc=%v", code, out, f.acc.calls)
		}
	})
	t.Run("prod needs the typed confirmation", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, _, stderr := f.run("wrong\n", "suspend-user", "--project", "dzeroth-prod", "--uid", "u2")
		if code != 1 || !strings.Contains(stderr, "aborted") || len(f.acc.calls) != 0 {
			t.Fatalf("code=%d stderr=%q acc=%v", code, stderr, f.acc.calls)
		}
		code, _, _ = f.run("dzeroth-prod\n", "suspend-user", "--project", "dzeroth-prod", "--uid", "u2")
		if code != 0 || len(f.acc.calls) != 1 {
			t.Fatalf("confirmed: code=%d acc=%v", code, f.acc.calls)
		}
	})
}
