package media

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// Unit tests of the orphan sweep over fakes: the two phases, every verdict, the races (by precondition), redelivery,
// the bound and the failure paths.

var sweepNow = time.Date(2026, 11, 10, 3, 0, 0, 0, time.UTC)

type orphanEnv struct {
	repo     *fakeOrphanRepo
	obj      *fakeObjects
	drafts   *fakeDraftHolds
	profiles *fakeProfileImages
	sweeper  *OrphanSweeper
	n        int
}

func newOrphanEnv(t *testing.T, mode config.ProfileMediaRetire) *orphanEnv {
	t.Helper()
	e := &orphanEnv{
		repo: newFakeOrphanRepo(), obj: newFakeObjects(),
		drafts:   &fakeDraftHolds{held: map[string]map[string]bool{}},
		profiles: &fakeProfileImages{urls: map[string][]string{}},
	}
	s, err := NewOrphanSweeper(OrphanSweepDeps{Repo: e.repo, Objects: e.obj, Drafts: e.drafts, Profiles: e.profiles, RetireMode: mode})
	if err != nil {
		t.Fatal(err)
	}
	e.sweeper = s
	return e
}

// seed stores a READY image the way FinalizeUpload leaves it, due at checkAt (zero = no orphanCheckAt), with its two
// public objects in the fake bucket. It returns the id.
func (e *orphanEnv) seed(owner string, purpose Purpose, checkAt time.Time) string {
	e.n++
	id := fmt.Sprintf("%019d", 7_000_000_000_000_000_000+e.n)
	suffix := fmt.Sprintf("%032x", e.n)
	d := &Doc{
		ID: id, OwnerID: owner, Purpose: string(purpose), Status: string(StatusReady), ContentType: ContentTypeJPEG,
		UploadPath: uploadObject(owner, id, "jpg"), ThumbUploadPath: uploadThumbObject(owner, id, "jpg"), NameSuffix: suffix,
		PublicPath: publicObject(id, suffix, "jpg"), ThumbPath: publicThumbObject(id, suffix, "jpg"),
		CreatedAt: sweepNow.Add(-8 * 24 * time.Hour), UpdateTime: time.Unix(100, 0), OrphanCheckAt: optTime(checkAt),
	}
	e.repo.docs[id] = d
	e.obj.public[d.PublicPath] = ContentTypeJPEG
	e.obj.public[d.ThumbPath] = ContentTypeJPEG
	return id
}

func (e *orphanEnv) sweep(t *testing.T, at time.Time, limit int) OrphanSweepResult {
	t.Helper()
	res, err := e.sweeper.Sweep(context.Background(), at, limit)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	return res
}

func (e *orphanEnv) doc(id string) *Doc { return e.repo.docs[id] }

func (e *orphanEnv) publicCount(id string) int {
	n := 0
	for name := range e.obj.public {
		if o, ok := ParseObjectName(name); ok && o.ID == id {
			n++
		}
	}
	return n
}

func timeIs(p *time.Time, want time.Time) bool { return p != nil && p.Equal(want) }

func TestNewOrphanSweeper_RequiresDependencies(t *testing.T) {
	ok := OrphanSweepDeps{Repo: newFakeOrphanRepo(), Objects: newFakeObjects(), Drafts: &fakeDraftHolds{}, Profiles: &fakeProfileImages{}}
	for name, mut := range map[string]func(*OrphanSweepDeps){
		"repo": func(d *OrphanSweepDeps) { d.Repo = nil }, "objects": func(d *OrphanSweepDeps) { d.Objects = nil },
		"drafts": func(d *OrphanSweepDeps) { d.Drafts = nil }, "profiles": func(d *OrphanSweepDeps) { d.Profiles = nil },
	} {
		d := ok
		mut(&d)
		if _, err := NewOrphanSweeper(d); err == nil {
			t.Errorf("no %s: want an error", name)
		}
	}
	if _, err := NewOrphanSweeper(ok); err != nil {
		t.Fatal(err)
	}
}

