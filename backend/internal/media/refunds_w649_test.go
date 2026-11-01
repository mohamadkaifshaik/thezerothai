package media

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"syscall"
	"testing"
	"time"

	"google.golang.org/api/googleapi"
	vision "google.golang.org/api/vision/v1"
)

// W6-49 (security W6-42, L-1 and L-3): the per-uid Vision-units cap and VISION_MONTHLY_CAP return the units of a call only when Google provably did not
// bill it, and a Vision call is not started with so little request time left that it can only time out.

// dialRefused is what a TCP connect failure looks like to the HTTP client: a *url.Error around a *net.OpError{Op: "dial"}.
func dialRefused() error {
	return &url.Error{Op: "Post", URL: "https://vision.googleapis.com/v1/images:annotate", Err: &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED}}
}

// connReset is a failure AFTER the request was written: Google may have received it, so it is as ambiguous as a timeout.
func connReset() error {
	return &url.Error{Op: "Post", URL: "https://vision.googleapis.com/v1/images:annotate", Err: &net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET}}
}

// TestW649_FinalizeRefundsOnlyUnbilledErrors: one claim of a 2-unit document (both calls fail with err). A call Google answered with 429 or 5xx, or that never
// went out, comes back from BOTH counters; any other failure stays counted in BOTH (it may have been billed).
func TestW649_FinalizeRefundsOnlyUnbilledErrors(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want int64 // units still counted after the claim, in the monthly counter and in the per-uid cap
	}{
		{"Vision 503 is refunded", fmt.Errorf("media: vision annotate: %w", &googleapi.Error{Code: 503}), 0},
		{"Vision 500 is refunded", fmt.Errorf("media: vision annotate: %w", &googleapi.Error{Code: 500}), 0},
		{"Vision 429 (project quota) is refunded", fmt.Errorf("media: vision annotate: %w", &googleapi.Error{Code: 429}), 0},
		{"a failure to build the Vision service never went out", fmt.Errorf("%w: build vision service: %w", errNotSent, errors.New("no credentials")), 0},
		{"a dial failure never went out", fmt.Errorf("media: vision annotate: %w", dialRefused()), 0},
		{"a plain error is not known to be unbilled", errors.New("vision down"), 2},
		{"a connection reset after the request was written stays counted", fmt.Errorf("media: vision annotate: %w", connReset()), 2},
		{"an unexpected EOF stays counted", fmt.Errorf("media: vision annotate: %w", io.ErrUnexpectedEOF), 2},
		{"Vision 400 stays counted (not a 429 or 5xx)", fmt.Errorf("media: vision annotate: %w", &googleapi.Error{Code: 400}), 2},
		{"Vision 403 stays counted (not a 429 or 5xx)", fmt.Errorf("media: vision annotate: %w", &googleapi.Error{Code: 403}), 2},
		{"our deadline stays counted", fmt.Errorf("media: vision annotate: %w", context.DeadlineExceeded), 2},
		{"a cancelled call stays counted", fmt.Errorf("media: vision annotate: %w", context.Canceled), 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: true})
			tg := e.upload(t, uidA, PurposePost, "a")
			e.mod.err = tt.err
			_, err := e.finalizeErr(t, tg.MediaID)
			wantRetryAfter(t, err, screeningRetryAfter)
			if got := e.units(); got != tt.want {
				t.Errorf("monthly vision units = %d, want %d", got, tt.want)
			}
			if got := e.unitsSpent(false); got != tt.want {
				t.Errorf("per-uid units = %d, want %d", got, tt.want)
			}
		})
	}
}

// One call that Google answered 503 and one that may have been billed: only the first is returned.
func TestW649_MixedFailuresRefundOnlyTheUnbilledCall(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true})
	tg := e.upload(t, uidA, PurposePost, "a")
	e.mod.errBy = map[string]error{
		uploadObject(uidA, tg.MediaID, "jpg"):      &googleapi.Error{Code: 503},
		uploadThumbObject(uidA, tg.MediaID, "jpg"): connReset(),
	}
	_, err := e.finalizeErr(t, tg.MediaID)
	wantUnavailable(t, err)
	if got, per := e.units(), e.unitsSpent(false); got != 1 || per != 1 {
		t.Fatalf("units: monthly %d, per-uid %d, want 1 and 1 (the 503 is returned, the reset is not)", got, per)
	}
}

