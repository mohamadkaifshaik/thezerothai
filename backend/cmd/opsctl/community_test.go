package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

const (
	testCommunityID  = "0000000000000000555"
	testCommunityID2 = "0000000000000000556"
)

// fakePlatform is a communities.Platform over one in-memory community.
type fakePlatform struct {
	exists   bool
	status   communities.Status
	owner    string
	sets     int
	archives int
	err      error
}

func newPlatform(status communities.Status, owner string) *fakePlatform {
	return &fakePlatform{exists: true, status: status, owner: owner}
}

func (f *fakePlatform) Get(ctx context.Context, id string) (communities.Community, error) {
	budget.FromContext(ctx).AddReads(1)
	if !f.exists {
		return communities.Community{}, communities.ErrNotFound
	}
	return communities.Community{ID: id, Name: "SECRET NAME", Status: f.status, OwnerID: f.owner}, nil
}

func (f *fakePlatform) SetSuspended(ctx context.Context, _ string, suspend bool, _ time.Time) (bool, communities.Status, communities.Status, error) {
	budget.FromContext(ctx).AddReads(1)
	if f.err != nil {
		return false, "", "", f.err
	}
	if !f.exists {
		return false, "", "", communities.ErrNotFound
	}
	before := f.status
	switch {
	case suspend && f.status != communities.StatusSuspended:
		f.status = communities.StatusSuspended
	case !suspend && f.status == communities.StatusSuspended:
		f.status = communities.StatusActive
		if f.owner == "" {
			f.status = communities.StatusArchived
		}
	default:
		return false, before, before, nil
	}
	f.sets++
	budget.FromContext(ctx).AddWrites(1)
	return true, before, f.status, nil
}

func (f *fakePlatform) Archive(ctx context.Context, _ string, _ time.Time, _ int) (communities.ArchiveResult, error) {
	budget.FromContext(ctx).AddReads(1)
	if !f.exists {
		return communities.ArchiveResult{}, communities.ErrNotFound
	}
	if f.status == communities.StatusSuspended {
		return communities.ArchiveResult{}, communities.ErrSuspendedArchive
	}
	if f.owner == "" {
		return communities.ArchiveResult{}, nil
	}
	budget.FromContext(ctx).AddReads(2)
	budget.FromContext(ctx).AddWrites(2)
	f.owner, f.status = "", communities.StatusArchived
	f.archives++
	return communities.ArchiveResult{Changed: true, OwnerMember: communities.MemberJoined}, nil
}

// fakeRemovals records the recentRemovals appends per community; missing lists communities that no longer exist, failing the next N calls.
type fakeRemovals struct {
	calls   []removalCall
	listed  map[string]bool // cid|post, like the real Append: a post already listed adds nothing
	missing map[string]bool
	failN   int
}

type removalCall struct {
	cid  string
	ids  []string
	when time.Time
}

func (f *fakeRemovals) Append(_ context.Context, cid string, ids []string, at time.Time, _ int) (int, error) {
	if f.failN > 0 {
		f.failN--
		return 0, errors.New("boom")
	}
	if f.missing[cid] {
		return 0, communities.ErrNotFound
	}
	if f.listed == nil {
		f.listed = map[string]bool{}
	}
	var fresh []string
	for _, id := range ids {
		if !f.listed[cid+"|"+id] {
			f.listed[cid+"|"+id] = true
			fresh = append(fresh, id)
		}
	}
	if len(fresh) > 0 {
		f.calls = append(f.calls, removalCall{cid, fresh, at})
	}
	return len(fresh), nil
}

func runCommunity(plat *fakePlatform, ops *fakeOps, stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	open := func(context.Context, string) (*backends, error) {
		return &backends{communities: plat, reports: ops, close: func() {}}, nil
	}
	now := func() time.Time { return time.Unix(1_000_000, 0) }
	code = run(context.Background(), args, strings.NewReader(stdin), &out, &errOut, open, now)
	return code, out.String(), errOut.String()
}

