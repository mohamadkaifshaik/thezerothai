package posts

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// Unit tests of the media hold (pending 2.15, security review of #289 Low 2): while FEATURE_MEDIA is globally off the sweep
// leaves items that carry images PENDING, with no read and no write, instead of attaching images CreatePost would refuse.

// withImages gives the item's draft images with the sweepMediaID(n) ids.
func withImages(ns ...int) func(*ScheduledPost) {
	return func(p *ScheduledPost) {
		for _, n := range ns {
			p.Draft.Media = append(p.Draft.Media, MediaRef{ID: sweepMediaID(n)})
		}
	}
}

// mediaOffEnv is a sweep env whose checker has FEATURE_MEDIA globally off. The returned map is the checker: delete the key
// to switch media back on between two runs.
func mediaOffEnv(t *testing.T, mut ...func(*SweepDeps, *sweepEnv)) (*sweepEnv, sweepFlags) {
	t.Helper()
	fl := sweepFlags{mediaFlagName: true}
	mut = append([]func(*SweepDeps, *sweepEnv){func(d *SweepDeps, _ *sweepEnv) { d.Flags = fl }}, mut...)
	return newSweepEnv(t, mut...), fl
}

func TestSweepMediaHold_HeldItemIsLeftUntouched(t *testing.T) {
	e, _ := mediaOffEnv(t)
	it := e.dueItem("uid-alice", 1, withImages(1, 2))
	queried := e.repo.doc("uid-alice", it.ID)

	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != SweepOK || res.Due != 1 || res.HeldMedia != 1 || res.Published != 0 || res.Deferred != 0 || res.Transient != 0 ||
		res.Noop != 0 || res.WriteFailed != 0 || len(res.Failed) != 0 || res.Cancelled != 0 {
		t.Fatalf("res = %+v, want one due item, all of it in HeldMedia", res)
	}
	// A held item is still a due item: it counts toward the oldest lateness (item 1 is due 10 minutes minus 1 s ago), which
	// is what makes max_lateness_ms rise during a hold (runbook, "Images held while FEATURE_MEDIA is off").
	if want := 10*time.Minute - time.Second; res.MaxLateness != want {
		t.Errorf("MaxLateness = %v, want %v: held items must count", res.MaxLateness, want)
	}
	// The due query's one read and nothing else: no transaction, no state write, no attempt.
	if c.Reads() != 1 || c.Writes() != 0 {
		t.Errorf("cost = %d reads %d writes, want the query's 1 read and 0 writes", c.Reads(), c.Writes())
	}
	for _, kind := range []string{"publish", "transition", "bump"} {
		if n := len(e.repo.callsOf(kind)); n != 0 {
			t.Errorf("%d %s calls for a held item, want 0", n, kind)
		}
	}
	got := e.repo.doc("uid-alice", it.ID)
	if got.Status != ScheduledPending || got.Attempts != 0 || got.Draft == nil || len(got.Draft.Media) != 2 || !got.UpdateTime.Equal(queried.UpdateTime) {
		t.Errorf("stored item = %+v, want it exactly as the query read it (PENDING, attempts 0, draft kept, same UpdateTime)", got)
	}
	if n := len(e.logs.lines(`"scheduled_item_start"`)); n != 0 {
		t.Errorf("%d scheduled_item_start lines, want 0: no item was started", n)
	}
	if len(e.events.created) != 0 {
		t.Errorf("%d post events for a held item", len(e.events.created))
	}
}

// The held items are older than their author's text items, so a filter placed after the per-author cap would let the
// three image items take all three slots and defer the text items; filtered before it, the text items publish.
func TestSweepMediaHold_HeldItemsDoNotUseTheAuthorCap(t *testing.T) {
	e, _ := mediaOffEnv(t)
	var img, txt []*ScheduledPost
	for n := 1; n <= 3; n++ {
		img = append(img, e.dueItem("uid-alice", n, withImages(n)))
	}
	for n := 4; n <= 6; n++ {
		txt = append(txt, e.dueItem("uid-alice", n))
	}
	bob := e.dueItem("uid-bob", 7)

	res, _, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Due != 7 || res.HeldMedia != 3 || res.Published != 4 || res.Deferred != 0 {
		t.Fatalf("res = %+v, want 7 due: 3 held, 4 published (alice's 3 text items and bob's), 0 deferred", res)
	}
	for _, it := range txt {
		if got := e.repo.doc("uid-alice", it.ID).Status; got != ScheduledPublished {
			t.Errorf("alice's text item %s status = %v, want PUBLISHED: the held items must not use her cap", it.ID[:6], got)
		}
	}
	if got := e.repo.doc("uid-bob", bob.ID).Status; got != ScheduledPublished {
		t.Errorf("bob's item status = %v, want PUBLISHED", got)
	}
	for _, it := range img {
		if got := e.repo.doc("uid-alice", it.ID); got.Status != ScheduledPending || got.Attempts != 0 {
			t.Errorf("held item = %+v, want PENDING and untouched", got)
		}
	}
	if n := len(e.repo.callsOf("transition")) + len(e.repo.callsOf("bump")); n != 0 {
		t.Errorf("%d bookkeeping writes in a run that only held and published, want 0", n)
	}
}

