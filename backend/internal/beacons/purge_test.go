package beacons

import (
	"context"
	"errors"
	"testing"
)

// fakePurger answers successive page sizes per phase and counts the calls.
type fakePurger struct {
	organised, memberships []int
	oCalls, mCalls         int
	err                    error
}

func (f *fakePurger) PurgeOrganisedPage(context.Context, string) (int, error) {
	f.oCalls++
	if f.err != nil {
		return 0, f.err
	}
	if len(f.organised) == 0 {
		return 0, nil
	}
	n := f.organised[0]
	f.organised = f.organised[1:]
	return n, nil
}

func (f *fakePurger) PurgeMembershipPage(context.Context, string) (int, error) {
	f.mCalls++
	if f.err != nil {
		return 0, f.err
	}
	if len(f.memberships) == 0 {
		return 0, nil
	}
	n := f.memberships[0]
	f.memberships = f.memberships[1:]
	return n, nil
}

// TestEraser_PhasesAndResume: a full page keeps the phase, a short page advances it; the organised phase ends on a short
// page and the memberships phase ends on a short page; a rerun after completion is two empty pages and no writes.
func TestEraser_PhasesAndResume(t *testing.T) {
	p := &fakePurger{organised: []int{purgeOrganisedPage, 3}, memberships: []int{purgeMembershipPage, 2}}
	e := NewEraser(p)
	ctx := context.Background()
	var cp Checkpoint
	var done bool
	var err error
	step := func(wantPhase string, wantDone bool) {
		t.Helper()
		cp, done, err = e.PurgeUser(ctx, "doomed", cp)
		if err != nil {
			t.Fatal(err)
		}
		if cp.Phase != wantPhase || done != wantDone {
			t.Fatalf("checkpoint = %+v done %v, want phase %q done %v", cp, done, wantPhase, wantDone)
		}
	}
	step(phaseOrganised, false)   // full page of organised beacons: stay
	step(phaseMemberships, false) // short page: advance
	step(phaseMemberships, false) // full page of memberships: stay
	step(phaseMemberships, true)  // short page: done
	if cp.Deleted != purgeOrganisedPage+3+purgeMembershipPage+2 {
		t.Fatalf("deleted = %d", cp.Deleted)
	}
	// Rerun from the beginning: two empty pages, nothing more.
	p2 := &fakePurger{}
	e2 := NewEraser(p2)
	cp2, done2, err := e2.PurgeUser(ctx, "doomed", Checkpoint{})
	if err != nil || done2 || cp2.Phase != phaseMemberships {
		t.Fatalf("rerun step 1 = %+v %v %v", cp2, done2, err)
	}
	cp2, done2, err = e2.PurgeUser(ctx, "doomed", cp2)
	if err != nil || !done2 || cp2.Deleted != 0 || p2.oCalls != 1 || p2.mCalls != 1 {
		t.Fatalf("rerun step 2 = %+v %v %v (calls %d/%d)", cp2, done2, err, p2.oCalls, p2.mCalls)
	}
}

// TestEraser_ErrorKeepsCheckpoint: a page error returns the checkpoint it was given, so the job retries the same page.
func TestEraser_ErrorKeepsCheckpoint(t *testing.T) {
	want := errors.New("boom")
	e := NewEraser(&fakePurger{err: want})
	in := Checkpoint{Phase: phaseMemberships, Deleted: 7}
	cp, done, err := e.PurgeUser(context.Background(), "doomed", in)
	if !errors.Is(err, want) || done || cp != in {
		t.Fatalf("got %+v %v %v", cp, done, err)
	}
}
