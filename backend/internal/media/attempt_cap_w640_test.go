package media

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// W6-40 (ADR-0029 Amendment 1 A5, revises W6-27 / security H-3): an attempt is consumed only by a valid assessment; outages, timeouts, internal
// errors, billed-but-invalid answers and a busy GIF slot consume none; a blocking verdict is final; a per-uid units cap refuses before the claim.

func ptr[T any](v T) *T { return &v }

// unitsSpent is what the per-uid Vision-units cap holds for uidA, on the tier (established or new account) the env's accounts are on.
func (e *env) unitsSpent(newAccount bool) int64 {
	s := e.svc.(*service)
	if newAccount {
		return s.unitsCapNew.Spent(uidA)
	}
	return s.unitsCap.Spent(uidA)
}

// doc is the stored media document (a copy).
func (e *env) doc(id string) Doc { return *e.repo.docs[id] }

// TestW640_BusyGIFSlotNeverConsumesAnAttemptAndWritesNothing is the founder's acceptance criterion for A5.1: a GIF that meets a busy slot any
// number of times is never REJECTED for attempts, and the busy path writes nothing. The account is a NEW account (12 units a day), so a busy
// call that kept its units charge would trip the cap at the 7th call: the test fails if the charge is not refunded.
func TestW640_BusyGIFSlotNeverConsumesAnAttemptAndWritesNothing(t *testing.T) {
	const busyCalls = 10
	e := newEnv(t, envOpts{gifWait: time.Millisecond, accountAge: time.Hour, maxAttempts: 3})
	tg := e.createGIF(t, uidA, "busy", ContentTypeJPEG)
	svc := e.svc.(*service)
	svc.gifSlot <- struct{}{} // another GIF holds this instance's screening slot for the whole test

	for i := 1; i <= busyCalls; i++ {
		_, err := e.finalizeErr(t, tg.MediaID)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
		if e.repo.claims != 0 || e.repo.releases != 0 || e.repo.resolves != 0 {
			t.Fatalf("busy call %d: claims %d, releases %d, resolves %d, want 0/0/0 (a busy slot writes nothing)", i, e.repo.claims, e.repo.releases, e.repo.resolves)
		}
	}
	if d := e.doc(tg.MediaID); d.ScreenAttempts != 0 || d.ScreenAssessed != 0 || d.Status != string(StatusPending) || d.ScreeningUntil != nil {
		t.Fatalf("doc after %d busy calls = %+v, want PENDING, 0 claims, 0 assessed, no claim", busyCalls, d)
	}
	if len(e.mod.calls) != 0 || len(e.mod.byteCalls) != 0 || e.units() != 0 {
		t.Fatalf("busy calls reached Vision: calls %d/%d, units %d", len(e.mod.calls), len(e.mod.byteCalls), e.units())
	}
	if got := e.unitsSpent(true); got != 0 {
		t.Fatalf("per-uid units after %d busy calls = %d, want 0 (the charge is refunded)", busyCalls, got)
	}

	// The slot frees up: the very same document screens normally and is READY, not REJECTED for attempts.
	<-svc.gifSlot
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusReady {
		t.Fatalf("after the slot freed: %+v, %v, want READY", r, err)
	}
	if d := e.doc(tg.MediaID); d.ScreenAttempts != 1 || d.ScreenAssessed != 0 {
		t.Fatalf("doc = claims %d, assessed %d, want 1 and 0 (a READY document consumes no attempt)", d.ScreenAttempts, d.ScreenAssessed)
	}
	if e.repo.claims != 1 || e.repo.resolves != 1 || e.repo.releases != 0 {
		t.Fatalf("honest path writes: claims %d, resolves %d, releases %d, want 1/1/0", e.repo.claims, e.repo.resolves, e.repo.releases)
	}
}

// Without the charge refund the same scenario would exhaust the new-account cap: this pins the other half of the criterion (a busy slot is
// not a Vision-units spend), with a cap of exactly one document's units.
func TestW640_BusyGIFSlotDoesNotSpendTheUnitsCap(t *testing.T) {
	e := newEnv(t, envOpts{gifWait: time.Millisecond, accountAge: time.Hour, newUnitsDay: 2})
	tg := e.createGIF(t, uidA, "busy2", ContentTypeJPEG)
	svc := e.svc.(*service)
	svc.gifSlot <- struct{}{}
	for range 5 {
		_, err := e.finalizeErr(t, tg.MediaID)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY)
	}
	<-svc.gifSlot
	if r, err := e.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
		t.Fatalf("the one document's 2 units must still be available: %+v, %v", r, err)
	}
}

func wantRetryAfter(t *testing.T, err error, want time.Duration) {
	t.Helper()
	wantUnavailable(t, err)
	var ae *apierr.Error
	_ = errors.As(err, &ae)
	if ae.RetryAfter != want {
		t.Fatalf("retry_after = %v, want %v", ae.RetryAfter, want)
	}
}

