package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// sharedRig is a claimRig with bob's two devices: devB1 last seen 31 days before the rig's clock (inactive) and devB2
// seen a day before it (active). Alice is the caller; the flags and the shared-conversation answer are set per case.
func sharedRig(t *testing.T, callerOn, targetOn, shared bool) *claimRig {
	t.Helper()
	r := newClaimRig(t)
	r.setFlags(map[string]bool{uidA: callerOn, uidBob: targetOn})
	r.perm.shares = map[string]bool{uidBob: shared}
	r.seed(t, uidBob, devB1, 2, pkgs(0, 2), []byte("lr"))
	r.clk.t = t0.Add(30 * 24 * time.Hour)
	r.seed(t, uidBob, devB2, 3, pkgs(10, 2), nil)
	r.clk.t = t0.Add(31 * 24 * time.Hour)
	r.repo.calls, r.repo.listCalls, r.repo.activeCalls = 0, 0, 0
	return r
}

// setFlags replaces the uids the flag is on for and rebuilds the service (it holds a copy of the flag checker).
func (r *claimRig) setFlags(on map[string]bool) {
	r.flags = fakeFlags{on: on}
	r.svc = New(Deps{Repo: r.repo, Now: r.clk.now, Permission: r.perm, Flags: r.flags, ConversationID: fakeConvID})
}

func deviceIDsOf(ds []Device) []string {
	out := make([]string, 0, len(ds))
	for _, d := range ds {
		out = append(out, d.ID)
	}
	return out
}

// TestGetDevices_SharedConversationRule pins K1/K5: another user's devices are returned when the caller and the target
// both have the flag on (active devices) or the two share an encrypted conversation (every registered device, with
// Inactive set, whatever either flag says); everything else is an empty success with no device read at all.
func TestGetDevices_SharedConversationRule(t *testing.T) {
	tests := []struct {
		name                       string
		callerOn, targetOn, shared bool
		want                       []string // device ids; nil = empty list and no read
		wantInactive               map[string]bool
	}{
		{"on,on,no: active devices only", true, true, false, []string{devB2}, map[string]bool{}},
		{"on,on,yes: every registered device", true, true, true, []string{devB1, devB2}, map[string]bool{devB1: true}},
		{"on,off,yes", true, false, true, []string{devB1, devB2}, map[string]bool{devB1: true}},
		{"off,on,yes", false, true, true, []string{devB1, devB2}, map[string]bool{devB1: true}},
		{"off,off,yes", false, false, true, []string{devB1, devB2}, map[string]bool{devB1: true}},
		{"on,off,no: empty, no read", true, false, false, nil, nil},
		{"off,on,no: empty, no read", false, true, false, nil, nil},
		{"off,off,no: empty, no read", false, false, false, nil, nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := sharedRig(t, tc.callerOn, tc.targetOn, tc.shared)
			got, err := r.svc.GetDevices(context.Background(), uidA, []string{uidBob})
			if err != nil {
				t.Fatal(err)
			}
			ds, ok := got[uidBob]
			if !ok || ds == nil {
				t.Fatalf("no entry for bob: %v", got)
			}
			if len(tc.want) == 0 {
				if len(ds) != 0 || r.repo.calls != 0 {
					t.Fatalf("devices %v with %d repository reads, want an empty list and no read", ds, r.repo.calls)
				}
				return
			}
			if fmt.Sprint(deviceIDsOf(ds)) != fmt.Sprint(tc.want) {
				t.Fatalf("devices %v, want %v", deviceIDsOf(ds), tc.want)
			}
			for _, d := range ds {
				if d.Inactive != tc.wantInactive[d.ID] {
					t.Fatalf("device %s Inactive = %v, want %v", d.ID, d.Inactive, tc.wantInactive[d.ID])
				}
				// Another user's device: only id, key and the marker.
				if len(d.SignatureKey) != SignatureKeyBytes || d.PoolCount != 0 || d.HasLastResort || !d.CreatedAt.IsZero() || !d.LastSeenAt.IsZero() {
					t.Fatalf("device %s carries more than id, key and marker: %+v", d.ID, d)
				}
			}
			// The shared rows read with List, the flag rows with ActiveDevices: one read, never both.
			if tc.shared && (r.repo.listCalls != 1 || r.repo.activeCalls != 0) {
				t.Fatalf("shared: list %d active %d, want one List", r.repo.listCalls, r.repo.activeCalls)
			}
			if !tc.shared && (r.repo.activeCalls != 1 || r.repo.listCalls != 0) {
				t.Fatalf("flags: list %d active %d, want one ActiveDevices", r.repo.listCalls, r.repo.activeCalls)
			}
		})
	}
}

