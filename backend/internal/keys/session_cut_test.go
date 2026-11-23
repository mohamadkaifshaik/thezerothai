package keys

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// The session cut of a REMOTE removal (security audit H2; removal-server design 2.3 steps 3-4 and 3.3): with
// device_sign_out on for the remover, the mark records the cut (the remover's auth_time), the cut is written through the
// SessionCutter seam, the mark notes it done, and other_sessions_ended reports it.

// fakeCutter is the identity seam: it records every cut (appending "EndSessionsBefore" to the repo's ops) and can fail.
type fakeCutter struct {
	repo *fakeRepo
	cuts []time.Time
	uids []string
	err  error
}

func (c *fakeCutter) EndSessionsBefore(_ context.Context, uid string, t time.Time) error {
	c.repo.ops = append(c.repo.ops, "EndSessionsBefore")
	if c.err != nil {
		return c.err
	}
	c.uids, c.cuts = append(c.uids, uid), append(c.cuts, t)
	return nil
}

// cutFlags answers device_sign_out (on for the listed uids) and nothing else.
type cutFlags struct{ on map[string]bool }

func (f cutFlags) Enabled(uid, name string) bool { return name == DeviceSignOutFlag && f.on[uid] }
func (f cutFlags) GloballyOff(name string) bool  { return name != DeviceSignOutFlag || len(f.on) == 0 }

// newCutService is newRemovalService with the cut seam and device_sign_out on for uidA when flagOn.
func newCutService(t *testing.T, flagOn bool) (Service, *fakeRepo, *fakeCutter) {
	t.Helper()
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	cutter := &fakeCutter{repo: repo}
	on := map[string]bool{}
	if flagOn {
		on[uidA] = true
	}
	return New(Deps{Repo: repo, Now: clk.now, ReauthMaxAge: testReauthMaxAge, Flags: cutFlags{on: on}, Sessions: cutter}), repo, cutter
}