// The checks that never depended on the flag keep their verdict, in the order of the unheld path: a held item cannot
// outlive SCHEDULED_MAX_LATENESS, and an item that could never publish is retired now, not held.
func TestSweepMediaHold_PermanentVerdictsStillApply(t *testing.T) {
	tests := []struct {
		name     string
		mut      func(e *sweepEnv, p *ScheduledPost)
		wantFail ScheduledFailure // "" = held
	}{
		{"older than the lateness bound: expired", func(e *sweepEnv, p *ScheduledPost) { p.PublishAt = e.now.Add(-6*time.Hour - time.Second) }, FailureExpired},
		{"exactly at the bound: still held", func(e *sweepEnv, p *ScheduledPost) { p.PublishAt = e.now.Add(-6 * time.Hour) }, ""},
		{"expiry is decided before the schema version", func(e *sweepEnv, p *ScheduledPost) {
			p.PublishAt = e.now.Add(-7 * time.Hour)
			p.SchemaVersion = 2
		}, FailureExpired},
		{"a higher schema version is unsupported, not held", func(_ *sweepEnv, p *ScheduledPost) { p.SchemaVersion = 2 }, FailureUnsupported},
		{"text that no longer parses is invalid, not held", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Text = "a\x00b" }, FailureInvalidContent},
		{"a reply policy this revision does not know is invalid, not held", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.ReplyPolicy = "NOBODY" }, FailureInvalidContent},
		{"a media id that is not a media id is invalid, not held", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Media = []MediaRef{{ID: "m1"}} }, FailureInvalidContent},
		{"an image-only post is valid, so held", func(_ *sweepEnv, p *ScheduledPost) { p.Draft.Text = "" }, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e, _ := mediaOffEnv(t)
			it := e.dueItem("uid-alice", 1, withImages(1), func(p *ScheduledPost) { tc.mut(e, p) })

			res, c, err := e.sweep(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if n := len(e.repo.callsOf("publish")); n != 0 {
				t.Errorf("the publish transaction ran %d times", n)
			}
			got := e.repo.doc("uid-alice", it.ID)
			if tc.wantFail == "" {
				if res.HeldMedia != 1 || len(res.Failed) != 0 || got.Status != ScheduledPending || c.Writes() != 0 {
					t.Errorf("res = %+v item = %+v writes = %d, want it held: PENDING, 0 writes", res, got, c.Writes())
				}
				return
			}
			if res.HeldMedia != 0 || res.Failed[tc.wantFail] != 1 || got.Status != ScheduledFailed || got.Failure != tc.wantFail || c.Reads() != 1 || c.Writes() != 1 {
				t.Errorf("res = %+v item = %+v cost = %d/%d, want FAILED %s with the usual 1 read 1 write and nothing held", res, got, c.Reads(), c.Writes(), tc.wantFail)
			}
		})
	}
}

