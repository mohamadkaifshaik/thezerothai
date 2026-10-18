package main

import (
	"bytes"
	"cmp"
	"context"
	"strconv"
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
	// report, when set, is what Get returns (default: an OPEN report of testPostID owned by "u2").
	report *moderation.Report
}

func (f *fakeOps) List(_ context.Context, st moderation.Status, _ int) ([]moderation.Report, error) {
	f.listSt = st
	return f.list, nil
}

func (f *fakeOps) Get(_ context.Context, id string) (moderation.Report, error) {
	if f.getErr != nil {
		return moderation.Report{}, f.getErr
	}
	if f.report != nil {
		r := *f.report
		r.ID = id
		return r, nil
	}
	return moderation.Report{ID: id, ReporterID: "", TargetType: moderation.TargetPost, TargetID: testPostID,
		TargetOwnerID: "u2", Reason: moderation.ReasonSpam, Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{Text: "evidence", AuthorHandle: "bob", MediaIDs: []string{"m1", "m2"}}}, nil
}

func (f *fakeOps) Resolve(_ context.Context, id string, res moderation.Resolution, _ string, now time.Time) (moderation.Report, error) {
	if f.resolved == nil {
		f.resolved = map[string]moderation.Resolution{}
	}
	f.resolved[id] = res
	return moderation.Report{ID: id, Status: moderation.StatusResolved, Resolution: res, ExpireAt: now.Add(moderation.Retention)}, nil
}

// fakePost is one post of the fake author: hidden mirrors posts.moderation != "".
type fakePost struct {
	id        int
	createdAt time.Time
	hidden    bool
}

// fakeModerator models the author's posts (newest first). HideAuthor pages fakePage posts per call, honours
// cp.Since like the Firestore implementation, and records every post it paged (reads).
type fakeModerator struct {
	takedowns, restores []string
	hideCalls, restCall int
	err                 error
	posts               []*fakePost
	paged               int
	// afterFirstHide runs once, right after the first HideAuthor call returns (a post created on an instance that
	// still cached the account as ACTIVE, after page 1 was read).
	afterFirstHide func()
}

const fakePage = 2

func (f *fakeModerator) Takedown(_ context.Context, id string, _ time.Time) (posts.ModerationResult, error) {
	f.takedowns = append(f.takedowns, id)
	return posts.ModerationResult{AuthorID: "u2", Before: posts.ModerationNone, After: posts.ModerationTakenDown}, f.err
}

func (f *fakeModerator) Restore(_ context.Context, id string, _ time.Time) (posts.ModerationResult, error) {
	f.restores = append(f.restores, id)
	return posts.ModerationResult{AuthorID: "u2", Before: posts.ModerationSuspendedAuthor, After: posts.ModerationSuspendedAuthor}, f.err
}

func (f *fakeModerator) HideAuthor(_ context.Context, _ string, cp posts.ModerationCheckpoint, _ time.Time) (posts.ModerationCheckpoint, bool, error) {
	f.hideCalls++
	var eligible []*fakePost
	for _, p := range f.posts {
		if cp.Since.IsZero() || !p.createdAt.Before(cp.Since) {
			eligible = append(eligible, p)
		}
	}
	start := 0
	if cp.After != nil {
		last, _ := strconv.Atoi(cp.After.ID)
		for i, p := range eligible {
			if p.id == last {
				start = i + 1
			}
		}
	}
	end := min(start+fakePage, len(eligible))
	next := posts.ModerationCheckpoint{Changed: cp.Changed, Since: cp.Since}
	for _, p := range eligible[start:end] {
		f.paged++
		if !p.hidden {
			p.hidden = true
			next.Changed++
		}
	}
	if end > start {
		next.After = &posts.Position{ID: strconv.Itoa(eligible[end-1].id)}
	} else {
		next.After = cp.After
	}
	if f.hideCalls == 1 && f.afterFirstHide != nil {
		f.afterFirstHide()
	}
	return next, end >= len(eligible), nil
}

func (f *fakeModerator) RestoreAuthor(_ context.Context, _ string, cp posts.ModerationCheckpoint, _ time.Time) (posts.ModerationCheckpoint, bool, error) {
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
	// slept records the settle waits; onSleep runs while "waiting" (a post created in the cache window).
	slept   []time.Duration
	onSleep func()
	// plannedPosts is what the dry-run plan reports; 0 means 7.
	plannedPosts int64
}

func newModFixture() *modFixture {
	return &modFixture{ops: &fakeOps{}, mod: &fakeModerator{}, acc: &fakeAccounts{}}
}

