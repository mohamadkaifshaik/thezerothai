package media

import (
	"context"
	"crypto/md5" //nolint:gosec // integrity check against the client-declared MD5 that verify already compared, not a security hash
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// GIF screening glue (ADR-0029 D11, W6-10): the per-instance semaphore, the object read, the deadlines, the panic
// recover and the gif_screen log line around the pure sampler in gifscan.go.
//
// Worst-case memory, per instance, whatever the request concurrency (the semaphore admits one GIF at a time and is held
// from the object read until the sheet is encoded): the file 2 MiB + two canvases of GIF_MAX_EDGE squared RGBA
// (1,280 x 1,280 x 4 = 6.3 MiB each, 12.5 MiB) + one decoded frame (<= 1.6 MiB paletted) + up to four tiles of
// 640 x 480 RGBA (4.7 MiB) + the sheet (1,280 x 960 x 4 = 4.7 MiB) + its JPEG (< 0.5 MiB) = about 26 MiB live. A request
// that has passed the semaphore then holds only the JPEG, its base64 and JSON copies (< 2 MiB) while Vision runs, so
// 80 concurrent requests add at most about 160 MiB in the pathological case where all 80 wait on Vision at once,
// which max-instances 3 and the 3-uid allowlist make unreachable at Stage 0. A refused bomb never allocates more
// than the frame list (one small struct per frame, at most GIF_MAX_FRAMES).

// Default guard values (ADR-0029 D11); Deps zero values mean these.
const (
	defaultGifMaxFrames     = 300
	defaultGifMaxFrameArea  = int64(50_000_000)
	defaultGifQueueWait     = 5 * time.Second
	defaultGifDecodeTimeout = 2 * time.Second
	gifReadTimeout          = 5 * time.Second
	gifSheetOp              = "media/gif_screen"
	gifMessageBusy          = "this GIF is being checked, please try again shortly"
	gifLogMessage           = "gif_screen"
)

// errGifBusy: another GIF held the semaphore for GifQueueWait.
var errGifBusy = errors.New("media: gif screening busy")

// gifStats is what the gif_screen line reports.
type gifStats struct {
	frames, sampled int
	decodeMS        int64
	refused         string
}

func (s *service) gifLimits() gifLimits {
	l := gifLimits{maxFrames: s.GifMaxFrames, maxEdge: s.gifMaxEdge(), maxAreaSum: s.GifMaxFrameAreaSum}
	if l.maxFrames <= 0 {
		l.maxFrames = defaultGifMaxFrames
	}
	if l.maxAreaSum <= 0 {
		l.maxAreaSum = defaultGifMaxFrameArea
	}
	return l
}

func durationOr(v, def time.Duration) time.Duration {
	if v > 0 {
		return v
	}
	return def
}

// acquireGif takes the per-instance GIF slot, waiting at most GifQueueWait. It returns errGifBusy on timeout and the
// context's error if the request ended first.
func (s *service) acquireGif(ctx context.Context) (release func(), err error) {
	wctx, cancel := context.WithTimeout(ctx, durationOr(s.GifQueueWait, defaultGifQueueWait))
	defer cancel()
	select {
	case s.gifSlot <- struct{}{}:
		return func() { <-s.gifSlot }, nil
	case <-wctx.Done():
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errGifBusy
	}
}

// gifSheet reads the whole private GIF, pre-scans it, and returns the JPEG contact sheet of its sampled frames. The
// error is a *gifRefusal (the GIF is rejected, 0 Vision units), errGifBusy (retryable), or an infrastructure error.
// 1 Class B read. A decoder panic is recovered into a refusal and reported to Error Reporting.
func (s *service) gifSheet(ctx context.Context, d *Doc, gens verifiedGens) (sheet []byte, st gifStats, err error) {
	release, err := s.acquireGif(ctx)
	if err != nil {
		return nil, st, err
	}
	defer release()
	defer func() {
		if v := recover(); v != nil {
			mw.ReportError(ctx, s.Log.With(logger.TraceAttrs(ctx)...), gifSheetOp, logger.ScrubErr(fmt.Errorf("gif sampler panic of type %T", v), d.OwnerID))
			sheet, err = nil, refuseInvalid("panic")
		}
	}()

	rctx, cancel := context.WithTimeout(ctx, gifReadTimeout)
	data, err := s.Objects.UploadHead(rctx, d.UploadPath, d.Bytes, gens.full) // pinned: the exact generation verify approved
	cancel()
	if errors.Is(err, objstore.ErrGenerationChanged) {
		logger.SetRequestField(ctx, fieldChangedAfterVerify, true)
		return nil, st, refuseInvalid(fieldChangedAfterVerify)
	}
	if err != nil {
		return nil, st, fmt.Errorf("media: read gif: %w", err)
	}
	// The bytes sampled must be the bytes verify approved. The read is pinned to the verified generation (and the signed PUT is
	// create-only), so this MD5 comparison is defence in depth.
	if sum := md5.Sum(data); int64(len(data)) != d.Bytes || base64.StdEncoding.EncodeToString(sum[:]) != d.FullMD5 { //nolint:gosec // see import
		logger.SetRequestField(ctx, fieldChangedAfterVerify, true)
		return nil, st, refuseInvalid(fieldChangedAfterVerify)
	}
	sc, err := scanGIF(data, s.gifLimits())
	if err != nil {
		return nil, st, err
	}
	st.frames = len(sc.frames)

	dctx, dcancel := context.WithTimeout(ctx, durationOr(s.GifDecodeTimeout, defaultGifDecodeTimeout))
	defer dcancel()
	began := time.Now() // wall time for the log only; the deadline is the context's
	sheet, st.sampled, err = sampleGIF(dctx, data, sc)
	st.decodeMS = time.Since(began).Milliseconds()
	return sheet, st, err
}

// screenGIF is screen for a GIF (D11 step 6): the sheet by bytes and the thumbnail by URI, in parallel; the worse
// verdict wins. It logs one gif_screen line.
func (s *service) screenGIF(ctx context.Context, d *Doc, gens verifiedGens) (blocked bool, answered int64, err error) {
	sheet, st, err := s.gifSheet(ctx, d, gens)
	units := 0
	defer func() {
		var ref *gifRefusal
		if errors.As(err, &ref) {
			st.refused = ref.why
		}
		s.Log.InfoContext(ctx, gifLogMessage, append([]any{
			"frames", st.frames, "sampled", st.sampled, "units", units, "decode_ms", st.decodeMS, "refused_reason", st.refused,
		}, logger.TraceAttrs(ctx)...)...)
	}()
	if err != nil {
		return false, 0, err
	}
	blocked, answered, err = s.screenAll(ctx, d, []func(context.Context) (SafeSearch, error){
		func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearchBytes(c, sheet) },
		func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearch(c, d.ThumbUploadPath) },
	})
	units = int(answered)
	return blocked, answered, err
}

// mediaNotReady is the retryable MEDIA_NOT_READY answer.
func mediaNotReady(id, msg string) error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY, msg).WithMeta("media_id", id)
}