func TestCommunity_UsageAndValidation(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		args []string
		want string
	}{
		{"no sub-command", []string{"community", "--project", "dzeroth-dev"}, "community needs a sub-command"},
		{"unknown sub-command", []string{"community", "delete", "--project", "dzeroth-dev"}, "community needs a sub-command"},
		{"suspend without an id", []string{"community", "suspend", "--project", "dzeroth-dev"}, "needs the community id"},
		{"restore without an id", []string{"community", "restore", "--project", "dzeroth-dev"}, "needs the community id"},
		{"archive without an id", []string{"community", "archive", "--project", "dzeroth-dev"}, "needs the community id"},
		{"short id", []string{"community", "suspend", "123", "--project", "dzeroth-dev"}, "19 digits"},
		{"letters in the id", []string{"community", "suspend", "123456789012345678x", "--project", "dzeroth-dev"}, "19 digits"},
		{"a path in the id", []string{"community", "suspend", "communities/" + testCommunityID, "--project", "dzeroth-dev"}, "19 digits"},
		{"two ids", []string{"community", "suspend", testCommunityID, testCommunityID, "--project", "dzeroth-dev"}, "unexpected argument"},
		{"no project", []string{"community", "suspend", testCommunityID}, "--project is required"},
		{"uid is not a substitute for the id", []string{"community", "suspend", "--uid", "u1", "--project", "dzeroth-dev"}, "needs the community id"},
		{"report on restore", []string{"community", "restore", testCommunityID, "--report", testReportID, "--project", "dzeroth-dev"}, "--report is for community suspend only"},
		{"report on archive", []string{"community", "archive", testCommunityID, "--report", testReportID, "--project", "dzeroth-dev"}, "--report is for community suspend only"},
		{"bad report id", []string{"community", "suspend", testCommunityID, "--report", "xyz", "--project", "dzeroth-dev"}, "32-character report id"},
		{"note without a report", []string{"community", "suspend", testCommunityID, "--note", "x", "--project", "dzeroth-dev"}, "--note is the report resolution note"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			p := newPlatform(communities.StatusActive, "owner")
			code, out, errOut := runCommunity(p, &fakeOps{}, "", tt.args...)
			if code != 2 || !strings.Contains(errOut, tt.want) {
				t.Fatalf("code=%d stderr=%q, want 2 containing %q", code, errOut, tt.want)
			}
			if p.sets != 0 || strings.Contains(out, "cost:") {
				t.Errorf("a usage error did work: sets=%d out=%q", p.sets, out)
			}
		})
	}
}

func TestCommunity_SuspendRestoreCostAndOutput(t *testing.T) {
	t.Parallel()
	p := newPlatform(communities.StatusActive, "owner")
	hash := communityHashForAudit(testCommunityID)
	steps := []struct {
		name string
		args []string
		want []string
		not  []string
	}{
		{"dry-run suspend writes nothing", []string{"community", "suspend", testCommunityID, "--dry-run"}, []string{"currently ACTIVE", "would write status SUSPENDED", "cost: reads=1 writes=0"}, []string{"audit:"}},
		{"suspend", []string{"community", "suspend", testCommunityID}, []string{"suspended: community_hash=" + hash, "within 60 s", "wrote=true", "cost: reads=1 writes=1"}, nil},
		{"suspend again", []string{"community", "suspend", testCommunityID}, []string{"already suspended", "wrote=false", "cost: reads=1 writes=0"}, nil},
		{"dry-run restore", []string{"community", "restore", testCommunityID, "--dry-run"}, []string{"currently SUSPENDED", "would write status ACTIVE", "cost: reads=1 writes=0"}, []string{"audit:"}},
		{"restore", []string{"community", "restore", testCommunityID}, []string{"restored: community_hash=" + hash, "status=ACTIVE", "wrote=true", "cost: reads=1 writes=1"}, nil},
		{"restore again", []string{"community", "restore", testCommunityID}, []string{"not suspended", "wrote=false", "cost: reads=1 writes=0"}, nil},
	}
	for _, s := range steps {
		code, out, errOut := runCommunity(p, &fakeOps{}, "", append(s.args, "--project", "dzeroth-dev")...)
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
		if strings.Contains(out, testCommunityID) || strings.Contains(out, "SECRET NAME") {
			t.Errorf("%s: the output names the community id, its name or its owner:\n%s", s.name, out)
		}
	}
	if p.sets != 2 {
		t.Errorf("sets = %d, want 2 (suspend, restore)", p.sets)
	}
}

func TestCommunity_RestoreOfOwnerlessIsArchived(t *testing.T) {
	t.Parallel()
	p := newPlatform(communities.StatusSuspended, "")
	code, out, _ := runCommunity(p, &fakeOps{}, "", "community", "restore", testCommunityID, "--dry-run", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "would write status ARCHIVED (no owner)") {
		t.Fatalf("dry-run: code=%d out=%q", code, out)
	}
	code, out, _ = runCommunity(p, &fakeOps{}, "", "community", "restore", testCommunityID, "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "status=ARCHIVED") || p.status != communities.StatusArchived {
		t.Fatalf("restore: code=%d out=%q status=%s", code, out, p.status)
	}
}