func TestRemoveDevice_SessionCut(t *testing.T) {
	recent := t0.Add(-time.Minute).Truncate(time.Second)
	stale := t0.Add(-testReauthMaxAge - time.Second)
	earlierCut := t0.Add(-48 * time.Hour)
	cases := []struct {
		name     string
		flagOn   bool
		reason   RemoveReason
		authTime time.Time
		// pre is the mark's state before the call (nil = no mark).
		pre *MarkState
		// premarkGone: with pre set, the device document is gone (a retry).
		premarkGone bool
		cutErr      error
		wantCode    connect.Code // 0 = success
		wantOps     []string
		wantCut     time.Time // the cut written (zero = none)
		wantEnded   bool
		wantState   MarkState // the mark afterwards (when one exists)
	}{
		{name: "flag on: the cut is the remover's auth_time, done, other sessions ended", flagOn: true, reason: RemoveRemote,
			authTime: recent, wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "Remove"},
			wantCut: recent, wantEnded: true, wantState: MarkState{CutAt: recent, CutDone: true}},
		{name: "flag off: marked, no cut, other sessions not ended", reason: RemoveRemote, authTime: recent,
			wantOps: []string{"MarkRemoved", "Remove"}},
		{name: "sign-out never cuts, flag on", flagOn: true, reason: RemoveSignOut, authTime: recent,
			wantOps: []string{"Remove"}},
		{name: "unspecified (sign-out) never cuts, stale sign-in", flagOn: true, reason: RemoveSignOut, authTime: stale,
			wantOps: []string{"Remove"}},
		{name: "a retry without a recent sign-in finishes a pending cut with the stored time", flagOn: true, reason: RemoveRemote,
			authTime: stale, pre: &MarkState{CutAt: earlierCut}, premarkGone: true,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "Remove"},
			wantCut: earlierCut, wantEnded: true, wantState: MarkState{CutAt: earlierCut, CutDone: true}},
		{name: "a retry of a done cut cuts nothing again and still reports it", flagOn: true, reason: RemoveRemote,
			authTime: stale, pre: &MarkState{CutAt: earlierCut, CutDone: true}, premarkGone: true,
			wantOps: []string{"MarkRemoved", "Remove"}, wantEnded: true, wantState: MarkState{CutAt: earlierCut, CutDone: true}},
		{name: "a pending cut is finished even with the flag off now", reason: RemoveRemote,
			authTime: stale, pre: &MarkState{CutAt: earlierCut}, premarkGone: true,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "Remove"},
			wantCut: earlierCut, wantEnded: true, wantState: MarkState{CutAt: earlierCut, CutDone: true}},
		{name: "a retry without a recent sign-in never asks for a new cut", flagOn: true, reason: RemoveRemote,
			authTime: stale, pre: &MarkState{}, premarkGone: true, wantOps: []string{"MarkRemoved", "Remove"}},
		{name: "a mark without a cut gets one from a recent remover with the flag on", flagOn: true, reason: RemoveRemote,
			authTime: recent, pre: &MarkState{}, premarkGone: true,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "Remove"},
			wantCut: recent, wantEnded: true, wantState: MarkState{CutAt: recent, CutDone: true}},
		{name: "a stale first removal is REAUTH_REQUIRED and cuts nothing", flagOn: true, reason: RemoveRemote,
			authTime: stale, wantCode: connect.CodeFailedPrecondition, wantOps: []string{"MarkRemoved"}},
		{name: "a cut failure is UNAVAILABLE before the sweep; the cut stays pending", flagOn: true, reason: RemoveRemote,
			authTime: recent, cutErr: errors.New("identity down"), wantCode: connect.CodeUnavailable,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore"}, wantState: MarkState{CutAt: recent}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, cutter := newCutService(t, tc.flagOn)
			mustRegister(t, s, devID, sigKey(1))
			k := devKey(uidA, devID)
			if tc.pre != nil {
				earlier := t0.Add(-48 * time.Hour)
				repo.marks[k] = RemovalMark{DeviceID: devID, RemovedAt: earlier, ExpireAt: earlier.Add(RemovalMarkTTL)}
				repo.cuts[k] = *tc.pre
				if tc.premarkGone {
					repo.devices[uidA] = nil
				}
			}
			cutter.err = tc.cutErr
			repo.ops = nil
			ctx, info := signedIn(tc.authTime)
			res, err := s.RemoveDevice(ctx, uidA, devID, tc.reason)
			if !slices.Equal(repo.ops, tc.wantOps) {
				t.Errorf("calls = %v, want %v", repo.ops, tc.wantOps)
			}
			if tc.wantCode != 0 {
				var code connect.Code
				if ae := new(apierr.Error); errors.As(err, &ae) {
					code = ae.Code
				}
				if code != tc.wantCode {
					t.Fatalf("err = %v (code %v), want %v", err, code, tc.wantCode)
				}
				if res.OtherSessionsEnded {
					t.Error("a failed removal reports other_sessions_ended")
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if res.OtherSessionsEnded != tc.wantEnded {
				t.Errorf("OtherSessionsEnded = %v, want %v", res.OtherSessionsEnded, tc.wantEnded)
			}
			switch {
			case tc.wantCut.IsZero() && len(cutter.cuts) > 0:
				t.Errorf("cut %v, want none", cutter.cuts)
			case !tc.wantCut.IsZero() && (len(cutter.cuts) != 1 || !cutter.cuts[0].Equal(tc.wantCut) || cutter.uids[0] != uidA):
				t.Errorf("cuts = %v for %v, want exactly %v for the caller", cutter.cuts, cutter.uids, tc.wantCut)
			}
			if _, marked := repo.marks[k]; marked {
				if got := repo.cuts[k]; !got.CutAt.Equal(tc.wantState.CutAt) || got.CutDone != tc.wantState.CutDone {
					t.Errorf("mark state = %+v, want %+v", got, tc.wantState)
				}
			}
			if v, _ := info.Get(fieldSessionsEnded); tc.wantCode == 0 && tc.reason == RemoveRemote && v != tc.wantEnded {
				t.Errorf("%s = %v, want %v", fieldSessionsEnded, v, tc.wantEnded)
			}
			for _, f := range info.Fields() {
				v := fmt.Sprint(f.Value.Any())
				if strings.Contains(v, devID) || strings.Contains(v, "2026") {
					t.Errorf("request-line field %s = %q names the device id or a time", f.Key, v)
				}
			}
			if err != nil && (strings.Contains(err.Error(), devID) || strings.Contains(err.Error(), uidA)) {
				t.Errorf("the error names the device or the uid: %v", err)
			}
		})
	}
}