// Nothing special happens when the flag returns: the next run publishes the held item like any other, attempts untouched.
func TestSweepMediaHold_PublishesNormallyOnceMediaIsBackOn(t *testing.T) {
	e, fl := mediaOffEnv(t)
	it := e.dueItem("uid-alice", 1, withImages(1, 2))

	if res, _, err := e.sweep(context.Background()); err != nil || res.HeldMedia != 1 || res.Published != 0 {
		t.Fatalf("first run: res = %+v err = %v, want it held", res, err)
	}
	if n := len(e.repo.callsOf("publish")); n != 0 {
		t.Fatalf("publish calls while held = %d", n)
	}

	delete(fl, mediaFlagName) // FEATURE_MEDIA is on again
	res, c, err := e.sweep(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.HeldMedia != 0 || res.Published != 1 || res.Due != 1 || len(res.Failed) != 0 {
		t.Fatalf("second run: res = %+v, want 1 published and nothing held", res)
	}
	if c.Reads() != 1+3 || c.Writes() != 4 {
		t.Errorf("second run cost = %d reads %d writes, want the ordinary 4 and 4", c.Reads(), c.Writes())
	}
	if got := e.repo.doc("uid-alice", it.ID); got.Status != ScheduledPublished || got.PostID == "" || got.Attempts != 0 {
		t.Errorf("stored item = %+v, want PUBLISHED with attempts 0", got)
	}
	if ps := e.repo.params; len(ps) != 1 || len(ps[0].MediaIDs) != 2 {
		t.Errorf("publish params = %+v, want one transaction carrying both images", ps)
	}
}

// Only the kill switch holds: an allowlist or percent rollout of media is not "globally off", exactly as for the
// scheduling flags. An unregistered name counts as off (Registry.GloballyOff), which is why the wiring registers media.
func TestSweepMediaHold_OnlyTheKillSwitchHolds(t *testing.T) {
	tests := []struct {
		name        string
		media       *flags.Spec // nil: media is not registered at all
		wantHeld    int
		wantPublish int
		wantOutcome string
	}{
		{"off", &flags.Spec{Name: mediaFlagName, Mode: flags.Off}, 1, 0, SweepOK},
		{"not registered is off", nil, 1, 0, SweepOK},
		{"allowlist, empty", &flags.Spec{Name: mediaFlagName, Mode: flags.Allowlist}, 0, 1, SweepOK},
		{"allowlist without the author", &flags.Spec{Name: mediaFlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{"someone-else": {}}}, 0, 1, SweepOK},
		{"percent 0", &flags.Spec{Name: mediaFlagName, Mode: flags.Percent, Percent: 0}, 0, 1, SweepOK},
		{"on", &flags.Spec{Name: mediaFlagName, Mode: flags.On}, 0, 1, SweepOK},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			specs := []flags.Spec{{Name: FlagName, Mode: flags.On}, {Name: ScheduledPostsFlagName, Mode: flags.On}}
			if tc.media != nil {
				specs = append(specs, *tc.media)
			}
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Flags = flags.NewRegistry(specs...) })
			e.dueItem("uid-alice", 1, withImages(1))

			res, _, err := e.sweep(context.Background())
			if err != nil || res.Outcome != tc.wantOutcome || res.HeldMedia != tc.wantHeld || res.Published != tc.wantPublish {
				t.Fatalf("res = %+v err = %v, want %d held and %d published", res, err, tc.wantHeld, tc.wantPublish)
			}
		})
	}
}

// The no-op cases come first and keep their meaning: no checker, a scheduling flag off or read-only mode end the run with
// 0 reads before anything is classified, whatever the media flag says.
func TestSweepMediaHold_NoOpCasesAreUnchanged(t *testing.T) {
	tests := []struct {
		name     string
		flags    GloballyOffChecker
		readOnly bool
		want     string
	}{
		{"no flag checker", nil, false, SweepFlagOff},
		{"scheduled_posts off as well", sweepFlags{mediaFlagName: true, ScheduledPostsFlagName: true}, false, SweepFlagOff},
		{"read-only mode", sweepFlags{mediaFlagName: true}, true, SweepDegraded},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := newSweepEnv(t, func(d *SweepDeps, _ *sweepEnv) { d.Flags, d.ReadOnly = tc.flags, tc.readOnly })
			e.dueItem("uid-alice", 1, withImages(1))

			res, c, err := e.sweep(context.Background())
			if err != nil || res.Outcome != tc.want || res.HeldMedia != 0 || res.Due != 0 || c.Reads() != 0 || c.Writes() != 0 || e.repo.dueCalls != 0 {
				t.Errorf("res = %+v err = %v reads = %d writes = %d due calls = %d, want outcome %q and nothing touched", res, err, c.Reads(), c.Writes(), e.repo.dueCalls, tc.want)
			}
		})
	}
}

// With media on (the common case) nothing changes for an item with images, and a text item is never classified as held.
func TestSweepMediaHold_MediaOnHoldsNothing(t *testing.T) {
	e := newSweepEnv(t) // sweepFlags{}: nothing is off
	e.dueItem("uid-alice", 1, withImages(1))
	e.dueItem("uid-alice", 2)
	res, _, err := e.sweep(context.Background())
	if err != nil || res.HeldMedia != 0 || res.Published != 2 {
		t.Fatalf("res = %+v err = %v, want both published, none held", res, err)
	}
}

// The scheduled_sweep line carries the count and, as ever, no id, handle or text.
func TestSweepMediaHold_RunLineCountsHeldItemsAndLeaksNothing(t *testing.T) {
	e, _ := mediaOffEnv(t)
	it := e.dueItem("uid-alice", 1, withImages(1), func(p *ScheduledPost) { p.Draft.Text = "secret draft text" })
	e.dueItem("uid-alice", 2, withImages(2))

	h := NewSweepHandler(e.svc, slog.New(slog.NewJSONHandler(e.logs, nil)), "demo-project")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/cron/publish-scheduled", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rec.Code)
	}
	lines := e.logs.lines(`"msg":"scheduled_sweep"`)
	if len(lines) != 1 {
		t.Fatalf("scheduled_sweep lines = %d, want 1:\n%s", len(lines), e.logs.String())
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &m); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]float64{"held_media": 2, "due": 2, "published": 0, "deferred": 0, "noop": 0, "fs_reads": 2, "fs_writes": 0, "failed_total": 0, "max_lateness_ms": 599000} {
		if got, ok := m[k].(float64); !ok || got != want {
			t.Errorf("%s = %v, want %v", k, m[k], want)
		}
	}
	if m["outcome"] != "ok" {
		t.Errorf("outcome = %v, want ok", m["outcome"])
	}
	for _, leak := range []string{"uid-alice", it.ID, "secret draft text", sweepMediaID(1)} {
		if strings.Contains(e.logs.String(), leak) {
			t.Errorf("the logs contain %q", leak)
		}
	}
}

