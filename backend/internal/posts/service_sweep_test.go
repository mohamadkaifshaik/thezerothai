package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// Unit tests of the sweep's orchestration (ADR-0021 "Sweep" steps 1, 2 and 6, CMP-D4): the no-op cases, fetch-then-
// dispatch, the per-author queues and caps, bounded concurrency, the deadline guard and the query-failure contract.
// Clock-injected (e.now), no sleeps: the only timers are timeouts that fail a hung test.

func sweepMediaID(n int) string { return fmt.Sprintf("%019d", n) }

func TestSweep_NoOpCases(t *testing.T) {
	tests := []struct {
		name     string
		flags    GloballyOffChecker
		readOnly bool
		want     string
	}{
		{"scheduled_posts is off for everyone", sweepFlags{ScheduledPostsFlagName: true}, false, SweepFlagOff},
		{"posts is off for everyone", sweepFlags{FlagName: true}, false, SweepFlagOff},
		{"both off", sweepFlags{FlagName: true, ScheduledPostsFlagName: true}, false, SweepFlagOff},
		{"no flag checker fails closed", nil, false, SweepFlagOff},
		{"degraded mode readonly", sweepFlags{}, true, SweepDegraded},
		{"a flag off wins over readonly", sweepFlags{ScheduledPostsFlagName: true}, true, SweepFlagOff},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Flags, d.ReadOnly = tc.flags, tc.readOnly })
			e.dueItem("uid-alice", 1)

			res, c, err := e.sweep(context.Background())
			if err != nil {
				t.Fatalf("err = %v, want nil (204)", err)
			}
			if res.Outcome != tc.want {
				t.Errorf("outcome = %q, want %q", res.Outcome, tc.want)
			}
			if c.Reads() != 0 || c.Writes() != 0 || e.repo.dueCalls != 0 || len(e.repo.callsOf("publish")) != 0 {
				t.Errorf("a no-op run touched the repository: reads=%d writes=%d due calls=%d", c.Reads(), c.Writes(), e.repo.dueCalls)
			}
			if got := e.repo.doc("uid-alice", e.firstID("uid-alice")); got.Status != ScheduledPending {
				t.Errorf("item status = %v, want it left PENDING", got.Status)
			}
		})
	}
}

// firstID returns the id of uid's item n=1.
func (e *sweepEnv) firstID(uid string) string {
	id, _ := ScheduledID(uid, schedKeyFor(1))
	return id
}

// Only the kill switch is a no-op: in allowlist or percent mode every due doc is still processed, because only enabled
// users could create it. The decision goes through the real flags.Registry.GloballyOff.
func TestSweep_RolloutModesStillPublishAndOffDoesNot(t *testing.T) {
	tests := []struct {
		name string
		spec flags.Spec
		want string
		pub  int
	}{
		{"off", flags.Spec{Name: ScheduledPostsFlagName, Mode: flags.Off}, SweepFlagOff, 0},
		{"allowlist without the author", flags.Spec{Name: ScheduledPostsFlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}, SweepOK, 1},
		{"allowlist, empty", flags.Spec{Name: ScheduledPostsFlagName, Mode: flags.Allowlist}, SweepOK, 1},
		{"percent 0", flags.Spec{Name: ScheduledPostsFlagName, Mode: flags.Percent, Percent: 0}, SweepOK, 1},
		{"on", flags.Spec{Name: ScheduledPostsFlagName, Mode: flags.On}, SweepOK, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			reg := flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, tc.spec)
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Flags = reg })
			e.dueItem("uid-alice", 1)
			res, _, err := e.sweep(context.Background())
			if err != nil || res.Outcome != tc.want || res.Published != tc.pub {
				t.Fatalf("res = %+v err = %v, want outcome %q and %d published", res, err, tc.want, tc.pub)
			}
		})
	}
}