func (m *modFixture) run(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{
			reports: m.ops, moderator: m.mod, accounts: m.acc,
			postsPlanner: fakePostsPlanner{posts.PurgePlan{Posts: cmp.Or(m.plannedPosts, 7)}},
			profile: func(context.Context, string) (identity.Profile, error) {
				return identity.Profile{Status: identity.AccountStatusActive}, nil
			},
			sleep: func(_ context.Context, d time.Duration) error {
				m.slept = append(m.slept, d)
				if m.onSleep != nil {
					m.onSleep()
				}
				return nil
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
		{"reports resolve cannot take down", []string{"reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "TAKEDOWN"}, "--resolution must be NO_ACTION or DISMISSED"},
		{"reports resolve bad resolution", []string{"reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "BAN"}, "--resolution must be"},
		{"reports list bad status", []string{"reports", "list", "--project", "dzeroth-dev", "--status", "OLD"}, "OPEN or RESOLVED"},
		{"takedown bad post", []string{"takedown-post", "--project", "dzeroth-dev", "--post", "a/b"}, "19-digit post id"},
		{"takedown bad report", []string{"takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", "zz"}, "32-character report id"},
		{"suspend without uid", []string{"suspend-user", "--project", "dzeroth-dev"}, "--uid is required"},
		{"takedown-post rejects --dry-run", []string{"takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--dry-run"}, "--dry-run is not supported by takedown-post"},
		{"restore-post rejects --dry-run", []string{"restore-post", "--project", "dzeroth-dev", "--post", testPostID, "--dry-run"}, "--dry-run is not supported by restore-post"},
		{"unsuspend-user rejects --dry-run", []string{"unsuspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run"}, "--dry-run is not supported by unsuspend-user"},
		{"reports resolve rejects --dry-run", []string{"reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "DISMISSED", "--dry-run"}, "--dry-run is not supported by reports"},
		{"unquoted multi-word note must not swallow --dry-run", []string{"suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--note", "spam", "account", "--dry-run"}, "unexpected argument"},
		{"unquoted note must not swallow --resolution flags", []string{"reports", "resolve", "--project", "dzeroth-dev", "--id", testReportID, "--resolution", "DISMISSED", "--note", "two", "words", "--dry-run"}, "unexpected argument"},
		{"unquoted note must not swallow --report", []string{"takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--note", "bad", "post", "--report", testReportID}, "unexpected argument"},
		{"restore-post rejects --report", []string{"restore-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID}, "--report is not supported by restore-post"},
		{"takedown without project", []string{"takedown-post", "--post", testPostID}, "--project is required"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newModFixture()
			code, _, stderr := f.run("", tt.args...)
			wantCode := 2
			if code != wantCode || !strings.Contains(stderr, tt.want) {
				t.Fatalf("code=%d stderr=%q, want code %d containing %q", code, stderr, wantCode, tt.want)
			}
			if len(f.mod.takedowns)+len(f.mod.restores)+len(f.acc.calls)+len(f.ops.resolved)+f.mod.hideCalls+f.mod.restCall != 0 {
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
	if code != 0 || !strings.Contains(out, "reporter - (reporter deleted)") || !strings.Contains(out, "evidence post by @bob") ||
		!strings.Contains(out, "evidence media: m1, m2") {
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

func TestTakedownAndSuspend_ReportMustMatchTheTarget(t *testing.T) {
	t.Parallel()
	t.Run("takedown with a report about another post writes nothing", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetPost, TargetID: "0000000000000000099", Status: moderation.StatusOpen}
		code, _, stderr := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID)
		if code != 1 || !strings.Contains(stderr, "not POST "+testPostID) || len(f.mod.takedowns) != 0 || len(f.ops.resolved) != 0 {
			t.Fatalf("code=%d stderr=%q takedowns=%v resolved=%v", code, stderr, f.mod.takedowns, f.ops.resolved)
		}
	})
	t.Run("takedown with an account report is refused", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetAccount, TargetID: "u2", Status: moderation.StatusOpen}
		code, _, _ := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID)
		if code != 1 || len(f.mod.takedowns) != 0 {
			t.Fatalf("code=%d takedowns=%v", code, f.mod.takedowns)
		}
	})
	t.Run("an already resolved report warns and the action still applies", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetPost, TargetID: testPostID, Status: moderation.StatusResolved, Resolution: moderation.ResolutionDismissed}
		code, out, stderr := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID)
		if code != 0 || !strings.Contains(out, "already RESOLVED (DISMISSED)") || len(f.mod.takedowns) != 1 {
			t.Fatalf("code=%d out=%q stderr=%q takedowns=%v", code, out, stderr, f.mod.takedowns)
		}
	})
	t.Run("suspend with a report about another user is refused before the status write", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.ops.report = &moderation.Report{TargetType: moderation.TargetAccount, TargetID: "u3", TargetOwnerID: "u3", Status: moderation.StatusOpen}
		code, _, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--report", testReportID)
		if code != 1 || !strings.Contains(stderr, "another user's content") || len(f.acc.calls) != 0 || f.mod.hideCalls != 0 {
			t.Fatalf("code=%d stderr=%q acc=%v hide=%d", code, stderr, f.acc.calls, f.mod.hideCalls)
		}
	})
}

func TestSuspendUnsuspend(t *testing.T) {
	t.Parallel()
	t.Run("dry run writes nothing", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
		if code != 0 || !strings.Contains(out, "nothing written") || !strings.Contains(out, "reads~9 writes~15") || len(f.acc.calls) != 0 || f.mod.hideCalls != 0 {
			t.Fatalf("code=%d out=%q acc=%v hide=%d", code, out, f.acc.calls, f.mod.hideCalls)
		}
	})
	t.Run("dry run warns about the client reset when P reaches the removal log page", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			posts int64
			warn  bool
		}{{49, false}, {50, true}, {1203, true}} {
			f := newModFixture()
			f.plannedPosts = tc.posts
			code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
			if code != 0 || strings.Contains(out, "WARNING") != tc.warn || (tc.warn && !strings.Contains(out, "section 3b")) {
				t.Fatalf("P=%d code=%d warn=%v out=%q", tc.posts, code, tc.warn, out)
			}
		}
	})
	t.Run("suspend sets status first, hides every page, settles and resolves the report", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		old := time.Unix(1_000_000, 0).Add(-48 * time.Hour)
		f.mod.posts = []*fakePost{{id: 1, createdAt: old}, {id: 2, createdAt: old}, {id: 3, createdAt: old}, {id: 4, createdAt: old}, {id: 5, createdAt: old}}
		code, out, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--report", testReportID)
		if code != 0 {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if len(f.acc.calls) != 1 || f.acc.calls[0] != "u2:ACTIVE>SUSPENDED" {
			t.Errorf("acc=%v", f.acc.calls)
		}
		for i, p := range f.mod.posts {
			if !p.hidden {
				t.Errorf("post %d not hidden", i)
			}
		}
		if f.ops.resolved[testReportID] != moderation.ResolutionSuspended || !strings.Contains(out, "hidden=5") {
			t.Errorf("resolved=%v out=%q", f.ops.resolved, out)
		}
		if len(f.slept) != 1 || f.slept[0] < 60*time.Second {
			t.Errorf("settle wait = %v, want one wait of at least CACHE_TTL", f.slept)
		}
		// 3 pages of 2 for the full pass; the settle pass bounded by createdAt >= suspension - skew pages nothing.
		if f.mod.paged != 5 {
			t.Errorf("paged = %d, want 5 (the settle pass must not re-read old posts)", f.mod.paged)
		}
	})
	t.Run("a post created after page 1 was read is hidden by the settle pass", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		now := time.Unix(1_000_000, 0)
		old := now.Add(-48 * time.Hour)
		f.mod.posts = []*fakePost{{id: 1, createdAt: old}, {id: 2, createdAt: old}, {id: 3, createdAt: old}}
		late := &fakePost{id: 99, createdAt: now.Add(20 * time.Second)}
		f.mod.afterFirstHide = func() { f.mod.posts = append([]*fakePost{late}, f.mod.posts...) }
		code, out, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if !late.hidden {
			t.Fatalf("the late post was not hidden; out=%q", out)
		}
		if len(f.slept) != 1 {
			t.Errorf("settle waits = %v, want 1", f.slept)
		}
		// full pass: page 1 (2 posts) + page 2 (1 post); settle pass: only the late post (older ones are below
		// createdAt >= suspension - 2 min).
		if f.mod.paged != 2+1+1 {
			t.Errorf("paged = %d, want 4", f.mod.paged)
		}
	})
	t.Run("already suspended still finishes the posts", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.acc.same = true
		f.mod.posts = []*fakePost{{id: 1, createdAt: time.Unix(5, 0)}, {id: 2, createdAt: time.Unix(4, 0)}, {id: 3, createdAt: time.Unix(3, 0)}}
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || !strings.Contains(out, "already SUSPENDED") || !f.mod.posts[2].hidden {
			t.Fatalf("code=%d out=%q", code, out)
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
