package media

import (
	"context"
	"errors"
	"maps"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// Regression tests for the 2026-11-11 review of the orphan sweep: a claimed document is never restored, a fresh upload is
// never marked by a fast clock, a holder-read error does not stall the head of the queue, and a run cut by its own
// deadline counts what it did not finish as skipped, not failed.

// TestOrphanSweep_ClaimedDocIsFinishedNeverRestored: phase 2 claims and deletes the objects, then the document delete
// fails. A holder appears before the next run. The next run must finish the delete (the objects are gone; restoring
// would leave a usable document that names missing objects), whatever the holders say.
func TestOrphanSweep_ClaimedDocIsFinishedNeverRestored(t *testing.T) {
	tests := []struct {
		name  string
		mode  config.ProfileMediaRetire
		seed  func(e *orphanEnv) string
		holds func(e *orphanEnv, id string)
	}{
		{"post image a draft holds after the claim", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			return e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
		}, func(e *orphanEnv, id string) { e.drafts.held[uidA] = map[string]bool{id: true} }},
		{"avatar the profile shows after the claim", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			return e.seed(uidA, PurposeAvatar, sweepNow.Add(-time.Minute))
		}, func(e *orphanEnv, id string) {
			e.profiles.urls[uidA] = []string{"https://cdn.test/media/" + e.doc(id).PublicPath}
		}},
		{"avatar whose retire switch was turned off after the claim", config.ProfileMediaRetireAll, func(e *orphanEnv) string {
			return e.seed(uidA, PurposeAvatar, sweepNow.Add(-time.Minute))
		}, func(e *orphanEnv, _ string) {
			e.sweeper.d.RetireMode = config.ProfileMediaRetireOff
		}},
		{"post image a draft holds and whose holder read now fails", config.ProfileMediaRetireOff, func(e *orphanEnv) string {
			return e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
		}, func(e *orphanEnv, _ string) { e.drafts.err = errors.New("firestore unavailable") }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newOrphanEnv(t, tt.mode)
			id := tt.seed(e)
			m := sweepNow.Add(-OrphanGrace - time.Hour)
			e.doc(id).OrphanedAt = &m
			e.repo.deleteErr = errors.New("deadline exceeded")

			res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
			if err == nil || res.Failed != 1 || res.Deleted != 0 {
				t.Fatalf("run 1 = %+v, %v: want the document delete to fail", res, err)
			}
			if e.publicCount(id) != 0 || e.doc(id) == nil {
				t.Fatalf("after run 1: public=%d doc=%+v, want objects gone and the document left", e.publicCount(id), e.doc(id))
			}
			if !e.doc(id).Orphaned() {
				t.Fatal("a claimed document must stay refused")
			}

			e.repo.deleteErr = nil
			tt.holds(e, id)
			res, _ = e.sweeper.Sweep(context.Background(), sweepNow.Add(OrphanGrace), 10)
			if res.Deleted != 1 || res.Restored != 0 || res.Attached != 0 || res.Held != 0 || res.Kept != 0 {
				t.Fatalf("run 2 = %+v, want the delete finished, never a restore", res)
			}
			if e.doc(id) != nil {
				t.Fatalf("the claimed document survived: %+v", e.doc(id))
			}
		})
	}
}