func TestSweep_PublishesADueItemLikeCreatePost(t *testing.T) {
	e := newSweepEnv(t)
	it := e.dueItem("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{
			Text: "hi @bob @nobody #Go", ReplyPolicy: ReplyPolicyMentionedOnly, PaidPartnership: true, MadeWithAI: true,
			Media: []MediaRef{{ID: sweepMediaID(1), AltText: "an alt"}, {ID: sweepMediaID(2)}},
		}
	})

	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != SweepOK || res.Due != 1 || res.Published != 1 || res.Deferred != 0 || len(res.Failed) != 0 {
		t.Fatalf("res = %+v", res)
	}
	// 1 read for the due query + the publish transaction's (the fake charges its documented typical 3) and 4 writes.
	if c.Reads() != 4 || c.Writes() != 4 {
		t.Errorf("run cost = %d reads %d writes, want 4 and 4", c.Reads(), c.Writes())
	}

	// The transaction was handed the parsed draft and the limits; the author snapshot is built inside it.
	if len(e.repo.params) != 1 {
		t.Fatalf("publish calls = %d, want 1", len(e.repo.params))
	}
	p := e.repo.params[0]
	if p.UID != "uid-alice" || p.ID != it.ID || p.Draft.Kind != KindPost || p.Draft.Visibility != VisibilityPublic ||
		p.Draft.Text != "hi @bob @nobody #Go" || p.Draft.ReplyPolicy != ReplyPolicyMentionedOnly || !p.Draft.PaidPartnership || !p.Draft.MadeWithAI {
		t.Errorf("params = %+v", p)
	}
	if len(p.Draft.Hashtags) != 1 || p.Draft.Hashtags[0] != "go" {
		t.Errorf("hashtags = %v, want [go]", p.Draft.Hashtags)
	}
	if strings.Join(p.MediaIDs, ",") != sweepMediaID(1)+","+sweepMediaID(2) || strings.Join(p.MediaAlts, "|") != "an alt|" {
		t.Errorf("media = %v alts %q", p.MediaIDs, p.MediaAlts)
	}
	if p.PostsLimit != 100 || p.NewAccountPostsLimit != 20 || p.NewAccountWindow != 24*time.Hour || p.TerminalTTL != 168*time.Hour || !p.Now.Equal(e.now) {
		t.Errorf("limits = %d/%d window %v ttl %v now %v", p.PostsLimit, p.NewAccountPostsLimit, p.NewAccountWindow, p.TerminalTTL, p.Now)
	}

	// The item is PUBLISHED with the post id and no draft; exactly what CreatePost does after its commit followed.
	doc := e.repo.doc("uid-alice", it.ID)
	if doc.Status != ScheduledPublished || doc.PostID == "" || doc.Draft != nil || doc.ExpireAt == nil {
		t.Errorf("stored item = %+v", doc)
	}
	post := e.repo.publishedPosts[0]
	if got, ok := e.cache.GetPost(post.ID); !ok || got != post {
		t.Error("the published post is not in the instance cache")
	}
	if len(e.events.created) != 1 || e.events.created[0] != post {
		t.Fatalf("PostEvents.Created calls = %d, want 1 with the published post", len(e.events.created))
	}
	if m := e.events.created[0].Mentions; len(m) != 1 || m[0].UserID != "uid-bob" || m[0].Handle != "bob" {
		t.Errorf("mentions = %v, want only the resolvable @bob (resolved at publish)", m)
	}
	if len(e.dir.forgotten) != 1 || e.dir.forgotten[0] != "uid-alice" {
		t.Errorf("directory.Forget = %v, want [uid-alice]", e.dir.forgotten)
	}
}

// A page-2 item joins its author's existing queue and counts toward the cap; the author is ONE worker, one after
// another; the over-cap item is deferred without any write; every page is fetched before the first item runs.
func TestSweep_FetchThenDispatchAndPerAuthorCapAcrossPages(t *testing.T) {
	e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.Limit, d.Limits.MaxPages = 2, 2 })
	a1 := e.dueItem("uid-a", 1)
	a2 := e.dueItem("uid-a", 2)
	a3 := e.dueItem("uid-a", 3) // page 2, joins A's queue as its third
	a4 := e.dueItem("uid-a", 4) // page 2, over the cap of 3
	e.dueItem("uid-a", 5)       // not fetched: MaxPages is 2 pages of 2

	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Due != 4 || res.Published != 3 || res.Deferred != 1 {
		t.Fatalf("res = %+v, want 4 due, 3 published, 1 deferred", res)
	}
	for _, it := range []*ScheduledPost{a1, a2, a3} {
		if got := e.repo.doc("uid-a", it.ID).Status; got != ScheduledPublished {
			t.Errorf("item %s status = %v, want PUBLISHED", it.ID[:6], got)
		}
	}
	if got := e.repo.doc("uid-a", a4.ID); got.Status != ScheduledPending || got.Attempts != 0 {
		t.Errorf("deferred item = %+v, want untouched", got)
	}
	if e.repo.dueCalls != 2 {
		t.Errorf("due calls = %d, want exactly SCHEDULED_SWEEP_MAX_PAGES (2)", e.repo.dueCalls)
	}
	if n := len(e.repo.callsOf("transition")) + len(e.repo.callsOf("bump")); n != 0 {
		t.Errorf("a deferred item cost %d bookkeeping writes, want 0", n)
	}
	// 2 pages x 2 reads + 3 publishes x (3 reads, 4 writes).
	if c.Reads() != 4+9 || c.Writes() != 12 {
		t.Errorf("run cost = %d reads %d writes, want 13 and 12", c.Reads(), c.Writes())
	}

	// Fetch FIRST, then dispatch: no publish before the last due call.
	lastDue, firstPublish := -1, -1
	e.repo.mu.Lock()
	for i, call := range e.repo.calls {
		switch call.kind {
		case "due":
			lastDue = i
		case "publish":
			if firstPublish < 0 {
				firstPublish = i
			}
		}
	}
	e.repo.mu.Unlock()
	if lastDue < 0 || firstPublish < 0 || lastDue > firstPublish {
		t.Errorf("last due call at %d, first publish at %d: pages must all be fetched before any item runs", lastDue, firstPublish)
	}
	if e.repo.maxInflightBy["uid-a"] != 1 {
		t.Errorf("one author's items overlapped (max in flight %d): they must run one after another", e.repo.maxInflightBy["uid-a"])
	}
}

