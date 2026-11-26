//go:build integration

package keys

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// The session cut on the mark, on the emulator (security audit H2; removal-server design 2.1 and 2.3 steps 3-4).

// recordingCutter is the identity seam on the emulator tests: it records the cuts, and can fail.
type recordingCutter struct {
	mu   sync.Mutex
	cuts []time.Time
	err  error
}

func (c *recordingCutter) EndSessionsBefore(_ context.Context, _ string, t time.Time) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.err != nil {
		return c.err
	}
	c.cuts = append(c.cuts, t)
	return nil
}

// TestRemoval_SessionCutOnTheMark: the mark stores cutAt (the remover's auth_time) and cutDone; an existing cutAt is
// kept; a mark without one gets it from a later REMOTE removal with the flag on; MarkCutDone never re-creates a mark.
func TestRemoval_SessionCutOnTheMark(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	e.mustRegister(t, uid, dvc(1), skey(1), it0)
	now := it0.Add(time.Hour)
	authAt := now.Add(-time.Minute).Truncate(time.Second)

	t.Run("the service cuts, notes it done and reports it", func(t *testing.T) {
		cutter := &recordingCutter{}
		svc := New(Deps{Repo: e.repo, Now: func() time.Time { return now }, ReauthMaxAge: itReauth,
			Flags: cutFlags{on: map[string]bool{uid: true}}, Sessions: cutter})
		res, err := svc.RemoveDevice(signedInAt(uid, authAt), uid, dvc(1), RemoveRemote)
		if err != nil || !res.OtherSessionsEnded {
			t.Fatalf("= %+v, %v; want ended", res, err)
		}
		if len(cutter.cuts) != 1 || !cutter.cuts[0].Equal(authAt) {
			t.Fatalf("cuts = %v, want [%v]", cutter.cuts, authAt)
		}
		data, ok := e.markData(t, uid, dvc(1))
		if !ok || !data["cutAt"].(time.Time).Equal(authAt) || data["cutDone"] != true {
			t.Fatalf("mark = %v, want cutAt %v and cutDone true", data, authAt)
		}
		// A retry with a stale sign-in cuts nothing again and still reports it.
		res, err = svc.RemoveDevice(signedInAt(uid, now.Add(-time.Hour)), uid, dvc(1), RemoveRemote)
		if err != nil || !res.OtherSessionsEnded || len(cutter.cuts) != 1 {
			t.Fatalf("retry = %+v, %v, cuts %d; want ended, no new cut", res, err, len(cutter.cuts))
		}
	})

	t.Run("a cut failure leaves it pending; the retry finishes it", func(t *testing.T) {
		e.mustRegister(t, uid, dvc(2), skey(2), it0)
		cutter := &recordingCutter{err: errors.New("identity down")}
		svc := New(Deps{Repo: e.repo, Now: func() time.Time { return now }, ReauthMaxAge: itReauth,
			Flags: cutFlags{on: map[string]bool{uid: true}}, Sessions: cutter})
		if _, err := svc.RemoveDevice(signedInAt(uid, authAt), uid, dvc(2), RemoveRemote); err == nil {
			t.Fatal("want the cut failure")
		}
		data, _ := e.markData(t, uid, dvc(2))
		if _, done := data["cutDone"]; done || !data["cutAt"].(time.Time).Equal(authAt) {
			t.Fatalf("mark = %v, want cutAt and no cutDone", data)
		}
		if _, err := e.repo.deviceRef(uid, dvc(2)).Get(ctx); err != nil {
			t.Fatalf("the device was swept before the cut: %v", err)
		}
		cutter.err = nil
		res, err := svc.RemoveDevice(signedInAt(uid, now.Add(-time.Hour)), uid, dvc(2), RemoveRemote)
		if err != nil || !res.OtherSessionsEnded || len(cutter.cuts) != 1 || !cutter.cuts[0].Equal(authAt) {
			t.Fatalf("retry = %+v, %v, cuts %v; want ended with the first auth_time", res, err, cutter.cuts)
		}
	})

	t.Run("an existing cut is kept; a mark without one gets it", func(t *testing.T) {
		if _, err := e.repo.MarkRemovedCut(ctx, uid, dvc(3), now, true, time.Time{}); err != nil {
			t.Fatal(err)
		}
		if data, _ := e.markData(t, uid, dvc(3)); len(data) != 2 {
			t.Fatalf("a mark without a cut = %v, want removedAt and expireAt only", data)
		}
		st, err := e.repo.MarkRemovedCut(ctx, uid, dvc(3), now.Add(time.Hour), true, authAt)
		if err != nil || !st.CutAt.Equal(authAt) || st.CutDone {
			t.Fatalf("= %+v, %v; want cutAt %v pending", st, err, authAt)
		}
		st, err = e.repo.MarkRemovedCut(ctx, uid, dvc(3), now.Add(2*time.Hour), true, authAt.Add(time.Hour))
		if err != nil || !st.CutAt.Equal(authAt) {
			t.Fatalf("= %+v, %v; want the first cut kept", st, err)
		}
		if err := e.repo.MarkCutDone(ctx, uid, dvc(3)); err != nil {
			t.Fatal(err)
		}
		st, err = e.repo.MarkRemovedCut(ctx, uid, dvc(3), now.Add(3*time.Hour), false, time.Time{})
		if err != nil || !st.CutDone || !st.CutAt.Equal(authAt) {
			t.Fatalf("= %+v, %v; want the done cut", st, err)
		}
		data, _ := e.markData(t, uid, dvc(3))
		if !data["removedAt"].(time.Time).Equal(now) {
			t.Errorf("removedAt moved: %v", data["removedAt"])
		}
	})

	t.Run("MarkCutDone on a missing mark is an error and creates nothing", func(t *testing.T) {
		if err := e.repo.MarkCutDone(ctx, uid, dvc(4)); err == nil {
			t.Fatal("want an error")
		}
		if _, ok := e.markData(t, uid, dvc(4)); ok {
			t.Fatal("a mark was created")
		}
	})
}

