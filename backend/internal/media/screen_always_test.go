package media

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/api/googleapi"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
)

// Every image is screened on every finalize and nothing can publish unscreened: there is no monthly cap, no policy and no
// setting that turns screening off. The usage counter only meters spend.

// hugeCounter is far above the old monthly cap (10,000 units): the counter must not matter any more.
const hugeCounter = int64(1) << 40

func TestFinalize_HugeUsageCounterStillScreensAndPublishesReady(t *testing.T) {
	tests := []struct {
		name    string
		prepare func(t *testing.T, e *env) UploadTarget
		units   int64
		sheet   bool // a GIF is screened by its contact sheet (bytes), not by object
	}{
		{"post photo", func(t *testing.T, e *env) UploadTarget { return e.upload(t, uidA, PurposePost, "a") }, 1, false},
		{"avatar", func(t *testing.T, e *env) UploadTarget { return e.upload(t, uidA, PurposeAvatar, "a") }, 1, false},
		{"gif", func(t *testing.T, e *env) UploadTarget { return e.createGIF(t, uidA, "a", ContentTypeJPEG) }, 2, true},
	}
	for _, tt := range tests {
		for _, age := range []time.Duration{30 * 24 * time.Hour, 2 * 24 * time.Hour} { // established and new account alike
			t.Run(fmt.Sprintf("%s/age %v", tt.name, age), func(t *testing.T) {
				e := newEnv(t, envOpts{accountAge: age})
				e.repo.vision[monthKey(testNow)] = hugeCounter
				tg := tt.prepare(t, e)
				res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
				if err != nil {
					t.Fatal(err)
				}
				r := res[0]
				if r.Status != StatusReady || r.Ref == nil || len(e.obj.public) != 2 {
					t.Fatalf("result = %+v public=%v, want READY with both objects published", r, e.obj.public)
				}
				if len(e.mod.calls)+len(e.mod.byteCalls) == 0 {
					t.Fatal("the image was not sent to Vision")
				}
				if got := e.repo.vision[monthKey(testNow)]; got != hugeCounter+tt.units {
					t.Fatalf("counter = %d, want %d (it still meters spend)", got, hugeCounter+tt.units)
				}
			})
		}
	}
}

// TestFinalize_NoFailureEverPublishesUnscreened: for an established account, whatever goes wrong while screening, the image is
// never published and never READY_UNSCREENED. It stays PENDING (retryable) or is REJECTED.
func TestFinalize_NoFailureEverPublishesUnscreened(t *testing.T) {
	failures := []struct {
		name string
		err  error
	}{
		{"Vision 429 (the project's 30 per minute quota)", &googleapi.Error{Code: 429}},
		{"Vision 500", &googleapi.Error{Code: 500}},
		{"Vision 503", &googleapi.Error{Code: 503}},
		{"Vision 403", &googleapi.Error{Code: 403}},
		{"our deadline", fmt.Errorf("media: vision annotate: %w", context.DeadlineExceeded)},
		{"client hung up", context.Canceled},
		{"connection reset", connReset()},
		{"connect refused", dialRefused()},
		{"quota error answered inside a 200 response", &VisionAnsweredError{Code: 8}},
		{"response without an annotation", &VisionAnsweredError{Code: -1}},
		{"unrecognised error", errors.New("boom")},
	}
	for _, f := range failures {
		for _, kind := range []string{"photo", "gif"} {
			t.Run(f.name+"/"+kind, func(t *testing.T) {
				e := newEnv(t, envOpts{screenThumb: true})
				var tg UploadTarget
				if kind == "gif" {
					tg = e.createGIF(t, uidA, "a", ContentTypeJPEG)
					e.mod.bytesErr = f.err
				} else {
					tg = e.upload(t, uidA, PurposePost, "a")
				}
				e.mod.err = f.err
				// The counter write failing as well changes nothing.
				e.repo.addVisionErr = errors.New("firestore unavailable")
				res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
				wantUnavailable(t, err)
				if len(res) != 0 || len(e.obj.public) != 0 {
					t.Fatalf("published despite a screening failure: %+v %v", res, e.obj.public)
				}
				if d := e.doc(tg.MediaID); d.Status != string(StatusPending) || d.PublicPath != "" || d.ScreeningUntil != nil {
					t.Fatalf("doc = %+v, want PENDING with no public path and the claim released", d)
				}
			})
		}
	}
}

