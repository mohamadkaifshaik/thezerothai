package keys

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
)

// The refresh-token revoke of a REMOTE removal (security audit H1): once the mark's cut is written, the account's
// refresh tokens are revoked through the SessionRevoker seam and the mark notes revokeDone, before the push drop and the
// sweep. Once per mark: a retry after a done revoke does not revoke again; a retry after a failed revoke does. A failure
// is the plain retryable UNAVAILABLE before the sweep.

// fakeRevoker is the identity seam: it records every revoke (appending "RevokeSessionsAt" to the repo's ops) and can fail.
type fakeRevoker struct {
	repo *fakeRepo
	uids []string
	cuts []time.Time
	err  error
}

func (r *fakeRevoker) RevokeSessionsAt(_ context.Context, uid string, cut time.Time) error {
	r.repo.ops = append(r.repo.ops, "RevokeSessionsAt")
	if r.err != nil {
		return r.err
	}
	r.uids, r.cuts = append(r.uids, uid), append(r.cuts, cut)
	return nil
}

// newRevokeService is newCutService with the revoke seam wired and the service's log captured.
func newRevokeService(t *testing.T, flagOn bool) (Service, *fakeRepo, *fakeCutter, *fakeRevoker, *bytes.Buffer) {
	t.Helper()
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	cutter, revoker := &fakeCutter{repo: repo}, &fakeRevoker{repo: repo}
	on := map[string]bool{}
	if flagOn {
		on[uidA] = true
	}
	logs := &bytes.Buffer{}
	svc := New(Deps{Repo: repo, Now: clk.now, ReauthMaxAge: testReauthMaxAge, Flags: cutFlags{on: on}, Sessions: cutter,
		Revoke: revoker, Log: slog.New(slog.NewJSONHandler(logs, nil))})
	return svc, repo, cutter, revoker, logs
}

// plainUnavailable fails unless err is removalRetryable's shape: UNAVAILABLE with no detail (the app's queue retries it).
func plainUnavailable(t *testing.T, err error) {
	t.Helper()
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeUnavailable || len(ce.Details()) != 0 {
		t.Fatalf("err = %v, want a plain UNAVAILABLE without details", err)
	}
}