// TestOrphanSweep_MarkThenDelete: phase 1 marks an unattached, unheld image and touches no object; a run before the grace
// ends sees nothing due; the run after deletes every object and the document; a further run (a redelivery) finds nothing.
func TestOrphanSweep_MarkThenDelete(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	d0 := *e.doc(id)

	res := e.sweep(t, sweepNow, 10)
	if res.Due != 1 || res.Marked != 1 || res.Deleted != 0 || res.More {
		t.Fatalf("run 1 = %+v, want one marked", res)
	}
	d := e.doc(id)
	if !timeIs(d.OrphanedAt, sweepNow) || !timeIs(d.OrphanCheckAt, sweepNow.Add(OrphanGrace)) {
		t.Fatalf("after the mark: orphanedAt=%v orphanCheckAt=%v", d.OrphanedAt, d.OrphanCheckAt)
	}
	if e.publicCount(id) != 2 || len(e.obj.deleted) != 0 {
		t.Fatalf("phase 1 touched objects: public=%d deleted=%v", e.publicCount(id), e.obj.deleted)
	}

	if res := e.sweep(t, sweepNow.Add(OrphanGrace-time.Second), 10); res.Due != 0 {
		t.Fatalf("a run inside the grace = %+v, want nothing due", res)
	}

	res = e.sweep(t, sweepNow.Add(OrphanGrace), 10)
	if res.Due != 1 || res.Deleted != 1 {
		t.Fatalf("run 2 = %+v, want one deleted", res)
	}
	if _, ok := e.repo.docs[id]; ok {
		t.Fatal("the document survived phase 2")
	}
	if e.publicCount(id) != 0 {
		t.Fatalf("public objects left: %v", e.obj.public)
	}
	// Every name the eraser would delete: both public shapes and the private leftovers.
	for _, name := range allPublicNames(&d0) {
		if !slices.Contains(e.obj.deleted, "p:"+name) {
			t.Errorf("public %s not deleted (deleted %v)", name, e.obj.deleted)
		}
	}
	for _, name := range []string{d0.UploadPath, d0.ThumbUploadPath} {
		if !slices.Contains(e.obj.deleted, "u:"+name) {
			t.Errorf("upload %s not deleted (deleted %v)", name, e.obj.deleted)
		}
	}

	// Redelivery (the cron retried, or ran again the same day): nothing left, nothing written.
	sets, dels := e.repo.sets, e.repo.deletes
	if res := e.sweep(t, sweepNow.Add(OrphanGrace+time.Hour), 10); res.Due != 0 {
		t.Fatalf("rerun = %+v", res)
	}
	if e.repo.sets != sets || e.repo.deletes != dels {
		t.Fatal("a rerun after completion wrote")
	}
}

// TestOrphanSweep_NotDueIsUntouched: a document without the field (attached, or published before the backfill) and one due
// later are never read as candidates.
func TestOrphanSweep_NotDueIsUntouched(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireAll)
	attached := e.seed(uidA, PurposePost, time.Time{})
	e.doc(attached).PostID = "1234567890123456789"
	later := e.seed(uidA, PurposePost, sweepNow.Add(time.Hour))
	res := e.sweep(t, sweepNow, 10)
	if res.Due != 0 || e.repo.sets != 0 || len(e.drafts.calls) != 0 {
		t.Fatalf("res=%+v sets=%d holder reads=%d, want nothing", res, e.repo.sets, len(e.drafts.calls))
	}
	if e.doc(attached).OrphanedAt != nil || e.doc(later).OrphanedAt != nil {
		t.Fatal("a document that is not due was marked")
	}
}