// TestOrphanSweep_ClockSanity: a candidate whose own createdAt is less than OrphanAfter before the sweep's clock is never
// marked (a workstation clock ahead of the server's could otherwise mark a fresh upload); its check moves to
// createdAt + OrphanAfter. One just old enough is marked.
func TestOrphanSweep_ClockSanity(t *testing.T) {
	tests := []struct {
		name       string
		created    time.Time
		wantMarked bool
	}{
		{"created a minute ago", sweepNow.Add(-time.Minute), false},
		{"created one second short of N", sweepNow.Add(-OrphanAfter + time.Second), false},
		{"created exactly N ago", sweepNow.Add(-OrphanAfter), true},
		{"created long ago", sweepNow.Add(-30 * 24 * time.Hour), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newOrphanEnv(t, config.ProfileMediaRetireOff)
			id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
			e.doc(id).CreatedAt = tt.created
			res := e.sweep(t, sweepNow, 10)
			if marked := e.doc(id).OrphanedAt != nil; marked != tt.wantMarked {
				t.Fatalf("res=%+v marked=%v, want %v", res, marked, tt.wantMarked)
			}
			if !tt.wantMarked && !timeIs(e.doc(id).OrphanCheckAt, tt.created.Add(OrphanAfter)) {
				t.Fatalf("orphanCheckAt = %v, want createdAt + N = %v", e.doc(id).OrphanCheckAt, tt.created.Add(OrphanAfter))
			}
		})
	}
	// Phase 2 too: a document marked (by a clock far ahead) before it was N old is not deleted.
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	id := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.doc(id).CreatedAt = sweepNow.Add(-time.Hour)
	m := sweepNow.Add(-OrphanGrace - time.Hour)
	e.doc(id).OrphanedAt = &m
	if res := e.sweep(t, sweepNow, 10); res.Deleted != 0 || e.doc(id) == nil || e.publicCount(id) != 2 {
		t.Fatalf("phase 2 on a young document = %+v", res)
	}
}

// TestOrphanSweep_HolderErrorPostponesThatOwner: an owner whose holders cannot be read is never marked, but its due
// documents move a day forward (a precondition write, the mark untouched) so they do not hold the head of the queue; the
// failure is still counted and returned.
func TestOrphanSweep_HolderErrorPostponesThatOwner(t *testing.T) {
	tests := []struct {
		name    string
		purpose Purpose
		marked  bool
		fail    func(e *orphanEnv)
	}{
		{"draft holders fail", PurposePost, false, func(e *orphanEnv) { e.drafts.err = errors.New("unavailable") }},
		{"draft holders fail on a marked image", PurposePost, true, func(e *orphanEnv) { e.drafts.err = errors.New("unavailable") }},
		{"profile read fails", PurposeAvatar, false, func(e *orphanEnv) { e.profiles.err = errors.New("unavailable") }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newOrphanEnv(t, config.ProfileMediaRetireAll)
			id := e.seed(uidA, tt.purpose, sweepNow.Add(-time.Minute))
			var m time.Time
			if tt.marked {
				m = sweepNow.Add(-OrphanGrace - time.Hour)
				e.doc(id).OrphanedAt = &m
			}
			tt.fail(e)
			res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
			if err == nil || res.Failed != 1 || res.Marked != 0 || res.Deleted != 0 {
				t.Fatalf("res=%+v err=%v, want one failure and no mark", res, err)
			}
			d := e.doc(id)
			if !timeIs(d.OrphanCheckAt, sweepNow.Add(orphanHolderRetry)) {
				t.Fatalf("orphanCheckAt = %v, want pushed to %v", d.OrphanCheckAt, sweepNow.Add(orphanHolderRetry))
			}
			if tt.marked != (d.OrphanedAt != nil) || (tt.marked && !timeIs(d.OrphanedAt, m)) {
				t.Fatalf("orphanedAt = %v, want unchanged", d.OrphanedAt)
			}
			if e.publicCount(id) != 2 {
				t.Fatal("objects deleted after a holder error")
			}
		})
	}
}

// TestOrphanSweep_OwnDeadlineIsSkippedNotFailed: a write that fails because the run's own budget ran out is a skip (the
// next run redoes it), not a failure that would page someone.
func TestOrphanSweep_OwnDeadlineIsSkippedNotFailed(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.repo.beforeSet = func(string) { cancel() }
	e.repo.setErr = context.Canceled
	res, err := e.sweeper.Sweep(ctx, sweepNow, 10)
	if err == nil || res.Failed != 0 || res.Skipped != 1 {
		t.Fatalf("res=%+v err=%v, want one skipped, none failed", res, err)
	}
}