func TestCommunity_Archive(t *testing.T) {
	t.Parallel()
	p := newPlatform(communities.StatusActive, "owner")
	steps := []struct {
		name string
		args []string
		code int
		want []string
	}{
		{"dry-run", []string{"community", "archive", testCommunityID, "--dry-run"}, 0, []string{"would write status ARCHIVED and clear the owner", "cost: reads=1 writes=0"}},
		{"archive", []string{"community", "archive", testCommunityID}, 0, []string{"archived: community_hash=", "restore does NOT undo this", "wrote=true", "cost: reads=3 writes=2"}},
		{"archive again", []string{"community", "archive", testCommunityID}, 0, []string{"already ownerless", "wrote=false", "cost: reads=1 writes=0"}},
	}
	for _, s := range steps {
		code, out, errOut := runCommunity(p, &fakeOps{}, "", append(s.args, "--project", "dzeroth-dev")...)
		if code != s.code {
			t.Fatalf("%s: code %d stderr %q", s.name, code, errOut)
		}
		for _, w := range s.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: output lacks %q:\n%s", s.name, w, out)
			}
		}
	}
	if p.archives != 1 {
		t.Errorf("archives = %d", p.archives)
	}

	// A SUSPENDED community is refused with nothing written.
	s := newPlatform(communities.StatusSuspended, "owner")
	code, _, errOut := runCommunity(s, &fakeOps{}, "", "community", "archive", testCommunityID, "--project", "dzeroth-dev")
	if code != 1 || !strings.Contains(errOut, "community restore first") || s.archives != 0 {
		t.Errorf("suspended archive: code=%d stderr=%q archives=%d", code, errOut, s.archives)
	}
	code, out, _ := runCommunity(s, &fakeOps{}, "", "community", "archive", testCommunityID, "--dry-run", "--project", "dzeroth-dev")
	if code != 0 || !strings.Contains(out, "refused: SUSPENDED") {
		t.Errorf("suspended archive dry-run: code=%d out=%q", code, out)
	}
}

func TestCommunity_MissingCommunityIsAnErrorWithNothingWritten(t *testing.T) {
	t.Parallel()
	for _, sub := range []string{"suspend", "restore", "archive"} {
		for _, dry := range []bool{false, true} {
			p := &fakePlatform{}
			args := []string{"community", sub, testCommunityID, "--project", "dzeroth-dev"}
			if dry {
				args = append(args, "--dry-run")
			}
			code, out, errOut := runCommunity(p, &fakeOps{}, "", args...)
			if code != 1 || !strings.Contains(errOut, "no such community") || p.sets != 0 || strings.Contains(out, "audit:") {
				t.Errorf("%s dry=%v: code=%d stderr=%q out=%q", sub, dry, code, errOut, out)
			}
		}
	}
}