// TestOrphanSweep_Verdicts: one run, one document per case.
func TestOrphanSweep_Verdicts(t *testing.T) {
	due := sweepNow.Add(-time.Minute)
	tests := []struct {
		name  string
		mode  config.ProfileMediaRetire
		setup func(e *orphanEnv) string
		check func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult)
	}{
		{"post held by a draft is pushed by N", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			e.drafts.held[uidA] = map[string]bool{id: true}
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Held != 1 || e.doc(id).OrphanedAt != nil || !timeIs(e.doc(id).OrphanCheckAt, sweepNow.Add(OrphanAfter)) {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"post attached since the query is cleared", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			e.doc(id).PostID = "1234567890123456789"
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Attached != 1 || e.doc(id).OrphanCheckAt != nil || e.doc(id).OrphanedAt != nil || len(e.drafts.calls) != 0 {
				t.Fatalf("res=%+v doc=%+v holder reads=%v", res, e.doc(id), e.drafts.calls)
			}
		}},
		{"a document no longer published is cleared", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			e.doc(id).Status = string(StatusRejected)
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Attached != 1 || e.doc(id).OrphanCheckAt != nil {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a retired profile image is cleared (the retire step owns it)", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposeAvatar, due)
			r := sweepNow.Add(-time.Hour)
			e.doc(id).RetiredAt = &r
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Attached != 1 || e.doc(id).OrphanCheckAt != nil || e.profiles.reads != 0 {
				t.Fatalf("res=%+v doc=%+v reads=%d", res, e.doc(id), e.profiles.reads)
			}
		}},
		{"an avatar the profile shows is attached", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposeAvatar, due)
			d := e.doc(id)
			e.profiles.urls[uidA] = []string{"https://cdn.test/media/" + d.PublicPath, "https://cdn.test/media/" + d.ThumbPath}
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Attached != 1 || e.doc(id).OrphanCheckAt != nil || e.doc(id).OrphanedAt != nil || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a banner not shown is kept (leaves the queue) while PROFILE_MEDIA_RETIRE is off", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			return e.seed(uidA, PurposeBanner, due)
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Kept != 1 || e.doc(id).OrphanedAt != nil || e.doc(id).OrphanCheckAt != nil || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"an avatar not shown is kept under banner-only retire", config.ProfileMediaRetireBanner, func(e *orphanEnv) string {
			return e.seed(uidA, PurposeAvatar, due)
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Kept != 1 || e.doc(id).OrphanedAt != nil || e.doc(id).OrphanCheckAt != nil {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a banner not shown is marked under banner retire", config.ProfileMediaRetireBanner, func(e *orphanEnv) string {
			return e.seed(uidA, PurposeBanner, due)
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Marked != 1 || !timeIs(e.doc(id).OrphanedAt, sweepNow) || len(e.drafts.calls) != 0 {
				t.Fatalf("res=%+v doc=%+v drafts=%v", res, e.doc(id), e.drafts.calls)
			}
		}},
		{"an unknown purpose is kept", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			e.doc(id).Purpose = "FUTURE"
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Kept != 1 || e.doc(id).OrphanedAt != nil || e.doc(id).OrphanCheckAt != nil || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a marked image a draft holds at phase 2 is restored", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			m := sweepNow.Add(-OrphanGrace - time.Minute)
			e.doc(id).OrphanedAt = &m
			e.drafts.held[uidA] = map[string]bool{id: true}
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Restored != 1 || e.doc(id).OrphanedAt != nil || !timeIs(e.doc(id).OrphanCheckAt, sweepNow.Add(OrphanAfter)) || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a marked avatar the profile shows at phase 2 is attached", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposeAvatar, due)
			m := sweepNow.Add(-OrphanGrace - time.Minute)
			e.doc(id).OrphanedAt = &m
			e.profiles.urls[uidA] = []string{"https://cdn.test/media/" + e.doc(id).PublicPath}
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Attached != 1 || e.doc(id).OrphanedAt != nil || e.doc(id).OrphanCheckAt != nil || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a marked banner whose retire switch was turned off before phase 2 is restored and leaves the queue", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposeBanner, due)
			m := sweepNow.Add(-OrphanGrace - time.Minute)
			e.doc(id).OrphanedAt = &m
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			if res.Restored != 1 || e.doc(id).OrphanedAt != nil || e.doc(id).OrphanCheckAt != nil || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
		{"a marked image due before its grace ended waits", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			id := e.seed(uidA, PurposePost, due)
			m := sweepNow.Add(-time.Hour)
			e.doc(id).OrphanedAt = &m
			return id
		}, func(t *testing.T, e *orphanEnv, id string, res OrphanSweepResult) {
			m := sweepNow.Add(-time.Hour)
			if res.Waiting != 1 || !timeIs(e.doc(id).OrphanCheckAt, m.Add(OrphanGrace)) || !timeIs(e.doc(id).OrphanedAt, m) || e.publicCount(id) != 2 {
				t.Fatalf("res=%+v doc=%+v", res, e.doc(id))
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newOrphanEnv(t, tt.mode)
			id := tt.setup(e)
			res := e.sweep(t, sweepNow, 10)
			if res.Due != 1 {
				t.Fatalf("due = %d", res.Due)
			}
			tt.check(t, e, id, res)
		})
	}
}