// TestOrphanSweep_KillSwitchModes: MEDIA_ORPHAN_SWEEP as the sweeper enforces it. off reads and writes nothing; mark
// marks, holds, keeps and restores but never claims or deletes (a marked image past its grace, and a claimed one, are
// deferred by another grace with the mark kept); delete is both phases.
func TestOrphanSweep_KillSwitchModes(t *testing.T) {
	due := sweepNow.Add(-time.Minute)
	pastGrace := sweepNow.Add(-OrphanGrace - time.Hour)
	type docs struct{ fresh, marked, claimed, held string }
	setup := func(e *orphanEnv) docs {
		var d docs
		d.fresh = e.seed(uidA, PurposePost, due)
		d.marked = e.seed(uidA, PurposePost, due)
		e.doc(d.marked).OrphanedAt = &pastGrace
		d.claimed = e.seed(uidA, PurposePost, due)
		e.doc(d.claimed).OrphanedAt = &pastGrace
		e.doc(d.claimed).OrphanDeletingAt = &pastGrace
		d.held = e.seed(uidA, PurposePost, due)
		e.doc(d.held).OrphanedAt = &pastGrace
		e.drafts.held[uidA] = map[string]bool{d.held: true, d.claimed: true}
		return d
	}
	tests := []struct {
		name  string
		mode  config.MediaOrphanSweep
		check func(t *testing.T, e *orphanEnv, d docs, res OrphanSweepResult)
	}{
		{"off", config.MediaOrphanSweepOff, func(t *testing.T, e *orphanEnv, d docs, res OrphanSweepResult) {
			if res != (OrphanSweepResult{}) || len(e.repo.dueLimits) != 0 || e.repo.sets != 0 || e.repo.deletes != 0 || len(e.obj.deleted) != 0 {
				t.Fatalf("res=%+v queries=%v sets=%d deletes=%d: off must do nothing", res, e.repo.dueLimits, e.repo.sets, e.repo.deletes)
			}
			if e.doc(d.fresh).OrphanedAt != nil {
				t.Fatal("off marked")
			}
		}},
		{"mark", config.MediaOrphanSweepMark, func(t *testing.T, e *orphanEnv, d docs, res OrphanSweepResult) {
			if res.Marked != 1 || res.Deferred != 2 || res.Restored != 1 || res.Deleted != 0 {
				t.Fatalf("res = %+v, want 1 marked, 2 deferred, 1 restored, 0 deleted", res)
			}
			if e.repo.deletes != 0 || len(e.obj.deleted) != 0 {
				t.Fatalf("mark mode deleted: docs=%d objects=%v", e.repo.deletes, e.obj.deleted)
			}
			for _, id := range []string{d.marked, d.claimed} {
				doc := e.doc(id)
				if !timeIs(doc.OrphanedAt, pastGrace) || !timeIs(doc.OrphanCheckAt, sweepNow.Add(OrphanGrace)) {
					t.Errorf("deferred doc = %+v, want the mark kept and the check one grace later", doc)
				}
			}
			if !timeIs(e.doc(d.claimed).OrphanDeletingAt, pastGrace) {
				t.Error("mark mode cleared a claim")
			}
			if e.doc(d.held).OrphanedAt != nil || e.doc(d.fresh).OrphanedAt == nil {
				t.Error("mark mode must restore the held image and mark the free one")
			}
		}},
		{"delete", config.MediaOrphanSweepDelete, func(t *testing.T, e *orphanEnv, d docs, res OrphanSweepResult) {
			if res.Marked != 1 || res.Deleted != 2 || res.Restored != 1 || res.Deferred != 0 {
				t.Fatalf("res = %+v, want 1 marked, 2 deleted (the claim finished despite its holder), 1 restored", res)
			}
			if e.doc(d.marked) != nil || e.doc(d.claimed) != nil || e.doc(d.held) == nil {
				t.Fatal("delete mode deleted the wrong documents")
			}
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newOrphanEnvMode(t, config.ProfileMediaRetireOff, tt.mode, false)
			d := setup(e)
			res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
			if err != nil {
				t.Fatal(err)
			}
			tt.check(t, e, d, res)
		})
	}
}

