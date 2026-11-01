package media

import (
	"context"
	"fmt"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/api/googleapi"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// W6-41 (ADR-0029 A5.7, security-w6-40-attempt-cap.md "The H-3 bound, verified" and I-5): a client that loops on FinalizeUpload cannot bill more than
// the documented bounds, whatever the outcome mix: 8 claims x 2 units = 16 per document, and the per-uid units cap across documents.

// finalizeUntilDone calls FinalizeUpload for one media id until the document is terminal or the units cap refuses, at most limit times (the loop of a
// modified client, which has no ceiling of its own). It returns the number of calls made and the last error (nil when the document ended).
func (e *env) finalizeUntilDone(t *testing.T, id string, limit int) (calls int, last error) {
	t.Helper()
	for calls < limit {
		calls++
		r, err := e.finalizeErr(t, id)
		if err != nil {
			last = err
			if connect.CodeOf(err) == connect.CodeResourceExhausted {
				return calls, err
			}
			continue
		}
		if r.Status != StatusPending {
			return calls, nil
		}
	}
	return calls, last
}

// A client looping on a Vision 5xx outage (refunded to both counters) never bills a unit and never exhausts the units cap, but it is still stopped by
// the document's claims ceiling: REJECTED `attempts` after 8 claims, whatever the loop does next.
func TestW641_H3_LoopOnAnOutageStopsAtTheClaimsCeiling(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 4}) // a cap of 4 units: the loop would trip it at once if outages were charged
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.err = &googleapi.Error{Code: 503}
	calls, _ := e.finalizeUntilDone(t, tg.MediaID, 200)
	d := e.doc(tg.MediaID)
	if d.Status != string(StatusRejected) || d.RejectionReason != reasonAttempts || d.ScreenAttempts != 8 || calls != 9 {
		t.Fatalf("doc %+v after %d calls, want REJECTED %q after 8 claims (the 9th call rejects)", d, calls, reasonAttempts)
	}
	if e.units() != 0 || e.unitsSpent(false) != 0 {
		t.Errorf("units: monthly %d, per-uid %d, want 0 (outages are refunded)", e.units(), e.unitsSpent(false))
	}
	if n := len(e.mod.calls); n > 16 {
		t.Errorf("%d Vision calls, want at most 16 (8 claims x 2)", n)
	}
	// Once terminal, more loops cost nothing.
	before := len(e.mod.calls)
	for range 20 {
		_, _ = e.finalizeErr(t, tg.MediaID)
	}
	if len(e.mod.calls) != before || e.repo.claims != 8 {
		t.Errorf("a loop on a terminal document called Vision or claimed: calls %d -> %d, claims %d", before, len(e.mod.calls), e.repo.claims)
	}
}

// A client looping on billed failures (timeouts: possibly billed, never refunded) across many documents is stopped by the per-uid units cap before
// the claim: the total billed is at most the cap, and the refused calls claim and call nothing. Both tiers.
func TestW641_H3_LoopAcrossDocumentsStopsAtTheUnitsCap(t *testing.T) {
	for _, tt := range []struct {
		name string
		opts envOpts
		docs int
		cap  int64
		tier bool
	}{
		{"established account, cap 20", envOpts{screenThumb: true, unitsPerDay: 20}, 8, 20, false},
		{"new account, cap 6", envOpts{screenThumb: true, accountAge: 1, newUnitsDay: 6, unitsPerDay: 100, newPerDay: 8}, 5, 6, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, tt.opts)
			e.mod.err = context.DeadlineExceeded
			ids := make([]string, tt.docs)
			for i := range ids {
				ids[i] = e.upload(t, uidA, PurposePost, fmt.Sprintf("doc%d", i)).MediaID
			}
			refused := 0
			for _, id := range ids {
				if _, last := e.finalizeUntilDone(t, id, 50); last != nil {
					ae := wantAPI(t, last, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
					if ae.Metadata["limit"] != "media_vision_units_daily" {
						t.Fatalf("limit %q, want media_vision_units_daily", ae.Metadata["limit"])
					}
					refused++
				}
			}
			if got := e.unitsSpent(tt.tier); got > tt.cap {
				t.Fatalf("per-uid units = %d, over the cap %d", got, tt.cap)
			}
			if got := e.units(); got > tt.cap {
				t.Fatalf("monthly units = %d, over the per-uid cap %d: the loop billed more than the cap", got, tt.cap)
			}
			if int64(len(e.mod.calls)) > tt.cap {
				t.Fatalf("%d Vision calls, want at most the cap %d", len(e.mod.calls), tt.cap)
			}
			if refused == 0 {
				t.Fatal("the cap never refused: the loop was not bounded by it")
			}
			// Once the cap tripped, another round over every document claims and calls nothing.
			claims, calls := e.repo.claims, len(e.mod.calls)
			for _, id := range ids {
				_, _ = e.finalizeErr(t, id)
			}
			if e.repo.claims != claims || len(e.mod.calls) != calls {
				t.Errorf("calls after the cap tripped: claims %d -> %d, vision %d -> %d", claims, e.repo.claims, calls, len(e.mod.calls))
			}
		})
	}
}