// TestOrphanSweep_AttachWinsTheRaceWithTheMark: the attach commits between the due query and the mark. The mark's
// precondition fails, nothing is marked or deleted, and the next run finds nothing due (Attach removed the field).
func TestOrphanSweep_AttachWinsTheRaceWithTheMark(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.repo.beforeSet = func(got string) {
		if got == id {
			e.repo.beforeSet = nil
			e.repo.attach(id, "1234567890123456789")
		}
	}
	res := e.sweep(t, sweepNow, 10)
	if res.Conflicts != 1 || res.Marked != 0 {
		t.Fatalf("res = %+v, want one conflict", res)
	}
	d := e.doc(id)
	if d.OrphanedAt != nil || d.PostID == "" || e.publicCount(id) != 2 {
		t.Fatalf("doc = %+v public=%d: the attach must win", d, e.publicCount(id))
	}
	if res := e.sweep(t, sweepNow.Add(OrphanGrace), 10); res.Due != 0 {
		t.Fatalf("after the attach = %+v, want nothing due", res)
	}
}

// TestOrphanSweep_ConcurrentRunLosesTheClaim: two runs read the same marked document; the one that loses the claim
// deletes no object.
func TestOrphanSweep_ConcurrentRunLosesTheClaim(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	m := sweepNow.Add(-OrphanGrace - time.Hour)
	e.doc(id).OrphanedAt = &m
	e.repo.beforeSet = func(got string) {
		e.repo.beforeSet = nil
		e.repo.mu.Lock()
		e.repo.docs[got].UpdateTime = e.repo.docs[got].UpdateTime.Add(time.Second) // the other run's claim committed first
		e.repo.mu.Unlock()
	}
	res := e.sweep(t, sweepNow, 10)
	if res.Conflicts != 1 || res.Deleted != 0 || len(e.obj.deleted) != 0 || e.doc(id) == nil {
		t.Fatalf("res=%+v deleted=%v: a lost claim must not delete", res, e.obj.deleted)
	}
}

// TestOrphanSweep_CrashAfterTheClaimResumes: the object delete fails after the claim; the document stays marked with its
// check pushed to the end of a new grace, and the run after it completes.
func TestOrphanSweep_CrashAfterTheClaimResumes(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	m := sweepNow.Add(-OrphanGrace - time.Hour)
	e.doc(id).OrphanedAt = &m
	e.obj.deletePub = errors.New("gcs down")
	res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
	if err == nil || res.Failed != 1 {
		t.Fatalf("res=%+v err=%v, want one failure", res, err)
	}
	d := e.doc(id)
	if d == nil || !timeIs(d.OrphanedAt, m) || !timeIs(d.OrphanCheckAt, sweepNow.Add(OrphanGrace)) {
		t.Fatalf("doc = %+v, want still marked and due after a new grace", d)
	}
	e.obj.deletePub = nil
	if res := e.sweep(t, sweepNow.Add(OrphanGrace), 10); res.Deleted != 1 || e.doc(id) != nil {
		t.Fatalf("resumed run = %+v", res)
	}
}

// TestOrphanSweep_HolderErrorWritesNothingForThatOwner: an unknown hold is never read as free; other owners still run.
func TestOrphanSweep_HolderErrorWritesNothingForThatOwner(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireAll)
	post := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	avatar := e.seed(uidB, PurposeAvatar, sweepNow.Add(-time.Minute))
	e.drafts.err = errors.New("firestore unavailable")
	res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
	if err == nil || res.Failed != 1 || res.Marked != 1 {
		t.Fatalf("res=%+v err=%v, want uidA failed and uidB marked", res, err)
	}
	if e.doc(post).OrphanedAt != nil || !timeIs(e.doc(post).OrphanCheckAt, sweepNow.Add(-time.Minute)) {
		t.Fatalf("the failed owner's document was written: %+v", e.doc(post))
	}
	if e.doc(avatar).OrphanedAt == nil {
		t.Fatal("the other owner was not swept")
	}

	e2 := newOrphanEnv(t, config.ProfileMediaRetireAll)
	id := e2.seed(uidA, PurposeBanner, sweepNow.Add(-time.Minute))
	e2.profiles.err = errors.New("users read failed")
	if res, err := e2.sweeper.Sweep(context.Background(), sweepNow, 10); err == nil || res.Failed != 1 || e2.doc(id).OrphanedAt != nil {
		t.Fatalf("profile read failure: res=%+v err=%v", res, err)
	}
}

