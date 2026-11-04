package media

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// Security, L-4: the per-uid Vision-units cap (FinalizeUpload) and the unscreened publish once VISION_MONTHLY_CAP is spent must put an
// account in the same tier. A users doc without createdAt (zero) is the new-account tier, the safer side, because an unknown age proves
// nothing about the account.

// TestW650_UnitsCapTier: for each account age, a one-image finalize shows which units-cap tier was charged.
func TestW650_UnitsCapTier(t *testing.T) {
	const window = 24 * time.Hour // newEnv's NewAccountWindow
	tests := []struct {
		name    string
		opts    envOpts
		wantNew bool
	}{
		{"createdAt missing (zero): the stricter tier", envOpts{accountUnknown: true}, true},
		{"one hour old", envOpts{accountAge: time.Hour}, true},
		{"one second inside the window", envOpts{accountAge: window - time.Second}, true},
		{"exactly at the window edge is established", envOpts{accountAge: window}, false},
		{"thirty days old", envOpts{accountAge: 30 * 24 * time.Hour}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.opts.cap = 100
			e := newEnv(t, tt.opts)
			tg := e.upload(t, uidA, PurposePost, "a")
			if r, err := e.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
				t.Fatalf("finalize = %+v, %v, want READY", r, err)
			}
			newUnits, estUnits := e.unitsSpent(true), e.unitsSpent(false)
			unitsNew := newUnits == 1 && estUnits == 0
			if !unitsNew && (newUnits != 0 || estUnits != 1) {
				t.Fatalf("units charged: new tier %d, established tier %d, want exactly one of them to hold 1", newUnits, estUnits)
			}
			if unitsNew != tt.wantNew {
				t.Fatalf("new-account tier = %v, want %v", unitsNew, tt.wantNew)
			}
		})
	}
}

// An age the directory cannot read is the stricter tier for the units cap.
func TestW650_UnreadableAgeIsTheNewAccountTier(t *testing.T) {
	e := newEnv(t, envOpts{dirErr: context.DeadlineExceeded})
	if !e.svc.(*service).isNewAccount(context.Background(), uidA) {
		t.Fatal("the units cap must treat an unreadable age as a new account")
	}
}

// The unscreened publish once VISION_MONTHLY_CAP is spent treats zero as "not established" (it fails closed): the same answer as the
// units cap, pinned here so the two cannot drift apart.
func TestW650_ZeroCreatedAtIsNotEstablishedWhenTheMonthlyCapIsSpent(t *testing.T) {
	e := newEnv(t, envOpts{cap: 10, policy: config.VisionPolicyEstablished, accountUnknown: true})
	e.repo.vision[monthKey(testNow)] = 10
	tg := e.upload(t, uidA, PurposePost, "a")
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonCapacity {
		t.Fatalf("result = %+v, %v, want REJECTED %q (an account of unknown age is not established)", r, err, reasonCapacity)
	}
}