// The caller's own id: asked about only when the caller's flag is on (active devices with every field), else empty with
// no read; the shared-conversation check is never asked about the caller themselves.
func TestGetDevices_OwnID(t *testing.T) {
	for _, callerOn := range []bool{true, false} {
		t.Run(fmt.Sprintf("callerOn=%v", callerOn), func(t *testing.T) {
			r := newClaimRig(t)
			r.setFlags(map[string]bool{uidA: callerOn})
			r.seed(t, uidA, devID, 1, pkgs(0, 4), []byte("alice-lr"))
			r.repo.calls, r.repo.listCalls, r.repo.activeCalls = 0, 0, 0
			got, err := r.svc.GetDevices(context.Background(), uidA, []string{uidA})
			if err != nil {
				t.Fatal(err)
			}
			mine := got[uidA]
			if !callerOn {
				if mine == nil || len(mine) != 0 || r.repo.calls != 0 {
					t.Fatalf("flag off: %v with %d reads, want an empty list and no read", mine, r.repo.calls)
				}
			} else if len(mine) != 1 || mine[0].PoolCount != 4 || !mine[0].HasLastResort || !mine[0].CreatedAt.Equal(t0) ||
				!mine[0].LastSeenAt.Equal(t0) || mine[0].Inactive || r.repo.activeCalls != 1 || r.repo.listCalls != 0 {
				t.Fatalf("own devices %+v (active reads %d, list reads %d), want every field and one ActiveDevices", mine, r.repo.activeCalls, r.repo.listCalls)
			}
			if len(r.perm.sharesCalls) != 0 || len(r.perm.calls) != 0 {
				t.Fatalf("the seams were asked about the caller: shares %v, permit %v", r.perm.sharesCalls, r.perm.calls)
			}
		})
	}
}