// TestOrphanSweep_WriteErrorIsCounted: a failed write (not a conflict) fails the document and returns the error.
func TestOrphanSweep_WriteErrorIsCounted(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.repo.setErr = errors.New("deadline exceeded")
	if res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10); err == nil || res.Failed != 1 {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

// TestOrphanSweep_TheLimitBoundsTheRun: limit 2 of 5 due reads 2 (oldest first), reports More, and one holder read per
// owner in the page.
func TestOrphanSweep_TheLimitBoundsTheRun(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	var ids []string
	for i := range 5 {
		ids = append(ids, e.seed(uidA, PurposePost, sweepNow.Add(-time.Duration(5-i)*time.Hour)))
	}
	res := e.sweep(t, sweepNow, 2)
	if res.Due != 2 || res.Marked != 2 || !res.More {
		t.Fatalf("res = %+v, want 2 marked and more", res)
	}
	if !slices.Equal(e.repo.dueLimits, []int{2}) || len(e.drafts.calls) != 1 {
		t.Fatalf("due limits %v, holder reads %v: want one query of 2 and one read for the one owner", e.repo.dueLimits, e.drafts.calls)
	}
	for i, id := range ids {
		if marked := e.doc(id).OrphanedAt != nil; marked != (i < 2) {
			t.Errorf("doc %d marked=%v, want only the two oldest", i, marked)
		}
	}
	if res := e.sweep(t, sweepNow, 10); res.Due != 3 || res.Marked != 3 || res.More {
		t.Fatalf("second page = %+v", res)
	}
}

// TestOrphanSweep_DeadlineSkips: a context already over starts no owner.
func TestOrphanSweep_DeadlineSkips(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.seed(uidB, PurposePost, sweepNow.Add(-time.Minute))
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res, err := e.sweeper.Sweep(ctx, sweepNow, 10)
	if err == nil || res.Skipped != 2 || e.repo.sets != 0 {
		t.Fatalf("res=%+v err=%v sets=%d", res, err, e.repo.sets)
	}
}

// TestOrphanSweep_PanicInAWorkerIsAFailure: a panic in one owner's work fails that owner and never ends the process.
func TestOrphanSweep_PanicInAWorkerIsAFailure(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.repo.beforeSet = func(string) { panic("boom") }
	res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
	if err == nil || res.Failed != 1 {
		t.Fatalf("res=%+v err=%v", res, err)
	}
}

// TestFinalize_SetsOrphanCheckAtOnReadyOnly: READY gets readyAt + OrphanAfter; REJECTED gets none.
func TestFinalize_SetsOrphanCheckAtOnReadyOnly(t *testing.T) {
	e := newEnv(t, envOpts{})
	ok := e.upload(t, uidA, PurposePost, "ok")
	bad := e.upload(t, uidA, PurposePost, "bad")
	e.mod.by[uploadObject(uidA, bad.MediaID, "jpg")] = SafeSearch{Adult: LikelihoodVeryLikely}
	if _, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: ok.MediaID}, {MediaID: bad.MediaID}}); err != nil {
		t.Fatal(err)
	}
	if d := e.repo.docs[ok.MediaID]; d.Status != string(StatusReady) || !timeIs(d.OrphanCheckAt, testNow.Add(OrphanAfter)) {
		t.Fatalf("READY doc orphanCheckAt = %v, want %v", d.OrphanCheckAt, testNow.Add(OrphanAfter))
	}
	if d := e.repo.docs[bad.MediaID]; d.Status != string(StatusRejected) || d.OrphanCheckAt != nil {
		t.Fatalf("REJECTED doc = %s orphanCheckAt %v, want none", d.Status, d.OrphanCheckAt)
	}
}

// TestOrphanedDocsAreRefused: the mark makes the article cover preview refuse the image (the avatar and banner resolvers
// and LoadForPost are covered over the real repo in the integration test).
func TestOrphanedDocsAreRefused(t *testing.T) {
	m := sweepNow
	d := &Doc{OwnerID: uidA, Purpose: string(PurposePost), Status: string(StatusReady), ContentType: ContentTypeJPEG}
	if !usablePostCover(d, uidA) {
		t.Fatal("an unmarked image must be a usable cover")
	}
	d.OrphanedAt = &m
	if usablePostCover(d, uidA) || !d.Orphaned() {
		t.Fatal("a marked image must not be a usable cover")
	}
}