// A request with under minVisionBudget left cannot start Vision: it answers UNAVAILABLE and publishes nothing.
func TestFinalize_NoRequestTimeLeftNeverPublishes(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	wantUnavailable(t, err)
	if len(e.mod.calls) != 0 || len(e.obj.public) != 0 || e.doc(tg.MediaID).Status != string(StatusPending) {
		t.Fatalf("calls %v public %v status %s", e.mod.calls, e.obj.public, e.doc(tg.MediaID).Status)
	}
}

// The attempt ceilings end in REJECTED, never in a publish: a document that keeps failing to screen is refused, not waved through.
func TestFinalize_ExhaustedAttemptsRejectAndNeverPublish(t *testing.T) {
	t.Run("claims ceiling: Vision keeps failing", func(t *testing.T) {
		e := newEnv(t, envOpts{maxAttempts: 3, maxRetries: ptr(2), unitsPerDay: 200})
		tg := e.upload(t, uidA, PurposePost, "a")
		e.mod.err = &googleapi.Error{Code: 429}
		for range 5 {
			_, err := e.finalizeErr(t, tg.MediaID)
			wantUnavailable(t, err)
		}
		r, err := e.finalizeErr(t, tg.MediaID)
		if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonAttempts || r.Ref != nil || len(e.obj.public) != 0 {
			t.Fatalf("result = %+v err=%v public=%v, want REJECTED %q", r, err, e.obj.public, reasonAttempts)
		}
	})
	t.Run("assessed ceiling: one image answers, the other keeps failing", func(t *testing.T) {
		e := newEnv(t, envOpts{screenThumb: true, maxAttempts: 3, unitsPerDay: 200})
		tg := e.upload(t, uidA, PurposePost, "a")
		e.mod.errBy = map[string]error{uploadThumbObject(uidA, tg.MediaID, "jpg"): &googleapi.Error{Code: 503}}
		for range 3 {
			_, err := e.finalizeErr(t, tg.MediaID)
			wantUnavailable(t, err)
		}
		r, err := e.finalizeErr(t, tg.MediaID)
		if err != nil || r.Status != StatusRejected || r.RejectionReason != reasonAttempts || len(e.obj.public) != 0 {
			t.Fatalf("result = %+v err=%v public=%v, want REJECTED %q", r, err, e.obj.public, reasonAttempts)
		}
	})
}

// The usage counter never gates anything: a failed write after a good screening still publishes READY.
func TestFinalize_CounterWriteFailureStillPublishesAScreenedImage(t *testing.T) {
	e := newEnv(t, envOpts{})
	e.repo.addVisionErr = errors.New("firestore unavailable")
	tg := e.upload(t, uidA, PurposePost, "a")
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusReady || res[0].Ref == nil || len(e.obj.public) != 2 {
		t.Fatalf("res = %+v err=%v public=%v, want READY", res, err, e.obj.public)
	}
	if e.repo.visionAdds != 1 || len(e.mod.calls) != 1 {
		t.Fatalf("counter writes = %d, Vision calls = %d, want 1 / 1", e.repo.visionAdds, len(e.mod.calls))
	}
}