// TestOrphanSweep_DryRunWritesNothing: the verdicts are counted as a delete run would, and nothing is written or deleted.
func TestOrphanSweep_DryRunWritesNothing(t *testing.T) {
	e := newOrphanEnvMode(t, config.ProfileMediaRetireOff, config.MediaOrphanSweepDelete, true)
	e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	marked := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	m := sweepNow.Add(-OrphanGrace - time.Hour)
	e.doc(marked).OrphanedAt = &m
	young := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	e.doc(young).CreatedAt = sweepNow.Add(-time.Hour)
	res, err := e.sweeper.Sweep(context.Background(), sweepNow, 10)
	if err != nil || res.Marked != 1 || res.Deleted != 1 || res.Young != 1 {
		t.Fatalf("res=%+v err=%v, want would-mark 1, would-delete 1, young 1", res, err)
	}
	if e.repo.sets != 0 || e.repo.deletes != 0 || len(e.obj.deleted) != 0 {
		t.Fatalf("a dry run wrote: sets=%d deletes=%d objects=%v", e.repo.sets, e.repo.deletes, e.obj.deleted)
	}
}

// TestOrphanSweep_UndecodableDocIsSkipped: a document the repo cannot decode is skipped (counted, logged by id) instead of
// failing the page, and still counts towards More so the caller keeps paging.
func TestOrphanSweep_UndecodableDocIsSkipped(t *testing.T) {
	e := newOrphanEnv(t, config.ProfileMediaRetireOff)
	e.repo.undecodable = []string{"0000000000000000bad"}
	ok := e.seed(uidA, PurposePost, sweepNow.Add(-time.Minute))
	res, err := e.sweeper.Sweep(context.Background(), sweepNow, 2)
	if err != nil || res.Undecodable != 1 || res.Due != 1 || res.Marked != 1 || !res.More {
		t.Fatalf("res=%+v err=%v, want the bad doc skipped, the good one marked and More", res, err)
	}
	if e.doc(ok).OrphanedAt == nil {
		t.Fatal("the decodable document was not swept")
	}
}

// TestOrphanSweepResult_Progressed: only outcomes that moved a document out of the due window count as progress.
func TestOrphanSweepResult_Progressed(t *testing.T) {
	if (OrphanSweepResult{Due: 5, Conflicts: 2, Failed: 2, Skipped: 1, Undecodable: 3}).Progressed() != 0 {
		t.Error("conflicts, failures, skips and undecodable documents are not progress")
	}
	if got := (OrphanSweepResult{Marked: 1, Deleted: 1, Held: 1, Kept: 1, Attached: 1, Restored: 1, Waiting: 1, Deferred: 1, Young: 1}).Progressed(); got != 9 {
		t.Errorf("Progressed = %d, want 9", got)
	}
}

type fakeHoldSource struct {
	m   map[string]bool
	err error
}

func (f fakeHoldSource) PendingScheduledMediaHolds(context.Context, string, []string) (map[string]bool, error) {
	return f.m, f.err
}

func (f fakeHoldSource) DraftCoverHolds(context.Context, string, []string) (map[string]bool, error) {
	return f.m, f.err
}

// TestNewDraftHolds: the union of both holders (false entries ignored), and either one's error is the answer (never "free").
func TestNewDraftHolds(t *testing.T) {
	boom := errors.New("boom")
	tests := []struct {
		name      string
		scheduled fakeHoldSource
		covers    fakeHoldSource
		want      map[string]bool
		wantErr   error
	}{
		{"union", fakeHoldSource{m: map[string]bool{"a": true, "c": false}}, fakeHoldSource{m: map[string]bool{"b": true}}, map[string]bool{"a": true, "b": true}, nil},
		{"none", fakeHoldSource{}, fakeHoldSource{}, map[string]bool{}, nil},
		{"scheduled fails", fakeHoldSource{err: boom}, fakeHoldSource{m: map[string]bool{"b": true}}, nil, boom},
		{"covers fail", fakeHoldSource{m: map[string]bool{"a": true}}, fakeHoldSource{err: boom}, nil, boom},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewDraftHolds(tt.scheduled, tt.covers).HeldByDrafts(context.Background(), uidA, []string{"a", "b", "c"})
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("err = %v, want %v", err, tt.wantErr)
			}
			if tt.wantErr == nil && !maps.Equal(got, tt.want) {
				t.Fatalf("held = %v, want %v", got, tt.want)
			}
		})
	}
}