func TestCommunity_SuspendWithReport(t *testing.T) {
	t.Parallel()
	communityReport := func(target string, status moderation.Status) *moderation.Report {
		return &moderation.Report{TargetType: moderation.TargetCommunity, TargetID: target, Status: status, Resolution: moderation.ResolutionDismissed}
	}
	t.Run("a COMMUNITY report of this community is resolved as TAKEDOWN with the note", func(t *testing.T) {
		t.Parallel()
		p, ops := newPlatform(communities.StatusActive, "owner"), &fakeOps{report: communityReport(testCommunityID, moderation.StatusOpen)}
		code, out, errOut := runCommunity(p, ops, "", "community", "suspend", testCommunityID, "--report", testReportID, "--note", "hate speech", "--project", "dzeroth-dev")
		if code != 0 || p.status != communities.StatusSuspended || ops.resolved[testReportID] != moderation.ResolutionTakedown || ops.notes[testReportID] != "hate speech" {
			t.Fatalf("code=%d stderr=%q status=%s resolved=%v notes=%v", code, errOut, p.status, ops.resolved, ops.notes)
		}
		// check 1 read + suspend 1 read + 1 write (the fake report store is outside the counter).
		if !strings.Contains(out, "report="+testReportID) || !strings.Contains(out, "cost: reads=1 writes=1") {
			t.Errorf("out=%q", out)
		}
	})
	t.Run("a report about another community writes nothing", func(t *testing.T) {
		t.Parallel()
		p, ops := newPlatform(communities.StatusActive, "owner"), &fakeOps{report: communityReport(testCommunityID2, moderation.StatusOpen)}
		code, _, errOut := runCommunity(p, ops, "", "community", "suspend", testCommunityID, "--report", testReportID, "--project", "dzeroth-dev")
		if code != 1 || !strings.Contains(errOut, "not COMMUNITY "+testCommunityID) || p.sets != 0 || len(ops.resolved) != 0 {
			t.Fatalf("code=%d stderr=%q sets=%d resolved=%v", code, errOut, p.sets, ops.resolved)
		}
	})
	t.Run("a POST report is refused", func(t *testing.T) {
		t.Parallel()
		p, ops := newPlatform(communities.StatusActive, "owner"), &fakeOps{report: &moderation.Report{TargetType: moderation.TargetPost, TargetID: testCommunityID, Status: moderation.StatusOpen}}
		code, _, _ := runCommunity(p, ops, "", "community", "suspend", testCommunityID, "--report", testReportID, "--project", "dzeroth-dev")
		if code != 1 || p.sets != 0 {
			t.Fatalf("code=%d sets=%d", code, p.sets)
		}
	})
	t.Run("an already suspended community still resolves the report", func(t *testing.T) {
		t.Parallel()
		p, ops := newPlatform(communities.StatusSuspended, "owner"), &fakeOps{report: communityReport(testCommunityID, moderation.StatusOpen)}
		code, out, _ := runCommunity(p, ops, "", "community", "suspend", testCommunityID, "--report", testReportID, "--project", "dzeroth-dev")
		if code != 0 || !strings.Contains(out, "already suspended") || ops.resolved[testReportID] != moderation.ResolutionTakedown {
			t.Fatalf("code=%d out=%q resolved=%v", code, out, ops.resolved)
		}
	})
	t.Run("dry-run resolves nothing", func(t *testing.T) {
		t.Parallel()
		p, ops := newPlatform(communities.StatusActive, "owner"), &fakeOps{report: communityReport(testCommunityID, moderation.StatusOpen)}
		code, out, _ := runCommunity(p, ops, "", "community", "suspend", testCommunityID, "--report", testReportID, "--dry-run", "--project", "dzeroth-dev")
		if code != 0 || !strings.Contains(out, "would resolve report") || p.sets != 0 || len(ops.resolved) != 0 {
			t.Fatalf("code=%d out=%q sets=%d resolved=%v", code, out, p.sets, ops.resolved)
		}
	})
}

func TestReportsShow_CommunityEvidence(t *testing.T) {
	t.Parallel()
	ops := &fakeOps{report: &moderation.Report{
		TargetType: moderation.TargetCommunity, TargetID: testCommunityID, TargetOwnerID: "owner", Status: moderation.StatusOpen,
		Evidence: &moderation.Evidence{AuthorHandle: "mallory", CommunityName: "targets", CommunityDescription: "people to watch",
			CommunityRules: []moderation.CommunityRule{{Title: "Be kind", Text: "No insults."}}},
	}}
	f := &modFixture{ops: ops, mod: &fakeModerator{}, acc: &fakeAccounts{}}
	code, out, errOut := f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID)
	if code != 0 {
		t.Fatalf("code=%d stderr=%q", code, errOut)
	}
	for _, w := range []string{`evidence community owned by @mallory`, `name "targets"`, `description "people to watch"`, `evidence rule 1: title "Be kind", text "No insults."`} {
		if !strings.Contains(out, w) {
			t.Errorf("output lacks %q:\n%s", w, out)
		}
	}
	ops.report.Evidence = nil
	if _, out, _ = f.run("", "reports", "show", "--project", "dzeroth-dev", "--id", testReportID); !strings.Contains(out, "evidence none") {
		t.Errorf("no evidence: %q", out)
	}
}