// A blocking verdict is final whatever the counter says: avatars use the stricter Racy rule, and a GIF is rejected on
// either its contact sheet or its thumbnail.
func TestFinalize_BlockedImagesAreStillRejectedWithAHugeCounter(t *testing.T) {
	racy := SafeSearch{Racy: LikelihoodLikely}
	adult := SafeSearch{Adult: LikelihoodVeryLikely}
	tests := []struct {
		name  string
		setup func(t *testing.T, e *env) UploadTarget
	}{
		{"avatar racy", func(t *testing.T, e *env) UploadTarget {
			tg := e.upload(t, uidA, PurposeAvatar, "a")
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = racy
			return tg
		}},
		{"post adult", func(t *testing.T, e *env) UploadTarget {
			tg := e.upload(t, uidA, PurposePost, "a")
			e.mod.by[uploadObject(uidA, tg.MediaID, "jpg")] = adult
			return tg
		}},
		{"gif sheet adult", func(t *testing.T, e *env) UploadTarget {
			tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
			e.mod.bytesBy = func([]byte) SafeSearch { return adult }
			return tg
		}},
		{"gif thumbnail adult", func(t *testing.T, e *env) UploadTarget {
			tg := e.createGIF(t, uidA, "a", ContentTypeJPEG)
			e.mod.by[uploadThumbObject(uidA, tg.MediaID, "jpg")] = adult
			return tg
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{})
			e.repo.vision[monthKey(testNow)] = hugeCounter
			tg := tt.setup(t, e)
			res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			if err != nil || res[0].Status != StatusRejected || res[0].RejectionReason != reasonPolicy || res[0].Ref != nil || len(e.obj.public) != 0 {
				t.Fatalf("res = %+v err=%v public=%v, want REJECTED %q", res, err, e.obj.public, reasonPolicy)
			}
		})
	}
}

// The per-uid daily units cap is separate from the usage counter and still refuses, before anything is claimed or sent.
func TestFinalize_PerUIDUnitsCapStillApplies(t *testing.T) {
	e := newEnv(t, envOpts{unitsPerDay: 2}) // an established account: 2 photos of 1 unit
	var ids []string
	for _, tag := range []string{"a", "b", "c"} {
		ids = append(ids, e.upload(t, uidA, PurposePost, tag).MediaID)
	}
	for _, id := range ids[:2] {
		if r, err := e.finalizeErr(t, id); err != nil || r.Status != StatusReady {
			t.Fatalf("within the cap: %+v, %v", r, err)
		}
	}
	calls, claims := len(e.mod.calls), e.repo.claims
	_, err := e.finalizeErr(t, ids[2])
	_ = wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED)
	if len(e.mod.calls) != calls || e.repo.claims != claims || len(e.obj.public) != 4 {
		t.Fatal("the refused call must not claim, screen or publish")
	}
}

// Documents already READY_UNSCREENED (written while the cap existed) stay published exactly as before: finalize answers them
// idempotently with their image, and nothing screens them again.
func TestFinalize_ExistingReadyUnscreenedDocStaysPublished(t *testing.T) {
	e := newEnv(t, envOpts{})
	tg := e.upload(t, uidA, PurposePost, "a")
	d := e.repo.docs[tg.MediaID]
	d.Status, d.PublicPath, d.ThumbPath, d.Blurhash = string(StatusReadyUnscreened), "m/legacy.jpg", "m/legacy_t.jpg", "LEHV6n"
	if !d.Published() {
		t.Fatal("READY_UNSCREENED must still count as published")
	}
	res, err := e.svc.FinalizeUpload(context.Background(), uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil {
		t.Fatal(err)
	}
	r := res[0]
	if r.Status != StatusReadyUnscreened || r.Ref == nil || r.Ref.URL != "https://cdn.test/media/m/legacy.jpg" || r.Ref.Blurhash != "LEHV6n" {
		t.Fatalf("result = %+v ref=%+v", r, r.Ref)
	}
	if len(e.mod.calls) != 0 || e.units() != 0 || len(e.obj.public) != 0 {
		t.Fatal("an already published document must not be screened, counted or copied again")
	}
}
