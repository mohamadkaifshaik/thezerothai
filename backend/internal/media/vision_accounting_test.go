package media

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// W6-27 (security H-3): Vision units are counted for every call that got an answer; only calls that never reached
// Vision are released; an undecodable image is terminal; screening attempts per document are capped.

func (e *env) finalizeErr(t *testing.T, id string) (Result, error) {
	t.Helper()
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: id}})
	if err != nil {
		return Result{}, err
	}
	return res[0], nil
}

func (e *env) units() int64 { return e.repo.vision[monthKey(testNow)] }

func wantUnavailable(t *testing.T, err error) {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != connect.CodeUnavailable {
		t.Fatalf("err = %v, want UNAVAILABLE", err)
	}
}

func TestW627_VisionUnitAccounting(t *testing.T) {
	tests := []struct {
		name      string
		thumbErr  error
		wantUnits int64
		wantErr   bool // retryable UNAVAILABLE, doc stays PENDING
		wantRej   string
	}{
		{"both answered", nil, 2, false, ""},
		{"thumbnail transport failure: the full image's unit is counted", errors.New("vision 503"), 1, true, ""},
		{"thumbnail answered with a non-terminal error: both counted", &VisionAnsweredError{Code: 7}, 2, true, ""},
		{"thumbnail answered INVALID_ARGUMENT: both counted, REJECTED invalid", &VisionAnsweredError{Code: 3}, 2, false, reasonInvalid},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true})
			tg := e.upload(t, uidA, PurposePost, "a")
			if tt.thumbErr != nil {
				e.mod.errBy = map[string]error{uploadThumbObject(uidA, tg.MediaID, "jpg"): tt.thumbErr}
			}
			r, err := e.finalizeErr(t, tg.MediaID)
			if tt.wantErr {
				wantUnavailable(t, err)
				if d := e.repo.docs[tg.MediaID]; d.Status != string(StatusPending) || d.ScreeningUntil != nil {
					t.Fatalf("doc = %+v, want PENDING with the claim released", d)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if tt.wantRej != "" && (r.Status != StatusRejected || r.RejectionReason != tt.wantRej) {
				t.Fatalf("result = %+v, want REJECTED %q", r, tt.wantRej)
			}
			if got := e.units(); got != tt.wantUnits {
				t.Fatalf("vision units = %d, want %d", got, tt.wantUnits)
			}
		})
	}
}

// A transport failure on every call never reached Vision: everything is released.
func TestW627_TransportFailureStillReleases(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.err = errors.New("vision unreachable")
	_, err := e.finalizeErr(t, tg.MediaID)
	wantUnavailable(t, err)
	if got := e.units(); got != 0 {
		t.Fatalf("vision units = %d, want 0", got)
	}
	if e.repo.docs[tg.MediaID].Status != string(StatusPending) {
		t.Fatal("doc must stay PENDING")
	}
}

// A GIF whose thumbnail Vision cannot decode: the sheet was answered and billed, the GIF is REJECTED.
func TestW627_GIFThumbnailInvalidArgumentIsRejected(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
	d := e.repo.docs[tg.MediaID]
	e.mod.errBy = map[string]error{d.ThumbUploadPath: &VisionAnsweredError{Code: 3}}
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != StatusRejected || r.RejectionReason != reasonInvalid {
		t.Fatalf("result = %+v", r)
	}
	if got := e.units(); got != 2 {
		t.Fatalf("vision units = %d, want 2", got)
	}
}

// The looping attack of H-3: a thumbnail that never screens. Each attempt counts its answered unit; the attempt after the
// cap is REJECTED with no Vision call at all.
func TestW627_AttemptCapStopsTheLoop(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.errBy = map[string]error{uploadThumbObject(uidA, tg.MediaID, "jpg"): errors.New("vision 503")}
	for i := 1; i <= 3; i++ {
		_, err := e.finalizeErr(t, tg.MediaID)
		wantUnavailable(t, err)
		if got := e.units(); got != int64(i) {
			t.Fatalf("after attempt %d: vision units = %d, want %d", i, got, i)
		}
	}
	if d := e.repo.docs[tg.MediaID]; d.ScreenAttempts != 3 {
		t.Fatalf("screenAttempts = %d, want 3", d.ScreenAttempts)
	}
	calls := len(e.mod.calls)
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil {
		t.Fatal(err)
	}
	if r.Status != StatusRejected || r.RejectionReason != reasonAttempts {
		t.Fatalf("result = %+v, want REJECTED %q", r, reasonAttempts)
	}
	if len(e.mod.calls) != calls || len(e.mod.byteCalls) != 0 || e.units() != 3 {
		t.Fatalf("calls %d -> %d, units %d: the capped attempt must make no Vision call", calls, len(e.mod.calls), e.units())
	}
	// A replay is idempotent and still free.
	if r, err = e.finalizeErr(t, tg.MediaID); err != nil || r.RejectionReason != reasonAttempts || len(e.mod.calls) != calls {
		t.Fatalf("replay = %+v, %v", r, err)
	}
}

// A document that screens in one attempt is READY even with a cap of 1.
func TestW627_OneAttemptIsEnough(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 1})
	tg := e.upload(t, uidA, PurposePost, "a")
	r, err := e.finalizeErr(t, tg.MediaID)
	if err != nil || r.Status != StatusReady {
		t.Fatalf("result = %+v, %v", r, err)
	}
}
