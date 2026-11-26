package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// A REMOTE removal that carries a session cut drops the account's push registrations through the PushRegistrations seam
// (removal-server design Q9, lane D PR 5): once per call, after the cut is done and before the sweep; never for a
// sign-out, a removal without a cut or a failed cut; a failure never fails the removal and logs no uid, time or token.

// fakePush is the notifications seam: it appends "DropPush" to the repo's ops and can fail.
type fakePush struct {
	repo *fakeRepo
	uids []string
	n    int
	err  error
}

func (p *fakePush) DropPushRegistrations(_ context.Context, uid string) (int, error) {
	p.repo.ops = append(p.repo.ops, "DropPush")
	p.uids = append(p.uids, uid)
	if p.err != nil {
		return 0, p.err
	}
	return p.n, nil
}

func newPushService(t *testing.T, flagOn bool, log *slog.Logger) (Service, *fakeRepo, *fakeCutter, *fakePush) {
	t.Helper()
	repo, clk := newFakeRepo(), &fakeClock{t: t0}
	cutter, push := &fakeCutter{repo: repo}, &fakePush{repo: repo, n: 2}
	on := map[string]bool{}
	if flagOn {
		on[uidA] = true
	}
	return New(Deps{Repo: repo, Now: clk.now, ReauthMaxAge: testReauthMaxAge, Flags: cutFlags{on: on}, Sessions: cutter, Push: push, Log: log}),
		repo, cutter, push
}

func TestRemoveDevice_DropsPushOnCut(t *testing.T) {
	recent := t0.Add(-time.Minute).Truncate(time.Second)
	cases := []struct {
		name     string
		flagOn   bool
		reason   RemoveReason
		cutErr   error
		wantOps  []string
		wantDrop bool
	}{
		{name: "flag on: dropped once, after the cut is done, before the sweep", flagOn: true, reason: RemoveRemote,
			wantOps: []string{"MarkRemoved", "EndSessionsBefore", "MarkCutDone", "DropPush", "Remove"}, wantDrop: true},
		{name: "flag off: no cut, nothing dropped", reason: RemoveRemote, wantOps: []string{"MarkRemoved", "Remove"}},
		{name: "sign-out never drops", flagOn: true, reason: RemoveSignOut, wantOps: []string{"Remove"}},
		{name: "a failed cut drops nothing", flagOn: true, reason: RemoveRemote, cutErr: errors.New("identity down"),
			wantOps: []string{"MarkRemoved", "EndSessionsBefore"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, repo, cutter, push := newPushService(t, tc.flagOn, nil)
			mustRegister(t, s, devID, sigKey(1))
			cutter.err = tc.cutErr
			repo.ops = nil
			ctx, info := signedIn(recent)
			_, _ = s.RemoveDevice(ctx, uidA, devID, tc.reason)
			if !slices.Equal(repo.ops, tc.wantOps) {
				t.Errorf("calls = %v, want %v", repo.ops, tc.wantOps)
			}
			v, set := info.Get(fieldPushDropped)
			if tc.wantDrop {
				if len(push.uids) != 1 || push.uids[0] != uidA {
					t.Errorf("drops for %v, want exactly one for the caller", push.uids)
				}
				if !set || fmt.Sprint(v) != "2" {
					t.Errorf("%s = %v (set %v), want 2", fieldPushDropped, v, set)
				}
			} else if len(push.uids) != 0 || set {
				t.Errorf("dropped for %v (field set %v), want none", push.uids, set)
			}
		})
	}
}

// TestRemoveDevice_PushDropRetry: a retry of the same removal (the cut already done) drops again; the drop is idempotent
// on the notifications side, so this is how a failed drop is tried again.
func TestRemoveDevice_PushDropRetry(t *testing.T) {
	s, repo, cutter, push := newPushService(t, true, nil)
	mustRegister(t, s, devID, sigKey(1))
	ctx, _ := signedIn(t0.Add(-time.Minute))
	for i := range 2 {
		res, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
		if err != nil || !res.OtherSessionsEnded {
			t.Fatalf("call %d = %+v, %v; want ended", i+1, res, err)
		}
	}
	if len(push.uids) != 2 {
		t.Errorf("drops = %d, want 2 (once per call)", len(push.uids))
	}
	if len(cutter.cuts) != 1 {
		t.Errorf("cuts = %d, want 1 (the retry finds it done)", len(cutter.cuts))
	}
	if repo.find(uidA, devID) >= 0 {
		t.Error("the device is still there")
	}
}

// TestRemoveDevice_PushDropFailureDoesNotFailRemoval: a failed drop answers success with the sessions ended, sets
// push_drop_failed on the request line, and its WARN names no uid, device id, time or token.
func TestRemoveDevice_PushDropFailureDoesNotFailRemoval(t *testing.T) {
	var logs bytes.Buffer
	// The handler's own time attribute is dropped, so a "2026" in the line can only come from the message's fields.
	noTime := &slog.HandlerOptions{ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
		if len(groups) == 0 && a.Key == slog.TimeKey {
			return slog.Attr{}
		}
		return a
	}}
	s, repo, _, push := newPushService(t, true, slog.New(slog.NewJSONHandler(&logs, noTime)))
	push.err = errors.New("notifications down for " + uidA)
	mustRegister(t, s, devID, sigKey(1))
	ctx, info := signedIn(t0.Add(-time.Minute))
	res, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
	if err != nil || !res.OtherSessionsEnded {
		t.Fatalf("= %+v, %v; want success with the sessions ended", res, err)
	}
	if repo.find(uidA, devID) >= 0 {
		t.Error("the device is still there")
	}
	if v, _ := info.Get(fieldPushDropFailed); v != true {
		t.Errorf("%s = %v, want true", fieldPushDropFailed, v)
	}
	if _, set := info.Get(fieldPushDropped); set {
		t.Errorf("%s set on a failed drop", fieldPushDropped)
	}
	out := logs.String()
	if !strings.Contains(out, "keys_push_drop_failed") {
		t.Fatalf("no WARN: %s", out)
	}
	for _, bad := range []string{uidA, logger.HashUID(uidA), devID, "2026"} {
		if strings.Contains(out, bad) {
			t.Errorf("the WARN names %q: %s", bad, out)
		}
	}
}
