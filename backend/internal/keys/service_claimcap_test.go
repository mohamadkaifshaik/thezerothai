package keys

import (
	"bytes"
	"context"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

const testPerTargetCap = 20

// newCapRig is newClaimRig with the per-(caller, target) claim cap at 20 on the rig's clock.
func newCapRig(t *testing.T) (*claimRig, *ratelimit.DailyCap) {
	t.Helper()
	r := newClaimRig(t)
	c := ratelimit.NewDailyCap(testPerTargetCap).WithClock(r.clk.now)
	r.svc = New(Deps{Repo: r.repo, Now: r.clk.now, Permission: r.perm, Flags: r.flags, ClaimCap: c, ConversationID: fakeConvID})
	return r, c
}

func wantPerTargetCap(t *testing.T, err error) {
	t.Helper()
	wantErr(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "limit", LimitClaimsPerTargetDaily)
}

// The 21st claim of one target in a day is refused with the standard RATE_LIMITED daily-cap error, without asking the
// permission seam or touching the pool; another target is still allowed for the same caller, and another caller for
// the same target.
func TestClaimPerTargetCap_21stRefusedOtherTargetAllowed(t *testing.T) {
	r, _ := newCapRig(t)
	r.seed(t, uidBob, devB1, 2, pkgs(0, 50), nil)
	r.seed(t, uidCarol, "device-carol-0000001", 3, pkgs(100, 5), nil)
	ctx := context.Background()
	for i := 0; i < testPerTargetCap; i++ {
		if _, _, err := r.svc.Claim(ctx, uidA, uidBob, ""); err != nil {
			t.Fatalf("claim %d: %v", i+1, err)
		}
	}
	asked, pool := len(r.perm.calls), len(r.repo.pool[devKey(uidBob, devB1)])
	_, _, err := r.svc.Claim(ctx, uidA, uidBob, "")
	wantPerTargetCap(t, err)
	if len(r.perm.calls) != asked || len(r.repo.pool[devKey(uidBob, devB1)]) != pool {
		t.Fatal("a capped claim asked permission or consumed a package")
	}
	if cl, _, err := r.svc.Claim(ctx, uidA, uidCarol, ""); err != nil || len(cl) != 1 {
		t.Fatalf("another target: %+v, %v; want allowed", cl, err)
	}
	if cl, _, err := r.svc.Claim(ctx, uidDan, uidBob, ""); err != nil || len(cl) != 1 {
		t.Fatalf("another caller of the same target: %+v, %v; want allowed", cl, err)
	}
	// The next IST day the pair is allowed again.
	r.clk.t = r.clk.t.Add(24 * time.Hour)
	if _, _, err := r.svc.Claim(ctx, uidA, uidBob, ""); err != nil {
		t.Fatalf("next day: %v", err)
	}
}

// The cap is counted before the permission check, so it is consumed by refused claims too, and once spent the answer
// for a blocked target, an unknown target and a real allowed target is the same error, byte for byte.
func TestClaimPerTargetCap_SameAnswerForEveryTarget(t *testing.T) {
	r, _ := newCapRig(t)
	r.seed(t, uidBob, devB1, 2, pkgs(0, 50), nil)
	r.perm.refuse = map[string]error{
		uidCarol:      fmt.Errorf("%w: blocked", ErrCannotMessage),
		"uid-unknown": fmt.Errorf("%w: no such user", ErrCannotMessage),
	}
	ctx := context.Background()
	for _, target := range []string{uidBob, uidCarol, "uid-unknown"} {
		for i := 0; i < testPerTargetCap; i++ {
			_, _, err := r.svc.Claim(ctx, uidA, target, "")
			if target == uidBob && err != nil {
				t.Fatalf("%s claim %d: %v", target, i+1, err)
			}
			if target != uidBob {
				wantErr(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
			}
		}
	}
	asked := len(r.perm.calls)
	var want []byte
	for _, target := range []string{uidBob, uidCarol, "uid-unknown"} {
		_, _, err := r.svc.Claim(ctx, uidA, target, "")
		wantPerTargetCap(t, err)
		got := wireBytes(t, err)
		if want == nil {
			want = got
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("%s: capped answer differs:\n got %q\nwant %q", target, got, want)
		}
	}
	if len(r.perm.calls) != asked {
		t.Fatal("a capped claim reached the permission check")
	}
	// Lifting the refusal does not give the spent pair a fresh allowance.
	delete(r.perm.refuse, uidCarol)
	_, _, err := r.svc.Claim(ctx, uidA, uidCarol, "")
	wantPerTargetCap(t, err)
}

// Claims for the caller's own other devices count against the (caller, caller) pair like any other target.
func TestClaimPerTargetCap_SelfClaimsCount(t *testing.T) {
	r, c := newCapRig(t)
	r.seed(t, uidA, devID, 1, nil, nil)
	r.seed(t, uidA, devID2, 5, pkgs(0, 50), nil)
	ctx := context.Background()
	for i := 0; i < testPerTargetCap; i++ {
		if _, _, err := r.svc.Claim(ctx, uidA, uidA, devID); err != nil {
			t.Fatalf("own claim %d: %v", i+1, err)
		}
	}
	_, _, err := r.svc.Claim(ctx, uidA, uidA, devID)
	wantPerTargetCap(t, err)
	if got := c.Spent(claimCapKey(uidA, uidA)); got != testPerTargetCap {
		t.Fatalf("spent = %d, want %d", got, testPerTargetCap)
	}
}

// A malformed target or exclude is VALIDATION and does not count; the key is a fixed-size hash of the ordered pair.
func TestClaimPerTargetCap_ValidationDoesNotCountAndKeyIsHashed(t *testing.T) {
	r, c := newCapRig(t)
	ctx := context.Background()
	for i := 0; i < testPerTargetCap+5; i++ {
		_, _, err := r.svc.Claim(ctx, uidA, uidBob, "bad id!")
		wantValidation(t, err, "exclude_device_id")
	}
	if got := c.Spent(claimCapKey(uidA, uidBob)); got != 0 {
		t.Fatalf("validation failures spent %d", got)
	}
	k := claimCapKey(uidA, uidBob)
	if k == claimCapKey(uidBob, uidA) || len(k) != 32 || bytes.Contains([]byte(k), []byte(uidA)) || bytes.Contains([]byte(k), []byte(uidBob)) {
		t.Fatalf("key %q: want a 32-character hash, ordered, naming neither uid", k)
	}
}
