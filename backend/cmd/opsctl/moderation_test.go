package main

import (
	"bytes"
	"cmp"
	"context"
	"errors"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
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
	// notes is the resolution note each Resolve call passed.
	notes  map[string]string
	getErr error
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

func (f *fakeOps) Resolve(_ context.Context, id string, res moderation.Resolution, note string, now time.Time) (moderation.Report, error) {
	if f.resolved == nil {
		f.resolved = map[string]moderation.Resolution{}
		f.notes = map[string]string{}
	}
	f.resolved[id] = res
	f.notes[id] = note
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
	releaseRepost       bool // Takedown reports a REPOST that was removed (issue #153)
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
	return posts.ModerationResult{AuthorID: "u2", Before: posts.ModerationNone, After: posts.ModerationTakenDown, RepostReleased: f.releaseRepost}, f.err
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

// fakeSweeper records the N-4 notification sweep (opsctl's notifications.ActorSweeper).
type fakeSweeper struct {
	calls []string
	// order, when set, receives "sweep" so tests can check it runs after the settle wait.
	order *[]string
}

func (f *fakeSweeper) SweepActorRows(_ context.Context, uid string, cp notifications.Checkpoint) (notifications.Checkpoint, bool, error) {
	f.calls = append(f.calls, uid)
	if f.order != nil {
		*f.order = append(*f.order, "sweep")
	}
	return notifications.Checkpoint{Step: 2, Deleted: cp.Deleted + 3}, true, nil
}

// fakeCopied lists the author's posts that have copies, in pages of one so paging is exercised.
type fakeCopied struct {
	ids   []string
	calls int
	err   error
}

func (f *fakeCopied) ListCopied(_ context.Context, _ string, after *posts.Position) ([]string, *posts.Position, bool, error) {
	f.calls++
	if f.err != nil {
		return nil, after, false, f.err
	}
	i := 0
	if after != nil {
		i, _ = strconv.Atoi(after.ID)
	}
	if i >= len(f.ids) {
		return nil, after, true, nil
	}
	return []string{f.ids[i]}, &posts.Position{ID: strconv.Itoa(i + 1)}, i+1 >= len(f.ids), nil
}

// fakeCleanup records the copy cleanup. moreFor lists post ids whose reposts never run out (page budget hit).
type fakeCleanup struct {
	reposts, quotes []string
	order           *[]string
	moreFor         map[string]bool
}

func (f *fakeCleanup) RemoveReposts(_ context.Context, id string, exists bool, _ int) (int, bool, error) {
	if !exists {
		panic("a suspension keeps the original, so its repostCount must be kept exact")
	}
	f.reposts = append(f.reposts, id)
	if f.order != nil {
		*f.order = append(*f.order, "copies")
	}
	return 2, f.moreFor[id], nil
}

func (f *fakeCleanup) TombstoneQuotes(_ context.Context, id string, _ int) (int, bool, error) {
	f.quotes = append(f.quotes, id)
	return 1, false, nil
}

type modFixture struct {
	copied  *fakeCopied
	cleanup *fakeCleanup
	sweep   *fakeSweeper
	order   []string
	ops     *fakeOps
	mod     *fakeModerator
	acc     *fakeAccounts
	// slept records the settle waits; onSleep runs while "waiting" (a post created in the cache window).
	slept   []time.Duration
	onSleep func()
	// plannedPosts is what the dry-run plan reports; 0 means 7.
	plannedPosts int64
}

func newModFixture() *modFixture {
	m := &modFixture{ops: &fakeOps{}, mod: &fakeModerator{}, acc: &fakeAccounts{}, sweep: &fakeSweeper{},
		copied: &fakeCopied{}, cleanup: &fakeCleanup{moreFor: map[string]bool{}}}
	m.sweep.order = &m.order
	m.cleanup.order = &m.order
	return m
}

func (m *modFixture) run(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{
			reports: m.ops, moderator: m.mod, accounts: m.acc, actorSweeper: m.sweep, copied: m.copied, cleanup: m.cleanup,
			postsPlanner: fakePostsPlanner{posts.PurgePlan{Posts: cmp.Or(m.plannedPosts, 7)}},
			profile: func(context.Context, string) (identity.Profile, error) {
				return identity.Profile{Status: identity.AccountStatusActive}, nil
			},
			sleep: func(_ context.Context, d time.Duration) error {
				m.slept = append(m.slept, d)
				m.order = append(m.order, "settle-wait")
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
	if strings.Contains(out, "ORIGINAL") {
		t.Fatalf("plain post report must not print the repost line: %q", out)
	}
	rep := moderation.Report{TargetType: moderation.TargetPost, TargetID: testPostID, TargetOwnerID: "u2", Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{Text: "orig", AuthorHandle: "carol", OriginalPostID: "1111111111111111111"}}
	f.ops.report = &rep
	code, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 || !strings.Contains(out, "evidence post by @carol") || !strings.Contains(out, "ORIGINAL post 1111111111111111111") {
		t.Fatalf("repost show: code=%d out=%q", code, out)
	}
	rep.Evidence.PollChoices = []string{"Yes", "No"}
	code, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 || !strings.Contains(out, `evidence poll choices: ["Yes" "No"]`) {
		t.Fatalf("poll show: code=%d out=%q", code, out)
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
	t.Run("unsuspend dry run warns about the reset when P reaches the removal log page and writes nothing", func(t *testing.T) {
		t.Parallel()
		for _, tc := range []struct {
			posts int64
			warn  bool
		}{{49, false}, {50, true}, {1203, true}} {
			f := newModFixture()
			f.plannedPosts = tc.posts
			code, out, _ := f.run("", "unsuspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
			if code != 0 || strings.Contains(out, "WARNING") != tc.warn || !strings.Contains(out, "nothing written") ||
				(tc.warn && !strings.Contains(out, "followers of this account")) || len(f.acc.calls) != 0 || f.mod.restCall != 0 {
				t.Fatalf("P=%d code=%d warn=%v out=%q acc=%v restores=%d", tc.posts, code, tc.warn, out, f.acc.calls, f.mod.restCall)
			}
		}
	})
	t.Run("suspend sweeps the notification rows about the actor after the settle wait, never on a dry run", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		if code, _, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run"); code != 0 || len(f.sweep.calls) != 0 {
			t.Fatalf("dry run swept: code=%d calls=%v", code, f.sweep.calls)
		}
		code, out, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || !reflect.DeepEqual(f.sweep.calls, []string{"u2"}) || !reflect.DeepEqual(f.order, []string{"settle-wait", "sweep"}) {
			t.Fatalf("code=%d calls=%v order=%v stderr=%q", code, f.sweep.calls, f.order, stderr)
		}
		if !strings.Contains(out, "notification sweep") || !strings.Contains(out, "swept=3") {
			t.Errorf("out=%q, want the sweep progress", out)
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

// Issue #151: suspend-user removes the copies other users hold of the author's posts, after the settle wait.
func TestSuspendUser_CleansUpCopiesOfTheHiddenPosts(t *testing.T) {
	t.Parallel()
	t.Run("copies are removed for posts that have them, after the settle wait, never on a dry run", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.copied.ids = []string{"1111111111111111111", "2222222222222222222"}
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
		if code != 0 || len(f.cleanup.reposts) != 0 || f.copied.calls != 0 {
			t.Fatalf("dry run: code=%d cleanup=%v listed=%d, want nothing touched", code, f.cleanup.reposts, f.copied.calls)
		}
		if !strings.Contains(out, "PERMANENT") {
			t.Errorf("dry run out=%q, want the permanence warning", out)
		}
		code, out, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 {
			t.Fatalf("code=%d stderr=%q", code, stderr)
		}
		if got := strings.Join(f.cleanup.reposts, ","); got != "1111111111111111111,2222222222222222222" {
			t.Errorf("reposts cleaned for %q", got)
		}
		if got := strings.Join(f.cleanup.quotes, ","); got != "1111111111111111111,2222222222222222222" {
			t.Errorf("quotes cleaned for %q", got)
		}
		if !strings.Contains(out, "posts with copies=2 reposts removed=4 quote embeds tombstoned=2") {
			t.Errorf("out=%q, want the copy totals", out)
		}
		w := slices.Index(f.order, "settle-wait")
		c := slices.Index(f.order, "copies")
		if w < 0 || c < w {
			t.Errorf("order=%v, want the copy cleanup after the settle wait", f.order)
		}
	})
	t.Run("an author whose posts have no copies costs only the listing", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || len(f.cleanup.reposts) != 0 || !strings.Contains(out, "posts with copies=0") {
			t.Fatalf("code=%d out=%q cleanup=%v", code, out, f.cleanup.reposts)
		}
	})
	t.Run("a post with more copies than one run handles is reported so the operator re-runs", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.copied.ids = []string{"1111111111111111111"}
		f.cleanup.moreFor["1111111111111111111"] = true
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 || !strings.Contains(out, "re-run suspend-user to finish") {
			t.Fatalf("code=%d out=%q, want the re-run note", code, out)
		}
	})
	t.Run("a listing failure stops before the report is resolved and says to re-run", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.copied.err = errors.New("boom")
		code, _, stderr := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--report", testReportID)
		if code == 0 || !strings.Contains(stderr, "re-run suspend-user to resume") {
			t.Fatalf("code=%d stderr=%q, want a failure that says to re-run", code, stderr)
		}
		if len(f.ops.resolved) != 0 {
			t.Errorf("the report was resolved although the copy cleanup failed")
		}
	})
}

// Issue #153: a taken-down REPOST is removed, and the operator is told restore-post will not bring it back.
func TestTakedownPost_RepostIsReleasedNotHidden(t *testing.T) {
	t.Parallel()
	f := newModFixture()
	f.mod.releaseRepost = true
	code, out, stderr := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID)
	if code != 0 || !strings.Contains(out, "a REPOST is removed, not hidden") || !strings.Contains(out, "can repost again") {
		t.Fatalf("code=%d out=%q stderr=%q, want the removal note", code, out, stderr)
	}
	f = newModFixture()
	if _, out, _ := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID); strings.Contains(out, "REPOST is removed") {
		t.Errorf("a plain post got the repost note: %q", out)
	}
}