// The mixed script of the review: outages and partial assessments (one valid answer, the other image failing) alternate. The document ends terminal
// within 8 claims, 3 assessed attempts and 16 billed units.
func TestW641_H3_AlternatingOutagesAndAssessedAttemptsAreTerminalWithin8Claims(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3, unitsPerDay: 200})
	tg := e.upload(t, uidA, PurposePost, "a")
	thumb := uploadThumbObject(uidA, tg.MediaID, "jpg")
	for i := 0; i < 60; i++ {
		if i%2 == 0 {
			e.mod.err, e.mod.errBy = &googleapi.Error{Code: 503}, nil // no valid assessment: a retry
		} else {
			e.mod.err, e.mod.errBy = nil, map[string]error{thumb: &VisionAnsweredError{Code: 7}} // full image valid, thumbnail billed-invalid: an attempt
		}
		if r, err := e.finalizeErr(t, tg.MediaID); err == nil && r.Status != StatusPending {
			break
		}
	}
	d := e.doc(tg.MediaID)
	if d.Status != string(StatusRejected) || d.RejectionReason != reasonAttempts {
		t.Fatalf("doc %+v, want terminal REJECTED %q", d, reasonAttempts)
	}
	if d.ScreenAttempts > 8 || d.ScreenAssessed > 3 {
		t.Errorf("claims %d assessed %d, want at most 8 and 3", d.ScreenAttempts, d.ScreenAssessed)
	}
	if got := e.units(); got > 16 {
		t.Errorf("billed units %d, want at most 16", got)
	}
	if n := len(e.mod.calls); n > 16 {
		t.Errorf("%d Vision calls, want at most 16", n)
	}
}

// security-w6-40 I-5: a lost claim race (ErrConflict from ClaimScreening) after the units were charged returns the WHOLE charge: nothing was sent, so
// a looping client that keeps losing the race never spends the cap, and no Vision call is made.
func TestW641_I5_LostClaimRaceRefundsTheWholeCharge(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, unitsPerDay: 4})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.repo.claimFn = func(string) error { return ErrConflict }
	for range 10 { // 10 x 2 units would be 20 against a cap of 4
		_, _ = e.finalizeErr(t, tg.MediaID)
	}
	if e.repo.claims == 0 {
		t.Fatal("the claim hook never ran: the test proved nothing")
	}
	if got := e.unitsSpent(false); got != 0 {
		t.Fatalf("per-uid units = %d after lost claim races, want 0 (full refund)", got)
	}
	if len(e.mod.calls) != 0 || e.units() != 0 {
		t.Errorf("a lost claim race called Vision (%d calls) or counted monthly units (%d)", len(e.mod.calls), e.units())
	}
	if d := e.doc(tg.MediaID); d.Status != string(StatusPending) || d.ScreenAttempts != 0 || d.ScreenAssessed != 0 {
		t.Errorf("doc %+v, want untouched PENDING", d)
	}
	// With the race over, the document still screens within the cap.
	e.repo.claimFn = nil
	if r, err := e.finalizeErr(t, tg.MediaID); err != nil || r.Status != StatusReady {
		t.Errorf("after the race: %+v, %v, want READY", r, err)
	}
	if got := e.unitsSpent(false); got != 2 {
		t.Errorf("per-uid units = %d, want 2 (only the successful screening)", got)
	}
}