// Many authors run in parallel, bounded by SCHEDULED_SWEEP_CONCURRENCY, and an author's own items never overlap.
func TestSweep_BoundedConcurrencyAcrossAuthors(t *testing.T) {
	const authors, conc = 7, 4
	e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.Concurrency = conc })
	for a := 0; a < authors; a++ {
		for i := 0; i < 3; i++ {
			e.dueItem(fmt.Sprintf("uid-%d", a), a*10+i)
		}
	}
	// The first `conc` authors rendezvous inside the transaction: the run completes only if that many really are in
	// flight together. A sweep that serialised authors would hang here and fail on the timeout.
	var (
		mu      sync.Mutex
		arrived = map[string]bool{}
		release = make(chan struct{})
	)
	e.repo.publish = func(ctx context.Context, p PublishParams) (PublishResult, error) {
		mu.Lock()
		if !arrived[p.UID] && len(arrived) < conc {
			arrived[p.UID] = true
			if len(arrived) == conc {
				close(release)
			}
		}
		mu.Unlock()
		select {
		case <-release:
		case <-time.After(10 * time.Second):
			return PublishResult{}, errors.New("fewer than the configured workers ran at once")
		}
		return e.repo.publishDefault(ctx, p)
	}

	res, _, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Published != authors*3 || res.Transient != 0 {
		t.Fatalf("res = %+v, want %d published", res, authors*3)
	}
	if e.repo.maxInflight != conc {
		t.Errorf("max concurrent publishes = %d, want exactly %d", e.repo.maxInflight, conc)
	}
	for uid, n := range e.repo.maxInflightBy {
		if n != 1 {
			t.Errorf("%s had %d items in flight at once, want 1", uid, n)
		}
	}
}

func TestSweep_PathShapeAndUndecodableAreCountedNotProcessed(t *testing.T) {
	e := newSweepEnv(t)
	e.repo.bad, e.repo.undecodable = 2, 1
	e.dueItem("uid-alice", 1)

	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.SkippedBadPath != 2 || res.Undecodable != 1 || res.Due != 1 || res.Published != 1 {
		t.Errorf("res = %+v", res)
	}
	// They cost one read each in the query, every run.
	if c.Reads() != (1+2+1)+3 {
		t.Errorf("reads = %d, want 7", c.Reads())
	}
}

func TestSweep_MaxLatenessIsTheLargestAge(t *testing.T) {
	e := newSweepEnv(t)
	e.dueItem("uid-a", 1, func(p *ScheduledPost) { p.PublishAt = e.now.Add(-90 * time.Minute) })
	e.dueItem("uid-b", 1, func(p *ScheduledPost) { p.PublishAt = e.now.Add(-time.Minute) })
	res, _, err := e.sweep(context.Background())
	if err != nil || res.MaxLateness != 90*time.Minute {
		t.Fatalf("max lateness = %v err = %v, want 1h30m", res.MaxLateness, err)
	}
}

func TestSweep_DueQueryFailure(t *testing.T) {
	t.Run("page one fails: nothing runs, the error is returned for a 500", func(t *testing.T) {
		e := newSweepEnv(t)
		e.dueItem("uid-alice", 1)
		e.repo.dueErr, e.repo.dueErrAt = errors.New("rpc error: documents/users/uid-alice/scheduled/x unavailable"), 1
		res, _, err := e.sweep(context.Background())
		if err == nil || res.Outcome != SweepError {
			t.Fatalf("err = %v outcome = %q, want an error and outcome error", err, res.Outcome)
		}
		if strings.Contains(err.Error(), "uid-alice") {
			t.Errorf("the returned error names a uid: %v", err)
		}
		if len(e.repo.callsOf("publish")) != 0 {
			t.Error("an item ran although the query failed")
		}
	})
	t.Run("page two fails: page one is processed and the failure is in the result, not a returned error", func(t *testing.T) {
		e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.Limit = 1 })
		e.dueItem("uid-a", 1)
		e.dueItem("uid-b", 2)
		e.repo.dueErr, e.repo.dueErrAt = errors.New("unavailable"), 2
		res, _, err := e.sweep(context.Background())
		if err != nil || res.Outcome != SweepError || res.LaterPageErr == nil || res.Published != 1 {
			t.Fatalf("res = %+v err = %v, want page one published, outcome error and LaterPageErr set (no returned error: no retry)", res, err)
		}
	})
	t.Run("nothing due is one read and no error", func(t *testing.T) {
		e := newSweepEnv(t)
		res, c, err := e.sweep(context.Background())
		if err != nil || res.Outcome != SweepOK || res.Due != 0 || c.Reads() != 1 || c.Writes() != 0 {
			t.Fatalf("res = %+v err = %v reads = %d writes = %d, want ok with 1 read", res, err, c.Reads(), c.Writes())
		}
	})
}

