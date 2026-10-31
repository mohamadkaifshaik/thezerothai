package media

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
)

// W6-50 (security W6-42, L-4): the upload quota (CreateUpload) and the per-uid Vision-units cap (FinalizeUpload) must put an account in the same
// tier. A users doc without createdAt (zero) used to be "established" for the first (20 images a day) and "new" for the second (12 units): the
// same account got the wider upload quota and the narrower units cap. Zero is now the new-account tier in both, the safer side, because an
// unknown age proves nothing about the account.

// TestW650_UploadQuotaAndUnitsCapUseTheSameTier: for each account age, a 3-image CreateUpload against a quota of 4 (established) or 2 (new) shows the upload
// tier, and a one-image finalize shows which units-cap tier was charged. Both must agree, and agree with the expected tier.
func TestW650_UploadQuotaAndUnitsCapUseTheSameTier(t *testing.T) {
	const window = 24 * time.Hour // newEnv's NewAccountWindow
	tests := []struct {
		name    string
		opts    envOpts
		wantNew bool
	}{
		{"createdAt missing (zero): the stricter tier everywhere", envOpts{accountUnknown: true}, true},
		{"one hour old", envOpts{accountAge: time.Hour}, true},
		{"one second inside the window", envOpts{accountAge: window - time.Second}, true},
		{"exactly at the window edge is established", envOpts{accountAge: window}, false},
		{"thirty days old", envOpts{accountAge: 30 * 24 * time.Hour}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.opts.perDay, tt.opts.newPerDay, tt.opts.cap = 4, 2, 100
			e := newEnv(t, tt.opts)

			// Upload quota: 3 images fit the established limit (4) and not the new-account limit (2).
			var items []UploadItem
			for _, tag := range []string{"a", "b", "c"} {
				items = append(items, item(jpegBytes("F"+tag), jpegBytes("T"+tag), "image/jpeg"))
			}
			_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{IdempotencyKey: "key-w650-0123456789", Purpose: PurposePost, Items: items})
			uploadNew := err != nil
			if uploadNew {
				_ = wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
			}

			// Units cap: one finalize charges one unit to the tier the account is in.
			e2 := newEnv(t, tt.opts)
			tg := e2.upload(t, uidA, PurposePost, "a")
			if r, err := e2.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
				t.Fatalf("finalize = %+v, %v, want READY", r, err)
			}
			newUnits, estUnits := e2.unitsSpent(true), e2.unitsSpent(false)
			unitsNew := newUnits == 1 && estUnits == 0
			if !unitsNew && (newUnits != 0 || estUnits != 1) {
				t.Fatalf("units charged: new tier %d, established tier %d, want exactly one of them to hold 1", newUnits, estUnits)
			}

			if uploadNew != unitsNew {
				t.Fatalf("the two caps disagree: upload quota new-account = %v, units cap new-account = %v", uploadNew, unitsNew)
			}
			if uploadNew != tt.wantNew {
				t.Fatalf("new-account tier = %v, want %v", uploadNew, tt.wantNew)
			}
		})
	}
}

// An age the directory cannot read stays an error for CreateUpload (the quota cannot be chosen) and the stricter tier for the units cap: unchanged by W6-50.
func TestW650_UnreadableAgeBehaviourIsUnchanged(t *testing.T) {
	e := newEnv(t, envOpts{dirErr: context.DeadlineExceeded})
	_, err := e.svc.CreateUpload(context.Background(), uidA, CreateUploadInput{
		IdempotencyKey: "key-w650-err-0123456789", Purpose: PurposePost, Items: []UploadItem{item(jpegBytes("Fa"), jpegBytes("Ta"), "image/jpeg")},
	})
	if err == nil {
		t.Fatal("CreateUpload must fail when the account's age cannot be read")
	}
	if !e.svc.(*service).isNewAccount(context.Background(), uidA) {
		t.Fatal("the units cap must treat an unreadable age as a new account")
	}
}

// The third place that reads the age, the unscreened publish once VISION_MONTHLY_CAP is spent, already treats zero as "not established" (it fails closed): the same
// answer as the two caps, pinned here so the three cannot drift apart.
func TestW650_ZeroCreatedAtIsNotEstablishedWhenTheMonthlyCapIsSpent(t *testing.T) {
	e := newEnv(t, envOpts{cap: 10, policy: config.VisionPolicyEstablished, accountUnknown: true})
	e.repo.vision[monthKey(testNow)] = 10
	tg := e.upload(t, uidA, PurposePost, "a")
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonCapacity {
		t.Fatalf("result = %+v, %v, want REJECTED %q (an account of unknown age is not established)", r, err, reasonCapacity)
	}
}