// TestW640_NoValidAssessmentConsumesARetryNotAnAttempt: an outage, our own deadline, a billed-but-invalid answer and an internal error before the
// call each leave screenAssessed at 0 and take one claim (a retry); the doc is REJECTED `attempts` only at the claims ceiling (3 + 5 = 8), and the
// UNAVAILABLE carries retry_after.
func TestW640_NoValidAssessmentConsumesARetryNotAnAttempt(t *testing.T) {
	tests := []struct {
		name         string
		setup        func(e *env, id string)
		wantMonthly  int64 // VISION_MONTHLY_CAP counter after the 8 claims
		wantUnitsCap int64 // per-uid units cap after the 8 claims
	}{
		{"outage (transport error)", func(e *env, _ string) { e.mod.err = errors.New("vision unreachable") }, 0, 0},
		{"our 10 s deadline", func(e *env, _ string) { e.mod.err = fmt.Errorf("media: vision annotate: %w", context.DeadlineExceeded) }, 0, 16},
		{"billed answer with a non-terminal error", func(e *env, _ string) { e.mod.err = &VisionAnsweredError{Code: 7} }, 16, 16},
		{"billed answer without an annotation", func(e *env, _ string) { e.mod.err = &VisionAnsweredError{Code: -1} }, 16, 16},
		{"internal error (Vision counter unreadable)", func(e *env, _ string) { e.repo.visionErr = errors.New("firestore unavailable") }, 0, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3})
			tg := e.upload(t, uidA, PurposePost, "a")
			tt.setup(e, tg.MediaID)
			for i := 1; i <= 8; i++ {
				_, err := e.finalizeErr(t, tg.MediaID)
				wantRetryAfter(t, err, 5*time.Second)
				d := e.doc(tg.MediaID)
				if d.ScreenAttempts != int64(i) || d.ScreenAssessed != 0 || d.Status != string(StatusPending) || d.ScreeningUntil != nil {
					t.Fatalf("after claim %d: %+v, want %d claims, 0 assessed, PENDING, claim released", i, d, i)
				}
			}
			if got := e.units(); got != tt.wantMonthly {
				t.Fatalf("monthly vision units = %d, want %d", got, tt.wantMonthly)
			}
			if got := e.unitsSpent(false); got != tt.wantUnitsCap {
				t.Fatalf("per-uid units = %d, want %d", got, tt.wantUnitsCap)
			}
			calls := len(e.mod.calls)
			r, err := e.finalizeErr(t, tg.MediaID)
			if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonAttempts {
				t.Fatalf("claim 9 = %+v, %v, want REJECTED %q", r, err, reasonAttempts)
			}
			if len(e.mod.calls) != calls || e.repo.claims != 8 {
				t.Fatalf("the rejected call must make no Vision call and no claim: calls %d -> %d, claims %d", calls, len(e.mod.calls), e.repo.claims)
			}
		})
	}
}

// MEDIA_MAX_SCREEN_RETRIES moves the claims ceiling; 0 means the ceiling is the attempts alone.
func TestW640_RetriesConfigSetsTheClaimsCeiling(t *testing.T) {
	for _, tt := range []struct {
		retries    int
		wantClaims int64
	}{{0, 3}, {2, 5}, {10, 13}} {
		t.Run(fmt.Sprintf("retries=%d", tt.retries), func(t *testing.T) {
			e := newEnv(t, envOpts{maxAttempts: 3, maxRetries: ptr(tt.retries), unitsPerDay: 200})
			tg := e.upload(t, uidA, PurposePost, "a")
			e.mod.err = errors.New("vision unreachable")
			for range tt.wantClaims {
				_, err := e.finalizeErr(t, tg.MediaID)
				wantUnavailable(t, err)
			}
			r, err := e.finalizeErr(t, tg.MediaID)
			if err != nil || r.RejectionReason != reasonAttempts || e.doc(tg.MediaID).ScreenAttempts != tt.wantClaims {
				t.Fatalf("result %+v, %v, claims %d, want REJECTED after %d claims", r, err, e.doc(tg.MediaID).ScreenAttempts, tt.wantClaims)
			}
		})
	}
}