func TestSweep_DeadlineGuard(t *testing.T) {
	t.Run("a second page is fetched only while 6 s remain", func(t *testing.T) {
		for _, tc := range []struct {
			left      time.Duration
			wantPages int
		}{{25 * time.Second, 2}, {6 * time.Second, 2}, {6*time.Second - 1, 1}, {time.Second, 1}} {
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.Limit, d.Limits.MaxPages = 1, 2 })
			e.svc.sweepTimeLeft = func(context.Context) time.Duration { return tc.left }
			e.dueItem("uid-a", 1)
			e.dueItem("uid-b", 2)
			_, _, err := e.sweep(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if e.repo.dueCalls != tc.wantPages {
				t.Errorf("with %v left: %d pages fetched, want %d", tc.left, e.repo.dueCalls, tc.wantPages)
			}
		}
	})
	t.Run("an item starts only while 6 s remain; the rest are deferred without a write", func(t *testing.T) {
		e := newSweepEnv(t)
		var calls atomic.Int64
		// One author, so the checks are sequential: the first item has time, then the budget runs out.
		e.svc.sweepTimeLeft = func(context.Context) time.Duration {
			if calls.Add(1) == 1 {
				return 20 * time.Second
			}
			return 5 * time.Second
		}
		for i := 1; i <= 3; i++ {
			e.dueItem("uid-a", i)
		}
		res, _, err := e.sweep(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if res.Published != 1 || res.Deferred != 2 {
			t.Errorf("res = %+v, want 1 published and 2 deferred", res)
		}
		if n := len(e.repo.callsOf("transition")) + len(e.repo.callsOf("bump")); n != 0 {
			t.Errorf("deferred items cost %d writes, want 0", n)
		}
	})
	t.Run("a cancelled run leaves the items PENDING and burns no attempt", func(t *testing.T) {
		e := newSweepEnv(t)
		it := e.dueItem("uid-a", 1)
		ctx, cancel := context.WithCancel(context.Background())
		e.repo.afterDue = cancel // the client hangs up after the query
		res, _, err := e.sweep(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if res.Deferred != 1 || res.Published != 0 || res.Transient != 0 {
			t.Errorf("res = %+v, want 1 deferred", res)
		}
		if got := e.repo.doc("uid-a", it.ID); got.Status != ScheduledPending || got.Attempts != 0 {
			t.Errorf("item = %+v, want untouched", got)
		}
	})
}

// The per-author counter is folded into the run's: the run line's fs_reads/fs_writes stay exact, and an author whose
// items spent more than SCHEDULED_AUTHOR_READS_WARN reads gets one warning with the one-way uid hash.
func TestSweep_AuthorReadsWarning(t *testing.T) {
	e := newSweepEnv(t)
	e.repo.publish = func(ctx context.Context, p PublishParams) (PublishResult, error) {
		reads := int64(40) // at the threshold: no warning
		if p.UID == "uid-heavy" {
			reads = 41
		}
		budget.FromContext(ctx).AddReads(reads)
		budget.FromContext(ctx).AddWrites(4)
		return PublishResult{Outcome: PublishNoop}, nil
	}
	e.dueItem("uid-heavy", 1)
	e.dueItem("uid-light", 2)

	_, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 2+41+40 || c.Writes() != 8 {
		t.Errorf("run cost = %d reads %d writes, want 83 and 8 (the author counters folded in)", c.Reads(), c.Writes())
	}
	warns := e.logs.lines(`"scheduled_author_reads"`)
	if len(warns) != 1 {
		t.Fatalf("scheduled_author_reads lines = %d, want 1: %v", len(warns), warns)
	}
	if !strings.Contains(warns[0], `"uid_hash":"`) || strings.Contains(warns[0], "uid-heavy") || !strings.Contains(warns[0], `"level":"WARN"`) {
		t.Errorf("warning = %s, want a WARN with only the uid hash", warns[0])
	}
}