// TestGetDevices_PermitStillFirst: the send-rules check comes before the shared-conversation check, so a blocked target
// that also shares a conversation answers the same bytes as an unknown one, and the shared check is never asked, not even
// for the other (allowed) targets of the same request.
func TestGetDevices_PermitStillFirst(t *testing.T) {
	r := sharedRig(t, true, true, true)
	r.perm.refuse = map[string]error{uidBob: ErrCannotMessage, "uid-unknown": ErrCannotMessage}
	r.perm.shares[uidCarol] = true
	_, errBlocked := r.svc.GetDevices(context.Background(), uidA, []string{uidCarol, uidBob})
	_, errUnknown := r.svc.GetDevices(context.Background(), uidA, []string{"uid-unknown"})
	wantErr(t, errBlocked, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	if !bytes.Equal(wireBytes(t, errBlocked), wireBytes(t, errUnknown)) {
		t.Fatalf("blocked %q differs from unknown %q", wireBytes(t, errBlocked), wireBytes(t, errUnknown))
	}
	if len(r.perm.sharesCalls) != 0 {
		t.Fatalf("the shared-conversation check ran before every permission check passed: %v", r.perm.sharesCalls)
	}
	if r.repo.calls != 0 {
		t.Fatalf("a device was read: %d", r.repo.calls)
	}
}

// TestGetDevices_SharedReadFailureIsAnError: a failed shared-conversation read is an error (never an empty list, never
// "not shared"), is not CANNOT_MESSAGE, names neither uid, and no device is read. The injected failure text contains the
// real uids so the redaction is what the test checks.
func TestGetDevices_SharedReadFailureIsAnError(t *testing.T) {
	r := sharedRig(t, true, true, false)
	r.perm.sharesErr = errors.New("boom " + uidBob + " for " + uidA)
	got, err := r.svc.GetDevices(context.Background(), uidA, []string{uidBob})
	if err == nil || got != nil {
		t.Fatalf("got %v, %v; want an error and no result", got, err)
	}
	var ae *apierr.Error
	if errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE || errors.Is(err, ErrCannotMessage) {
		t.Fatalf("a failed read became a refusal: %v", err)
	}
	if strings.Contains(err.Error(), uidBob) || strings.Contains(err.Error(), uidA) {
		t.Fatalf("error text carries a uid: %v", err)
	}
	if r.repo.calls != 0 {
		t.Fatalf("%d device reads after a failed shared check", r.repo.calls)
	}
}

// TestListMine_InactiveMarker: ListMine sets Inactive from the clock (never stored), true exactly at InactiveAfter.
func TestListMine_InactiveMarker(t *testing.T) {
	s, _, clk := newTestService(t)
	mustRegister(t, s, devID, sigKey(1))
	clk.t = t0.Add(InactiveAfter - time.Second)
	mustRegister(t, s, devID2, sigKey(2))
	for _, tc := range []struct {
		at   time.Duration
		want [2]bool
	}{
		{InactiveAfter - 2*time.Second, [2]bool{false, false}},
		{InactiveAfter, [2]bool{true, false}},
		{2 * InactiveAfter, [2]bool{true, true}},
	} {
		clk.t = t0.Add(tc.at)
		got, err := s.ListMine(context.Background(), uidA)
		if err != nil || len(got) != 2 {
			t.Fatalf("ListMine = %v, %v", got, err)
		}
		if got[0].Inactive != tc.want[0] || got[1].Inactive != tc.want[1] {
			t.Fatalf("at +%v Inactive = [%v %v], want %v", tc.at, got[0].Inactive, got[1].Inactive, tc.want)
		}
	}
}

// TestClaim_ConversationID: every nil-error claim of another user carries the conversation id of (caller, target) (the
// flag-off target's empty success included); a self claim and every error carry "".
func TestClaim_ConversationID(t *testing.T) {
	ctx := context.Background()
	newRig := func(t *testing.T) *claimRig {
		r := newClaimRig(t)
		r.seed(t, uidA, devID, 1, pkgs(0, 2), nil)
		r.seed(t, uidBob, devB1, 2, pkgs(10, 2), nil)
		return r
	}
	t.Run("another user", func(t *testing.T) {
		r := newRig(t)
		cl, id, err := r.svc.Claim(ctx, uidA, uidBob, "")
		if err != nil || len(cl) != 1 || id != "c-"+uidA+"-"+uidBob {
			t.Fatalf("claimed %d, id %q, err %v", len(cl), id, err)
		}
	})
	t.Run("flag-off target is an empty success with the id", func(t *testing.T) {
		r := newRig(t)
		cl, id, err := r.svc.Claim(ctx, uidA, uidDan, "")
		if err != nil || cl == nil || len(cl) != 0 || id != "c-"+uidA+"-"+uidDan {
			t.Fatalf("claimed %v, id %q, err %v", cl, id, err)
		}
	})
	t.Run("self", func(t *testing.T) {
		r := newRig(t)
		_, id, err := r.svc.Claim(ctx, uidA, uidA, devID)
		if err != nil || id != "" {
			t.Fatalf("id %q, err %v; want empty", id, err)
		}
	})
	t.Run("errors carry no id", func(t *testing.T) {
		r := newRig(t)
		r.perm.refuse[uidCarol] = ErrCannotMessage
		_, id, err := r.svc.Claim(ctx, uidA, uidCarol, "")
		wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
		if id != "" {
			t.Fatalf("CANNOT_MESSAGE carried id %q", id)
		}
		_, id, err = r.svc.Claim(ctx, uidA, uidBob, "bad id!")
		wantValidation(t, err, "exclude_device_id")
		if id != "" {
			t.Fatalf("VALIDATION carried id %q", id)
		}
		_, id, err = r.svc.Claim(ctx, uidA, "bad uid!", "")
		wantValidation(t, err, "user_id")
		if id != "" {
			t.Fatalf("VALIDATION carried id %q", id)
		}
	})
	t.Run("per-target cap carries no id", func(t *testing.T) {
		r := newRig(t)
		r.svc = New(Deps{Repo: r.repo, Now: r.clk.now, Permission: r.perm, Flags: r.flags, ConversationID: fakeConvID, ClaimCap: ratelimit.NewDailyCap(1)})
		if _, _, err := r.svc.Claim(ctx, uidA, uidBob, ""); err != nil {
			t.Fatal(err)
		}
		_, id, err := r.svc.Claim(ctx, uidA, uidBob, "")
		wantErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", LimitClaimsPerTargetDaily)
		if id != "" {
			t.Fatalf("RATE_LIMITED carried id %q", id)
		}
	})
	t.Run("a repository failure carries no id", func(t *testing.T) {
		r := newRig(t)
		r.repo.err = errors.New("boom")
		_, id, err := r.svc.Claim(ctx, uidA, uidBob, "")
		if err == nil || id != "" {
			t.Fatalf("id %q, err %v; want an error and no id", id, err)
		}
	})
}