// TestRemoveDevice_CutRetryCompletes: after a failed cut, a retry (no recent sign-in needed: the id is marked) writes the
// SAME cut, notes it done and finishes the removal.
func TestRemoveDevice_CutRetryCompletes(t *testing.T) {
	s, repo, cutter := newCutService(t, true)
	mustRegister(t, s, devID, sigKey(1))
	authTime := t0.Add(-time.Minute).Truncate(time.Second)
	cutter.err = errors.New("identity down")
	ctx, _ := signedIn(authTime)
	if _, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote); err == nil {
		t.Fatal("want the cut failure")
	}
	if repo.find(uidA, devID) < 0 {
		t.Fatal("the sweep ran before the cut")
	}
	cutter.err = nil
	later, _ := signedIn(t0.Add(-time.Hour)) // a stale sign-in: a retry needs none
	res, err := s.RemoveDevice(later, uidA, devID, RemoveRemote)
	if err != nil || !res.OtherSessionsEnded {
		t.Fatalf("retry = %+v, %v; want ended", res, err)
	}
	if len(cutter.cuts) != 1 || !cutter.cuts[0].Equal(authTime) {
		t.Errorf("cuts = %v, want the first call's auth_time %v", cutter.cuts, authTime)
	}
	if repo.find(uidA, devID) >= 0 {
		t.Error("the device is still there")
	}
}

// TestRemoveDevice_CutDoneFailureIsRetryable: the cut was written but the mark could not note it: UNAVAILABLE before the
// sweep, and the retry cuts again (idempotent on identity's side) and finishes.
func TestRemoveDevice_CutDoneFailureIsRetryable(t *testing.T) {
	s, repo, cutter := newCutService(t, true)
	mustRegister(t, s, devID, sigKey(1))
	repo.cutDoneErr = errUnavailableForTest()
	ctx, _ := signedIn(t0.Add(-time.Minute))
	_, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
	wantErr(t, err, connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
	repo.cutDoneErr = nil
	res, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
	if err != nil || !res.OtherSessionsEnded || len(cutter.cuts) != 2 {
		t.Fatalf("retry = %+v, %v, cuts %d; want ended after a second (idempotent) cut", res, err, len(cutter.cuts))
	}
}

// TestRemoveDevice_UnwiredCutterFailsClosed: a cut that is due with no SessionCutter wired is an error, never a silent
// "done" (newKeysModule refuses a nil seam, so this only guards a future composition).
func TestRemoveDevice_UnwiredCutterFailsClosed(t *testing.T) {
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	s := New(Deps{Repo: repo, Now: clk.now, ReauthMaxAge: testReauthMaxAge, Flags: cutFlags{on: map[string]bool{uidA: true}}})
	mustRegister(t, s, devID, sigKey(1))
	ctx, _ := signedIn(t0.Add(-time.Minute))
	res, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
	if err == nil || res.OtherSessionsEnded {
		t.Fatalf("= %+v, %v; want an error", res, err)
	}
	if repo.cuts[devKey(uidA, devID)].CutDone {
		t.Error("the cut was noted done without a cutter")
	}
}

// TestServer_RemoveKeyDevice_OtherSessionsEnded: the handler puts the service's result on the wire.
func TestServer_RemoveKeyDevice_OtherSessionsEnded(t *testing.T) {
	for _, ended := range []bool{false, true} {
		svc := &fakeService{removeResult: RemoveResult{OtherSessionsEnded: ended}}
		srv := NewServer(fakeFlags{on: map[string]bool{srvCaller: true}}, svc)
		resp, err := srv.RemoveKeyDevice(srvCtx(srvCaller), connect.NewRequest(&keysv1.RemoveKeyDeviceRequest{
			IdempotencyKey: srvKey, DeviceId: srvDevice, Reason: keysv1.RemoveReason_REMOVE_REASON_REMOTE,
		}))
		if err != nil {
			t.Fatal(err)
		}
		if resp.Msg.GetOtherSessionsEnded() != ended {
			t.Errorf("other_sessions_ended = %v, want %v", resp.Msg.GetOtherSessionsEnded(), ended)
		}
	}
}