// TestW640_OnlyAssessedAttemptsCountTowardsTheCapOfThree: a partial answer (one valid assessment, the other call failing) is an attempt; outages in
// between are retries. The cap of 3 binds at the third ASSESSED attempt, well below the claims ceiling of 8.
func TestW640_OnlyAssessedAttemptsCountTowardsTheCapOfThree(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3})
	tg := e.upload(t, uidA, PurposePost, "a")
	thumb := uploadThumbObject(uidA, tg.MediaID, "jpg")

	e.mod.err = errors.New("vision unreachable") // claim 1: no valid assessment
	_, err := e.finalizeErr(t, tg.MediaID)
	wantUnavailable(t, err)
	e.mod.err = nil
	e.mod.errBy = map[string]error{thumb: errors.New("vision 503")} // claims 2-4: the full image answers, the thumbnail does not
	for i := int64(1); i <= 3; i++ {
		_, err = e.finalizeErr(t, tg.MediaID)
		wantUnavailable(t, err)
		if d := e.doc(tg.MediaID); d.ScreenAssessed != i || d.ScreenAttempts != i+1 {
			t.Fatalf("after assessed attempt %d: claims %d, assessed %d, want %d and %d", i, d.ScreenAttempts, d.ScreenAssessed, i+1, i)
		}
	}
	calls := len(e.mod.calls)
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonAttempts {
		t.Fatalf("result = %+v, %v, want REJECTED %q at 3 assessed attempts and 4 claims", r, err, reasonAttempts)
	}
	if len(e.mod.calls) != calls {
		t.Fatal("the capped call must make no Vision call")
	}
}

// A completed screening that cannot publish keeps the doc PENDING and consumes an attempt (A5.3 row 4).
func TestW640_PublishFailureAfterACompletedScreeningConsumesAnAttempt(t *testing.T) {
	e := newEnv(t, envOpts{maxAttempts: 3})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.obj.publishErr = errors.New("gcs 503")
	_, err := e.finalizeErr(t, tg.MediaID)
	if err == nil {
		t.Fatal("want an error")
	}
	if d := e.doc(tg.MediaID); d.ScreenAssessed != 1 || d.ScreenAttempts != 1 || d.Status != string(StatusPending) {
		t.Fatalf("doc = %+v, want PENDING, 1 claim, 1 assessed", d)
	}
}

// TestW640_BlockingVerdictIsFinalEvenIfTheOtherCallFailed: A5.3 row 2. Before W6-40 the other call's error won and the doc retried.
func TestW640_BlockingVerdictIsFinalEvenIfTheOtherCallFailed(t *testing.T) {
	for _, tt := range []struct {
		name     string
		thumbErr error
	}{
		{"thumbnail transport failure", errors.New("vision 503")},
		{"thumbnail billed non-terminal answer", &VisionAnsweredError{Code: 7}},
		{"thumbnail deadline", context.DeadlineExceeded},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true})
			tg := e.upload(t, uidA, PurposePost, "a")
			e.mod.by = map[string]SafeSearch{uploadObject(uidA, tg.MediaID, "jpg"): {Adult: LikelihoodVeryLikely}}
			e.mod.errBy = map[string]error{uploadThumbObject(uidA, tg.MediaID, "jpg"): tt.thumbErr}
			r, err := e.finalizeErr(t, tg.MediaID)
			if err != nil {
				t.Fatalf("err = %v, want a terminal REJECTED result", err)
			}
			if r.Status != StatusRejected || r.RejectionReason != reasonPolicy {
				t.Fatalf("result = %+v, want REJECTED %q", r, reasonPolicy)
			}
			if d := e.doc(tg.MediaID); d.Status != string(StatusRejected) || e.repo.releases != 0 {
				t.Fatalf("doc = %+v, releases %d, want REJECTED with no claim release", d, e.repo.releases)
			}
		})
	}
}

// TestW640_UnitsCapRefusesBeforeTheClaim: the per-uid daily cap counts a document's 2 units before the claim, refuses with RATE_LIMITED
// media_vision_units_daily, and writes nothing. The new-account tier is the smaller one.
func TestW640_UnitsCapRefusesBeforeTheClaim(t *testing.T) {
	for _, tt := range []struct {
		name string
		opts envOpts
		tier bool
	}{
		{"established account", envOpts{screenThumb: true, unitsPerDay: 4}, false},
		{"new account (its own, smaller, cap)", envOpts{screenThumb: true, accountAge: time.Hour, newUnitsDay: 4, unitsPerDay: 100}, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, tt.opts)
			a, b, c := e.upload(t, uidA, PurposePost, "a"), e.upload(t, uidA, PurposePost, "b"), e.upload(t, uidA, PurposePost, "c")
			for _, tg := range []UploadTarget{a, b} {
				if r, err := e.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
					t.Fatalf("within the cap: %+v, %v", r, err)
				}
			}
			claims, calls, units := e.repo.claims, len(e.mod.calls), e.units()
			_, err := e.finalizeErr(t, c.MediaID)
			ae := wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
			if ae.Metadata["limit"] != "media_vision_units_daily" || ae.RetryAfter <= 0 {
				t.Fatalf("limit %q, retry_after %v, want media_vision_units_daily and a positive retry_after", ae.Metadata["limit"], ae.RetryAfter)
			}
			if e.repo.claims != claims || len(e.mod.calls) != calls || e.units() != units {
				t.Fatalf("a refused call must not claim or call Vision: claims %d -> %d, calls %d -> %d", claims, e.repo.claims, calls, len(e.mod.calls))
			}
			if d := e.doc(c.MediaID); d.Status != string(StatusPending) || d.ScreenAttempts != 0 {
				t.Fatalf("refused doc = %+v, want untouched PENDING", d)
			}
			if got := e.unitsSpent(tt.tier); got != 4 {
				t.Fatalf("units = %d, want 4 (the refused call is not counted)", got)
			}
		})
	}
}