// TestW649_RefundClassification pins the classifier the finalize path uses for both counters.
func TestW649_RefundClassification(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"googleapi 429", &googleapi.Error{Code: 429}, true},
		{"googleapi 500", &googleapi.Error{Code: 500}, true},
		{"googleapi 503, wrapped twice", fmt.Errorf("a: %w", fmt.Errorf("b: %w", &googleapi.Error{Code: 503})), true},
		{"googleapi 599", &googleapi.Error{Code: 599}, true},
		{"googleapi 499 is below the 5xx range", &googleapi.Error{Code: 499}, false},
		{"googleapi 400", &googleapi.Error{Code: 400}, false},
		{"googleapi 401", &googleapi.Error{Code: 401}, false},
		{"googleapi 403", &googleapi.Error{Code: 403}, false},
		{"googleapi 404", &googleapi.Error{Code: 404}, false},
		{"googleapi 200 (never an error in practice)", &googleapi.Error{Code: 200}, false},
		{"pre-send sentinel", fmt.Errorf("%w: build vision service: %w", errNotSent, errors.New("x")), true},
		{"dial failure", dialRefused(), true},
		{"bare dial OpError", &net.OpError{Op: "dial", Err: errors.New("no route to host")}, true},
		{"DNS failure while dialling", &net.OpError{Op: "dial", Err: &net.DNSError{Err: "no such host", Name: "vision.googleapis.com"}}, true},
		{"read OpError (connection reset)", connReset(), false},
		{"write OpError", &net.OpError{Op: "write", Err: syscall.EPIPE}, false},
		{"unexpected EOF", io.ErrUnexpectedEOF, false},
		{"EOF", io.EOF, false},
		{"plain error", errors.New("boom"), false},
		{"deadline exceeded", context.DeadlineExceeded, false},
		{"cancelled", context.Canceled, false},
		{"a dial that hit our deadline may be ambiguous: charged", &net.OpError{Op: "dial", Err: context.DeadlineExceeded}, false},
		{"a dial that the client cancelled: charged", fmt.Errorf("x: %w", &net.OpError{Op: "dial", Err: context.Canceled}), false},
		{"answered error (billed)", &VisionAnsweredError{Code: 7}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := unbilled(tt.err); got != tt.want {
				t.Fatalf("unbilled(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

// TestW649_VisionHTTPFailuresClassify drives the real Vision client against a stub endpoint: an HTTP 503 and 429 answer arrive as a
// *googleapi.Error the finalize path refunds, a 400 does not.
func TestW649_VisionHTTPFailuresClassify(t *testing.T) {
	for _, tt := range []struct {
		status int
		want   bool
	}{{503, true}, {500, true}, {429, true}, {400, false}, {403, false}} {
		t.Run(fmt.Sprintf("HTTP %d", tt.status), func(t *testing.T) {
			v := visionFor(t, tt.status, fmt.Sprintf(`{"error":{"code":%d,"message":"stub"}}`, tt.status), nil)
			_, err := v.SafeSearch(context.Background(), "u/uid/1.jpg")
			if err == nil {
				t.Fatal("want an error")
			}
			if got := unbilled(err); got != tt.want {
				t.Fatalf("unbilled(%v) = %v, want %v", err, got, tt.want)
			}
		})
	}
}

// A Vision service that cannot be built (no credentials, a metadata-server failure) has sent nothing: the error carries the pre-send sentinel.
func TestW649_VisionBuildFailureIsNotSent(t *testing.T) {
	v := &Vision{bucket: "demo-upload", newService: func(context.Context) (*vision.Service, error) { return nil, errors.New("no credentials") }}
	_, err := v.SafeSearch(context.Background(), "u/uid/1.jpg")
	if !errors.Is(err, errNotSent) || !unbilled(err) {
		t.Fatalf("err = %v, want errNotSent and unbilled", err)
	}
}

// W6-49 L-3: a Vision call needs time. With less than minVisionBudget left on the request, the calls are not started (nothing is billed,
// both counters keep their units, the claim is released with no attempt consumed, and the client retries after retry_after).
func TestW649_VisionNotStartedWithLessThanTheMinimumBudgetLeft(t *testing.T) {
	for _, tt := range []struct {
		name  string
		thumb bool
		gif   bool
	}{{"one image", false, false}, {"image and thumbnail", true, false}, {"a GIF (sheet and thumbnail)", false, true}} {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t, envOpts{screenThumb: tt.thumb})
			var tg UploadTarget
			if tt.gif {
				tg = e.createGIF(t, uidA, "a", ContentTypeJPEG)
			} else {
				tg = e.upload(t, uidA, PurposePost, "a")
			}
			ctx, cancel := context.WithTimeout(context.Background(), minVisionBudget/3)
			defer cancel()
			_, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: tg.MediaID}})
			wantRetryAfter(t, err, screeningRetryAfter)
			if len(e.mod.calls) != 0 || len(e.mod.byteCalls) != 0 {
				t.Fatalf("Vision was called with %v left: calls %d, byte calls %d", minVisionBudget/3, len(e.mod.calls), len(e.mod.byteCalls))
			}
			if got, per := e.units(), e.unitsSpent(false); got != 0 || per != 0 {
				t.Fatalf("units: monthly %d, per-uid %d, want 0 and 0 (nothing was sent)", got, per)
			}
			d := e.doc(tg.MediaID)
			if d.Status != string(StatusPending) || d.ScreenAttempts != 1 || d.ScreenAssessed != 0 || d.ScreeningUntil != nil {
				t.Fatalf("doc = %+v, want PENDING, 1 claim (a retry), 0 assessed, claim released", d)
			}
		})
	}
}

// With enough time the same document screens normally, so the guard changes nothing on a healthy request.
func TestW649_VisionStartsWithEnoughBudget(t *testing.T) {
	e := newEnv(t, envOpts{screenThumb: true})
	tg := e.upload(t, uidA, PurposePost, "a")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	res, err := e.svc.FinalizeUpload(ctx, uidA, []FinalizeItem{{MediaID: tg.MediaID}})
	if err != nil || res[0].Status != StatusReady {
		t.Fatalf("result = %+v, %v, want READY", res, err)
	}
	if len(e.mod.calls) != 2 {
		t.Fatalf("Vision calls = %d, want 2", len(e.mod.calls))
	}
}