// takedown-post of a community post appends it to that community's recentRemovals (once); a plain post appends nothing; a missing
// community is a note; an append failure is an error that says to re-run.
func TestTakedownPost_AppendsToTheCommunityRemovalLog(t *testing.T) {
	t.Parallel()
	t.Run("community post", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.mod.takedownCommunity = testCommunityID
		code, out, errOut := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID)
		if code != 0 {
			t.Fatalf("code=%d stderr=%q", code, errOut)
		}
		if len(f.removals.calls) != 1 || f.removals.calls[0].cid != testCommunityID || len(f.removals.calls[0].ids) != 1 || f.removals.calls[0].ids[0] != testPostID {
			t.Fatalf("appends = %+v", f.removals.calls)
		}
		if !strings.Contains(out, "community removal log: communities=1 entries=1 missing=0") || strings.Contains(out, testCommunityID) {
			t.Errorf("out = %q", out)
		}
	})
	t.Run("plain post", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID)
		if code != 0 || len(f.removals.calls) != 0 || strings.Contains(out, "community removal log") {
			t.Fatalf("code=%d appends=%v out=%q", code, f.removals.calls, out)
		}
	})
	t.Run("a deleted community is a note, not an error", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.mod.takedownCommunity = testCommunityID
		f.removals.missing = map[string]bool{testCommunityID: true}
		code, out, _ := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID, "--report", testReportID)
		if code != 0 || !strings.Contains(out, "communities=0 entries=0 missing=1") || f.ops.resolved[testReportID] != moderation.ResolutionTakedown {
			t.Fatalf("code=%d out=%q resolved=%v", code, out, f.ops.resolved)
		}
	})
	t.Run("an append failure asks for a re-run", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.mod.takedownCommunity = testCommunityID
		f.removals.failN = 1
		code, _, errOut := f.run("", "takedown-post", "--project", "dzeroth-dev", "--post", testPostID)
		if code != 1 || !strings.Contains(errOut, "re-run takedown-post") || strings.Contains(errOut, testCommunityID) {
			t.Fatalf("code=%d stderr=%q", code, errOut)
		}
	})
}

// suspend-user appends the community posts of every page (main pass and settle pass) once per community per page; a failed append repeats
// the page.
func TestSuspendUser_AppendsToTheCommunityRemovalLog(t *testing.T) {
	t.Parallel()
	posts5 := func() []*fakePost {
		// newest first, pages of fakePage = 2: [5 4] [3 2] [1]
		return []*fakePost{
			{id: 5, createdAt: time.Unix(1_000_000, 0), communityID: testCommunityID},
			{id: 4, createdAt: time.Unix(999_000, 0), communityID: testCommunityID},
			{id: 3, createdAt: time.Unix(998_000, 0), communityID: testCommunityID2},
			{id: 2, createdAt: time.Unix(997_000, 0)},
			{id: 1, createdAt: time.Unix(996_000, 0), communityID: testCommunityID},
		}
	}
	t.Run("one append per community per page", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.mod.posts = posts5()
		code, out, errOut := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 {
			t.Fatalf("code=%d stderr=%q out=%q", code, errOut, out)
		}
		got := map[string][]string{}
		for _, c := range f.removals.calls {
			got[c.cid] = append(got[c.cid], strings.Join(c.ids, ","))
		}
		// main pass: page 1 -> community A [5 4]; page 2 -> community B [3]; page 3 -> community A [1]. The settle pass pages the posts
		// since suspension (none of these are that new, so it adds none) and repeats nothing.
		if got[testCommunityID][0] != "5,4" || got[testCommunityID2][0] != "3" || got[testCommunityID][1] != "1" {
			t.Errorf("appends = %v", got)
		}
		if !strings.Contains(out, "community removal log: communities=3 entries=4 missing=0") {
			t.Errorf("out = %q", out)
		}
	})
	t.Run("a failed append repeats the page and still finishes", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		f.mod.posts = posts5()
		f.removals.failN = 1
		code, out, errOut := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2")
		if code != 0 {
			t.Fatalf("code=%d stderr=%q out=%q", code, errOut, out)
		}
		if !strings.Contains(out, "community removal log: communities=3 entries=4 missing=0") {
			t.Errorf("out = %q", out)
		}
	})
	t.Run("dry-run says what it would add and writes nothing", func(t *testing.T) {
		t.Parallel()
		f := newModFixture()
		code, out, _ := f.run("", "suspend-user", "--project", "dzeroth-dev", "--uid", "u2", "--dry-run")
		if code != 0 || !strings.Contains(out, "recentRemovals append per community") || len(f.removals.calls) != 0 {
			t.Fatalf("code=%d out=%q", code, out)
		}
	})
}

// A removed-id append does not run for unsuspend-user or restore-post (ADR-0031 D6: they do not list).
func TestRestoreAndUnsuspendDoNotTouchTheRemovalLog(t *testing.T) {
	t.Parallel()
	f := newModFixture()
	f.mod.takedownCommunity = testCommunityID
	if code, _, _ := f.run("", "restore-post", "--project", "dzeroth-dev", "--post", testPostID); code != 0 {
		t.Fatal("restore-post")
	}
	if code, _, _ := f.run("", "unsuspend-user", "--project", "dzeroth-dev", "--uid", "u2"); code != 0 {
		t.Fatal("unsuspend-user")
	}
	if len(f.removals.calls) != 0 {
		t.Errorf("appends = %+v", f.removals.calls)
	}
}