// The tiers are separate: an established account with the same caps would not have been refused at 4 units.
func TestW640_UnitsCapTierFollowsTheAccountAge(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 100, newUnitsDay: 2})
	for i := range 3 {
		tg := e.upload(t, uidA, PurposePost, fmt.Sprintf("%d", i))
		if r, err := e.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
			t.Fatalf("established account, doc %d: %+v, %v", i, r, err)
		}
	}
}

// Refunds (A5.5): a call that never went out is refunded, a timeout and an answered call are not.
func TestW640_UnitsAreRefundedOnlyWhenNothingWasSent(t *testing.T) {
	t.Run("outages never exhaust the cap", func(t *testing.T) {
		e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 4, maxAttempts: 3, maxRetries: ptr(10)})
		tg := e.upload(t, uidA, PurposePost, "a")
		e.mod.err = errors.New("vision unreachable")
		for range 10 { // 10 x 2 units would be 20 against a cap of 4
			_, err := e.finalizeErr(t, tg.MediaID)
			wantUnavailable(t, err)
		}
		if got := e.unitsSpent(false); got != 0 {
			t.Fatalf("per-uid units = %d, want 0", got)
		}
	})
	t.Run("timeouts are never refunded", func(t *testing.T) {
		e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 4})
		tg := e.upload(t, uidA, PurposePost, "a")
		e.mod.err = context.DeadlineExceeded
		for range 2 {
			_, err := e.finalizeErr(t, tg.MediaID)
			wantUnavailable(t, err)
		}
		claims := e.repo.claims
		_, err := e.finalizeErr(t, tg.MediaID)
		wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
		if e.repo.claims != claims {
			t.Fatal("the refused call must not claim")
		}
	})
	t.Run("a lost claim race and a Vision-counter error refund", func(t *testing.T) {
		e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 4})
		tg := e.upload(t, uidA, PurposePost, "a")
		e.repo.visionErr = errors.New("firestore unavailable")
		for range 5 {
			_, err := e.finalizeErr(t, tg.MediaID)
			wantUnavailable(t, err)
		}
		if got := e.unitsSpent(false); got != 0 {
			t.Fatalf("per-uid units = %d, want 0", got)
		}
	})
}

// TestW640_PerDocBillableUnitsAreAtMost16 is the H-3 bound of A5.7: at most MEDIA_MAX_SCREEN_ATTEMPTS + MEDIA_MAX_SCREEN_RETRIES = 8 claims of 2 units.
// The worst script: 5 retries that are billed on both images (billed-but-invalid answers), then 3 assessed attempts that bill both images (one valid,
// one billed-invalid). Unit counting is #535's: every answered call counts.
func TestW640_PerDocBillableUnitsAreAtMost16(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3, unitsPerDay: 200})
	tg := e.upload(t, uidA, PurposePost, "a")
	thumb := uploadThumbObject(uidA, tg.MediaID, "jpg")

	e.mod.err = &VisionAnsweredError{Code: 7} // both images answered with an error: 2 units, no valid assessment
	for range 5 {
		_, err := e.finalizeErr(t, tg.MediaID)
		wantUnavailable(t, err)
	}
	e.mod.err = nil
	e.mod.errBy = map[string]error{thumb: &VisionAnsweredError{Code: 7}} // the full image is a valid assessment: an attempt
	for range 3 {
		_, err := e.finalizeErr(t, tg.MediaID)
		wantUnavailable(t, err)
	}
	if d := e.doc(tg.MediaID); d.ScreenAttempts != 8 || d.ScreenAssessed != 3 {
		t.Fatalf("doc = %d claims, %d assessed, want 8 and 3", d.ScreenAttempts, d.ScreenAssessed)
	}
	if got := e.units(); got != 16 {
		t.Fatalf("vision units = %d, want exactly 16 (8 claims x 2)", got)
	}
	calls := len(e.mod.calls)
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonAttempts {
		t.Fatalf("claim 9 = %+v, %v, want REJECTED %q", r, err, reasonAttempts)
	}
	if len(e.mod.calls) != calls || e.units() != 16 {
		t.Fatalf("the ninth call must bill nothing: calls %d -> %d, units %d", calls, len(e.mod.calls), e.units())
	}
}
