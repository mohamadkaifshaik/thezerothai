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

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// A REMOTE removal that carries a session cut drops the account's push registrations through the PushRegistrations seam
// (removal-server design Q9, lane D PR 5): once per call, after the cut is done and before the sweep; never for a
// sign-out, a removal without a cut or a failed cut. A failed drop (fix round 1, security M2) is a plain UNAVAILABLE
// before the sweep, so the key device stays and the client's queue retries; its WARN names a fixed reason and the gRPC
// code only.

// fakePush is the notifications seam: it appends "DropPush" to the repo's ops and can fail. block makes it wait for its
// context to end (the deadline case); deadline records whether its context had one.
type fakePush struct {
	repo     *fakeRepo
	uids     []string
	n        int
	err      error
	block    bool
	deadline time.Duration
}

func (p *fakePush) DropPushRegistrations(ctx context.Context, uid string) (int, error) {
	p.repo.ops = append(p.repo.ops, "DropPush")
	p.uids = append(p.uids, uid)
	if d, ok := ctx.Deadline(); ok {
		p.deadline = time.Until(d)
	}
	if p.block {
		<-ctx.Done()
		return 0, ctx.Err()
	}
	if p.err != nil {
		return 0, p.err
	}
	return p.n, nil
}

// stageErr is a drop error that names its stage, like notifications.DropError.
type stageErr struct {
	stage string
	err   error
}

func (e *stageErr) Error() string          { return e.stage + ": " + e.err.Error() }
func (e *stageErr) Unwrap() error          { return e.err }
func (e *stageErr) PushDropReason() string { return e.stage }

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

// noTimeJSON is a JSON logger into buf without the handler's own time attribute, so a "2026" in a line can only come
// from the message's fields.
func noTimeJSON(buf *bytes.Buffer) *slog.Logger {
	return slog.New(slog.NewJSONHandler(buf, &slog.HandlerOptions{ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
		if len(groups) == 0 && a.Key == slog.TimeKey {
			return slog.Attr{}
		}
		return a
	}}))
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
				if push.deadline <= 0 || push.deadline > pushDropTimeout {
					t.Errorf("drop deadline %v, want within %v", push.deadline, pushDropTimeout)
				}
			} else if len(push.uids) != 0 || set {
				t.Errorf("dropped for %v (field set %v), want none", push.uids, set)
			}
		})
	}
}

// TestRemoveDevice_PushDropRetry: a retry of the same removal (the cut already done) drops again; the drop is idempotent
// on the notifications side.
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

// TestRemoveDevice_PushDropFailureIsRetryable: a failed drop answers a plain UNAVAILABLE (no ErrorDetail, so the app keeps
// its intent and resends it) before the sweep, with the cut recorded and done; the WARN names the fixed reason and the gRPC
// code, never the error text, a uid, its hash, the device id or a time. A retry (a stale sign-in: the id is marked) drops
// and finishes, without a second cut.
func TestRemoveDevice_PushDropFailureIsRetryable(t *testing.T) {
	for _, tc := range []struct {
		name       string
		err        error
		block      bool
		wantReason string
		wantCode   string
	}{
		{"a stage error", &stageErr{stage: "commit", err: fmt.Errorf("wrapped: %w", status.Error(codes.Aborted, "contention for "+uidA))}, false, "commit", "Aborted"},
		{"an error without a stage", errors.New("boom " + uidA), false, "unknown", "Unknown"},
		{"the drop deadline", nil, true, "deadline", "Unknown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var logs bytes.Buffer
			s, repo, cutter, push := newPushService(t, true, noTimeJSON(&logs))
			push.err, push.block = tc.err, tc.block
			mustRegister(t, s, devID, sigKey(1))
			ctx, info := signedIn(t0.Add(-time.Minute))
			if tc.block {
				// The deadline case: a short request deadline stands in for the 3 s drop deadline (no sleeps).
				var cancel context.CancelFunc
				ctx, cancel = context.WithTimeout(ctx, time.Millisecond)
				defer cancel()
			}
			res, err := s.RemoveDevice(ctx, uidA, devID, RemoveRemote)
			var ce *connect.Error
			if !errors.As(err, &ce) || ce.Code() != connect.CodeUnavailable || len(ce.Details()) != 0 {
				t.Fatalf("= %v; want a plain UNAVAILABLE (no ErrorDetail)", err)
			}
			if errors.As(err, new(*apierr.Error)) {
				t.Error("the answer carries an apierr.Error (it would get an ErrorDetail)")
			}
			if res.OtherSessionsEnded {
				t.Error("a failed removal reports other_sessions_ended")
			}
			if repo.find(uidA, devID) < 0 {
				t.Fatal("the sweep ran before the drop")
			}
			if st := repo.cuts[devKey(uidA, devID)]; !st.CutDone {
				t.Error("the cut is not recorded as done (the thief would still be in)")
			}
			if v, _ := info.Get(fieldPushDropFailed); v != true {
				t.Errorf("%s = %v, want true", fieldPushDropFailed, v)
			}
			out := logs.String()
			if !strings.Contains(out, `"msg":"keys_push_drop_failed"`) || !strings.Contains(out, `"reason":"`+tc.wantReason+`"`) ||
				!strings.Contains(out, `"grpc_code":"`+tc.wantCode+`"`) {
				t.Fatalf("WARN = %s; want reason %s and grpc_code %s", out, tc.wantReason, tc.wantCode)
			}
			for _, bad := range []string{uidA, logger.HashUID(uidA), devID, "2026", "boom", "contention", `"err"`} {
				if strings.Contains(out, bad) {
					t.Errorf("the WARN names %q: %s", bad, out)
				}
			}

			// The retry: no sign-in needed, the drop succeeds, the removal finishes, no second cut.
			push.err, push.block = nil, false
			res, err = s.RemoveDevice(context.Background(), uidA, devID, RemoveRemote)
			if err != nil || !res.OtherSessionsEnded {
				t.Fatalf("retry = %+v, %v; want ended", res, err)
			}
			if repo.find(uidA, devID) >= 0 {
				t.Error("the device is still there after the retry")
			}
			if len(cutter.cuts) != 1 || len(push.uids) != 2 {
				t.Errorf("cuts %d, drops %d; want 1 and 2", len(cutter.cuts), len(push.uids))
			}
		})
	}
}