// TestSweepMediaHold_KnownLimit_HeldItemsFillTheWindow PINS A KNOWN LIMIT of this PR; it describes behaviour nobody wants.
// Held items are never written, so they keep their place at the head of the due query (ORDER BY publishAt) until they
// expire, and they are filtered before the per-author cap, so a few authors' held items can fill the whole window
// (SCHEDULED_SWEEP_LIMIT x SCHEDULED_SWEEP_MAX_PAGES = 100). Every newer due item, text-only ones of uninvolved users
// included, is then not read at all. Adaptive paging is tracked as a follow-up; when it lands, this test is the one to
// change. Operator guidance: docs/runbooks/posts.md section 12, "Known limit".
func TestSweepMediaHold_KnownLimit_HeldItemsFillTheWindow(t *testing.T) {
	// 4 authors x 25 held image items (SCHEDULED_MAX_PENDING), all older than one text-only item of a fifth author.
	setup := func(t *testing.T, mut ...func(*SweepDeps, *sweepEnv)) (*sweepEnv, *ScheduledPost) {
		t.Helper()
		e, _ := mediaOffEnv(t, mut...)
		for a := 0; a < 4; a++ {
			for n := 1; n <= 25; n++ {
				e.dueItem(fmt.Sprintf("uid-held-%d", a), n, withImages(n))
			}
		}
		return e, e.dueItem("uid-late", 100)
	}

	t.Run("default window: the newer text-only item is not read, not published and not touched", func(t *testing.T) {
		e, late := setup(t)
		queried := e.repo.doc("uid-late", late.ID)

		res, c, err := e.sweep(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if res.Due != 100 || res.HeldMedia != 100 || res.Published != 0 || res.Deferred != 0 || len(res.Failed) != 0 {
			t.Fatalf("res = %+v, want the window (100 due) entirely held and nothing published: the symptom the runbook names", res)
		}
		if e.repo.dueCalls != 2 || c.Reads() != 100 || c.Writes() != 0 || len(e.repo.callsOf("publish")) != 0 {
			t.Errorf("due calls %d reads %d writes %d publishes %d, want 2 pages of 50, 100 reads, nothing else", e.repo.dueCalls, c.Reads(), c.Writes(), len(e.repo.callsOf("publish")))
		}
		if got := e.repo.doc("uid-late", late.ID); got.Status != ScheduledPending || !got.UpdateTime.Equal(queried.UpdateTime) {
			t.Errorf("the text-only item = %+v, want it untouched (it was never read)", got)
		}
	})

	t.Run("window raised past the held items: the text-only item publishes", func(t *testing.T) {
		e, late := setup(t, func(d *SweepDeps, _ *sweepEnv) { d.Limits.MaxPages = 3 })

		res, _, err := e.sweep(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if res.Due != 101 || res.HeldMedia != 100 || res.Published != 1 {
			t.Fatalf("res = %+v, want 101 due: 100 held and the text-only item published", res)
		}
		if got := e.repo.doc("uid-late", late.ID); got.Status != ScheduledPublished {
			t.Errorf("the text-only item status = %v, want PUBLISHED", got.Status)
		}
	})
}

// posts checks three flags by name, and Registry.GloballyOff is TRUE for a name it does not know. A drift between a name
// here and the spec the config registers would therefore silently stop the sweep (flag_off) or, for media, hold every
// image item. The registry is built from these specs in apiserver.Build.
func TestSweepMediaHold_FlagNamesMatchTheRegisteredSpecs(t *testing.T) {
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		flag, specName, name string
	}{
		{"FEATURE_POSTS", cfg.FeaturePosts.Name, FlagName},
		{"FEATURE_SCHEDULED_POSTS", cfg.FeatureScheduledPosts.Name, ScheduledPostsFlagName},
		{"FEATURE_MEDIA (config spec)", cfg.FeatureMedia.Name, mediaFlagName},
		{"FEATURE_MEDIA (media module)", media.FlagName, mediaFlagName},
	}
	for _, tc := range tests {
		if tc.specName != tc.name {
			t.Errorf("%s: the registered spec is named %q but posts checks %q", tc.flag, tc.specName, tc.name)
		}
	}
}