// recordingRevoker is the H1 revoke seam on the emulator tests: it records the cuts it revoked at, and can fail.
type recordingRevoker struct {
	mu   sync.Mutex
	cuts []time.Time
	err  error
}

func (r *recordingRevoker) RevokeSessionsAt(_ context.Context, _ string, cut time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err != nil {
		return r.err
	}
	r.cuts = append(r.cuts, cut)
	return nil
}

// TestRemoval_SessionRevokeOnTheMark (H1): the mark stores revokeDone after the revoke; a failed revoke leaves it unset
// and the device in place, and the retry revokes once; a new cut on a mark without one starts with revokeDone false;
// MarkRevokeDone never re-creates a mark.
func TestRemoval_SessionRevokeOnTheMark(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	uid := uniqueUID()
	now := it0.Add(time.Hour)
	authAt := now.Add(-time.Minute).Truncate(time.Second)
	newSvc := func(rv *recordingRevoker) Service {
		return New(Deps{Repo: e.repo, Now: func() time.Time { return now }, ReauthMaxAge: itReauth,
			Flags: cutFlags{on: map[string]bool{uid: true}}, Sessions: &recordingCutter{}, Revoke: rv})
	}

	t.Run("a failed revoke leaves revokeDone unset; the retry revokes once and notes it", func(t *testing.T) {
		e.mustRegister(t, uid, dvc(1), skey(1), it0)
		rv := &recordingRevoker{err: errors.New("auth down")}
		svc := newSvc(rv)
		if _, err := svc.RemoveDevice(signedInAt(uid, authAt), uid, dvc(1), RemoveRemote); err == nil {
			t.Fatal("want the revoke failure")
		}
		data, _ := e.markData(t, uid, dvc(1))
		if _, set := data["revokeDone"]; set || data["cutDone"] != true {
			t.Fatalf("mark = %v, want cutDone and no revokeDone", data)
		}
		if _, err := e.repo.deviceRef(uid, dvc(1)).Get(ctx); err != nil {
			t.Fatalf("the device was swept before the revoke: %v", err)
		}
		rv.err = nil
		for range 2 {
			if res, err := svc.RemoveDevice(signedInAt(uid, now.Add(-time.Hour)), uid, dvc(1), RemoveRemote); err != nil || !res.OtherSessionsEnded {
				t.Fatalf("retry = %+v, %v; want ended", res, err)
			}
		}
		if len(rv.cuts) != 1 || !rv.cuts[0].Equal(authAt) {
			t.Fatalf("revokes = %v, want exactly [%v]", rv.cuts, authAt)
		}
		if data, _ := e.markData(t, uid, dvc(1)); data["revokeDone"] != true {
			t.Fatalf("mark = %v, want revokeDone", data)
		}
	})

	t.Run("a cut recorded on an existing mark resets revokeDone", func(t *testing.T) {
		if _, err := e.repo.MarkRemovedCut(ctx, uid, dvc(2), now, true, time.Time{}); err != nil {
			t.Fatal(err)
		}
		if err := e.repo.MarkRevokeDone(ctx, uid, dvc(2)); err != nil { // stands in for a stale value on a mark without a cut
			t.Fatal(err)
		}
		st, err := e.repo.MarkRemovedCut(ctx, uid, dvc(2), now, true, authAt)
		if err != nil || !st.CutAt.Equal(authAt) || st.CutDone || st.RevokeDone {
			t.Fatalf("= %+v, %v; want a pending cut and revoke", st, err)
		}
		if data, _ := e.markData(t, uid, dvc(2)); data["revokeDone"] != false {
			t.Fatalf("mark = %v, want revokeDone false", data)
		}
	})

	t.Run("MarkRevokeDone on a missing mark is an error and creates nothing", func(t *testing.T) {
		if err := e.repo.MarkRevokeDone(ctx, uid, dvc(3)); err == nil {
			t.Fatal("want an error")
		}
		if _, ok := e.markData(t, uid, dvc(3)); ok {
			t.Fatal("a mark was created")
		}
	})
}