func TestRemoveDevice_SessionRevoke(t *testing.T) {
	recent := t0.Add(-time.Minute).Truncate(time.Second)
	stale := t0.Add(-testReauthMaxAge - time.Second)
	earlierCut := t0.Add(-48 * time.Hour)
	cases := []struct {
		name      string
		flagOn    bool
		reason    RemoveReason
		authTime  time.Time
		pre       *MarkState // the mark's state before the call (nil = no mark); the device document is then gone (a retry)
		cutErr    error
		revokeErr error
		markErr   error
		wantErr   bool
		wantOps   []string
		wantCut   time.Time // the cut revoked at (zero = no revoke)
		wantState MarkState
	}{
		{name: "a new cut: cut, then revoke at the remover's auth_time, both noted, then the sweep", flagOn: true, reason: RemoveRemote,
			authTime: recent, wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "RevokeSessionsAt", "MarkRevokeDone", "Remove"},
			wantCut: recent, wantState: MarkState{CutAt: recent, CutDone: true, RevokeDone: true}},
		{name: "flag off: no cut, no revoke", reason: RemoveRemote, authTime: recent, wantOps: []string{"MarkRemoved", "Remove"}},
		{name: "sign-out never revokes", flagOn: true, reason: RemoveSignOut, authTime: recent, wantOps: []string{"Remove"}},
		{name: "a retry of a done cut and revoke revokes nothing again", flagOn: true, reason: RemoveRemote, authTime: stale,
			pre:       &MarkState{CutAt: earlierCut, CutDone: true, RevokeDone: true},
			wantOps:   []string{"MarkRemoved", "Remove"},
			wantState: MarkState{CutAt: earlierCut, CutDone: true, RevokeDone: true}},
		{name: "a retry after a failed revoke revokes with the stored cut, no sign-in needed", reason: RemoveRemote, authTime: stale,
			pre:     &MarkState{CutAt: earlierCut, CutDone: true},
			wantOps: []string{"MarkRemoved", "RevokeSessionsAt", "MarkRevokeDone", "Remove"},
			wantCut: earlierCut, wantState: MarkState{CutAt: earlierCut, CutDone: true, RevokeDone: true}},
		{name: "a failed cut never revokes", flagOn: true, reason: RemoveRemote, authTime: recent, cutErr: errors.New("identity down"),
			wantErr: true, wantOps: []string{"MarkRemoved", "EndSessionsBefore"}, wantState: MarkState{CutAt: recent}},
		{name: "a failed revoke is UNAVAILABLE before the sweep; revokeDone stays unset", flagOn: true, reason: RemoveRemote,
			authTime: recent, revokeErr: errors.New("auth down"), wantErr: true,
			wantOps:   []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "RevokeSessionsAt"},
			wantState: MarkState{CutAt: recent, CutDone: true}},
		{name: "a failed revokeDone note is UNAVAILABLE before the sweep", flagOn: true, reason: RemoveRemote,
			authTime: recent, markErr: errors.New("firestore down"), wantErr: true,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "RevokeSessionsAt", "MarkRevokeDone"},
			wantCut: recent, wantState: MarkState{CutAt: recent, CutDone: true}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, cutter, revoker, logs := newRevokeService(t, tc.flagOn)
			mustRegister(t, s, devID, sigKey(1))
			k := devKey(uidA, devID)
			if tc.pre != nil {
				earlier := t0.Add(-48 * time.Hour)
				repo.marks[k] = RemovalMark{DeviceID: devID, RemovedAt: earlier, ExpireAt: earlier.Add(RemovalMarkTTL)}
				repo.cuts[k] = *tc.pre
				repo.devices[uidA] = nil
			}
			cutter.err, revoker.err, repo.revokeDoneErr = tc.cutErr, tc.revokeErr, tc.markErr
			repo.ops = nil
			ctx, info := signedIn(tc.authTime)
			_, err := s.RemoveDevice(ctx, uidA, devID, tc.reason)
			if !slices.Equal(repo.ops, tc.wantOps) {
				t.Errorf("calls = %v, want %v", repo.ops, tc.wantOps)
			}
			if tc.wantErr {
				plainUnavailable(t, err)
				if tc.pre == nil && repo.find(uidA, devID) < 0 {
					t.Error("the sweep ran after a failed step")
				}
			} else if err != nil {
				t.Fatal(err)
			}
			switch {
			case tc.wantCut.IsZero() && len(revoker.cuts) > 0:
				t.Errorf("revoked at %v, want no revoke", revoker.cuts)
			case !tc.wantCut.IsZero() && (len(revoker.cuts) != 1 || !revoker.cuts[0].Equal(tc.wantCut) || revoker.uids[0] != uidA):
				t.Errorf("revokes = %v for %v, want exactly %v for the caller", revoker.cuts, revoker.uids, tc.wantCut)
			}
			if _, marked := repo.marks[k]; marked && repo.cuts[k] != tc.wantState {
				t.Errorf("mark state = %+v, want %+v", repo.cuts[k], tc.wantState)
			}
			v, _ := info.Get(fieldSessionsRevoked)
			if wantRevoked := tc.wantState.RevokeDone && !tc.wantErr && !tc.wantCut.IsZero(); (v == true) != wantRevoked {
				t.Errorf("%s = %v, want %v", fieldSessionsRevoked, v, wantRevoked)
			}
			out := logs.String()
			if (tc.revokeErr != nil || tc.markErr != nil) != strings.Contains(out, "keys_session_revoke_failed") {
				t.Errorf("revoke failure WARN presence wrong: %s", out)
			}
			if strings.Contains(out, uidA) || strings.Contains(out, devID) || strings.Contains(out, "auth down") || strings.Contains(out, "firestore down") {
				t.Errorf("the log names the uid, the device or the error text: %s", out)
			}
		})
	}
}

// TestRemoveDevice_RevokeRetryRevokesOnce: a failed revoke leaves the device; the retry (a stale sign-in: the id is
// marked) revokes with the first call's cut, finishes the removal, and a further retry revokes nothing again.
func TestRemoveDevice_RevokeRetryRevokesOnce(t *testing.T) {
	s, repo, cutter, revoker, _ := newRevokeService(t, true)
	mustRegister(t, s, devID, sigKey(1))
	authTime := t0.Add(-time.Minute).Truncate(time.Second)
	revoker.err = errors.New("auth down")
	ctx, _ := signedIn(authTime)
	_, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
	plainUnavailable(t, err)
	if repo.find(uidA, devID) < 0 {
		t.Fatal("the sweep ran before the revoke")
	}
	revoker.err = nil
	for range 2 {
		later, _ := signedIn(t0.Add(-time.Hour))
		if res, err := s.RemoveDevice(later, uidA, devID, RemoveRemote); err != nil || !res.OtherSessionsEnded {
			t.Fatalf("retry = %+v, %v; want ended", res, err)
		}
	}
	if len(cutter.cuts) != 1 {
		t.Errorf("cuts = %v, want the one cut", cutter.cuts)
	}
	if len(revoker.cuts) != 1 || !revoker.cuts[0].Equal(authTime) {
		t.Errorf("revokes = %v, want exactly one at the first call's auth_time %v", revoker.cuts, authTime)
	}
	if repo.find(uidA, devID) >= 0 {
		t.Error("the device is still there")
	}
}
