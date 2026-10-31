package media

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// FinalizeUpload implements Service.
func (s *service) FinalizeUpload(ctx context.Context, uid string, items []FinalizeItem) (_ []Result, err error) {
	logger.SetRequestField(ctx, fieldOp, "finalize_upload")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validateFinalize(items); err != nil {
		return nil, err
	}
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.MediaID
	}
	logger.SetRequestField(ctx, fieldImages, len(items))
	docs, err := s.Repo.GetMany(ctx, ids)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("media: finalize: load: %w", err), uid)
	}
	for _, id := range ids {
		if d, ok := docs[id]; !ok || d.OwnerID != uid {
			return nil, notFound()
		}
	}
	logger.SetRequestField(ctx, fieldPurpose, finalizePurpose(docs, ids))
	logger.SetRequestField(ctx, fieldContentType, finalizeContentType(docs, ids))

	results := make([]Result, len(items))
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		firstEr error
		units   int64
	)
	for i, it := range items {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, spent, err := s.finalizeShared(ctx, uid, docs[it.MediaID], it.Blurhash)
			mu.Lock()
			defer mu.Unlock()
			units += spent
			if err != nil && firstEr == nil {
				firstEr = err
			}
			results[i] = r
		}()
	}
	wg.Wait()
	// The Vision counter is the cost meter: record what was actually spent even when another item failed.
	if units > 0 {
		if err := s.Repo.AddVisionUnits(ctx, monthKey(s.Now()), units); err != nil {
			s.Log.WarnContext(ctx, "vision_counter_write_failed", append([]any{"units", units, "error", logger.CauseChain(err)}, logger.TraceAttrs(ctx)...)...)
		}
	}
	logger.SetRequestField(ctx, fieldVisionUnits, units)
	if firstEr != nil {
		return nil, firstEr
	}
	var ready, unscreened, rejected int
	for _, r := range results {
		switch r.Status {
		case StatusReady:
			ready++
		case StatusReadyUnscreened:
			unscreened++
		case StatusRejected:
			rejected++
		}
	}
	logger.SetRequestField(ctx, fieldReady, ready)
	logger.SetRequestField(ctx, fieldUnscreened, unscreened)
	logger.SetRequestField(ctx, fieldRejected, rejected)
	logger.SetRequestField(ctx, fieldOutcome, "finalized")
	return results, nil
}

// finalizePurpose is the purpose to log for a finalize: the shared one, or "MIXED" (a post batch never mixes
// purposes in practice; a client could ask). Enum values only.
func finalizePurpose(docs map[string]*Doc, ids []string) string {
	p := ""
	for _, id := range ids {
		switch d := docs[id].Purpose; {
		case p == "":
			p = d
		case p != d:
			return "MIXED"
		}
	}
	return p
}

func validateFinalize(items []FinalizeItem) error {
	if len(items) == 0 || len(items) > MaxPerPost {
		return apierr.Validation("items", "1 to 4 items are required")
	}
	seen := make(map[string]struct{}, len(items))
	for i, it := range items {
		if !mediaIDPattern.MatchString(it.MediaID) {
			return apierr.Validation(fmt.Sprintf("items[%d].media_id", i), "media_id must be a 19-digit media id")
		}
		if _, dup := seen[it.MediaID]; dup {
			return apierr.Validation(fmt.Sprintf("items[%d].media_id", i), "media_id appears twice")
		}
		seen[it.MediaID] = struct{}{}
		if !blurhashPattern.MatchString(it.Blurhash) {
			return apierr.Validation(fmt.Sprintf("items[%d].blurhash", i), "blurhash must be at most 64 BlurHash characters")
		}
	}
	return nil
}

// screeningClaimTTL is how long a FinalizeUpload owns the SafeSearch spend for one image (W3-22 M-3). It is far above a
// healthy run (two parallel Vision calls with a 10 s deadline each, then two copies) and short enough that a call
// that died holding the claim blocks a client retry for at most this long. A run that outlives it is not unsafe: a
// second call may claim and screen again, and the first one's Resolve then loses its UpdateTime precondition and
// converges on the second's result (the pre-fix behaviour, now the rare case).
//
// A GIF (W6-10) takes longer: the claim is taken before the 5 s wait for the instance's GIF slot, then a 5 s object read,
// a 2 s sampling deadline, the Vision calls (10 s each, in parallel) and the two copies, so its bounded worst case is
// about 22 s plus the ordinary calls, still under this TTL and under the 30 s Cloud Run request timeout. A GIF that
// runs past the TTL degrades exactly as described above: it is correct, only the double-spend guard is lost.
const screeningClaimTTL = 30 * time.Second

// claimReleaseTimeout bounds the best-effort release of a claim after a failed attempt. It runs on a context cut off
// from the request's cancellation so a client that hung up does not leave the image locked.
const claimReleaseTimeout = 3 * time.Second

// flightResult is what a same-instance finalize flight shares: the leader's result and the Vision units it spent.
type flightResult struct {
	r     Result
	spent int64
}

// finalizeShared is finalizeOne behind a per-instance single-flight keyed by media id (W3-22 M-3, part a): N
// concurrent calls for one PENDING image on this instance run the verify, claim, screen and publish steps once and
// all receive the leader's result, so a double tap or a client retry is answered READY instead of MEDIA_NOT_READY.
// Only the leader reports the Vision units it spent (the caller adds them to the month's counter), followers report
// 0. A document that is already resolved is answered directly. Other instances are covered by the screening claim
// in finalizeOne. Every caller of one media id has the same uid (FinalizeUpload checks ownership first), so sharing
// the leader's error leaks nothing.
func (s *service) finalizeShared(ctx context.Context, uid string, d *Doc, blurhash string) (Result, int64, error) {
	if d.Status != string(StatusPending) {
		return s.finalizeOne(ctx, uid, d, blurhash)
	}
	led := false
	v, err, _ := s.flight.Do(d.ID, func() (any, error) {
		led = true
		r, spent, err := s.finalizeOne(ctx, uid, d, blurhash)
		return flightResult{r: r, spent: spent}, err
	})
	out, _ := v.(flightResult)
	if !led {
		logger.SetRequestField(ctx, fieldJoined, true)
		out.spent = 0
	}
	return out.r, out.spent, err
}

// finalizeOne verifies, screens and publishes one image. spent is the Vision units it consumed.
func (s *service) finalizeOne(ctx context.Context, uid string, d *Doc, blurhash string) (_ Result, spent int64, err error) {
	if d.Status != string(StatusPending) {
		return s.resultOf(d), 0, nil // idempotent: already READY / REJECTED
	}
	// 0. Another call (usually on another instance: this instance's calls are collapsed by finalizeShared) holds the
	// screening claim: do not verify, reserve or screen. The document is read again in case it was resolved since
	// this call loaded it; otherwise the client retries (W3-22 M-3).
	if d.ScreeningUntil != nil && d.ScreeningUntil.After(s.Now()) {
		return s.screeningElsewhere(ctx, uid, d)
	}
	// 0b. Attempt cap (W6-27, security H-3): every claim below counts one attempt on the document. A document that used them
	// all is REJECTED here, before verify, the claim and any Vision call, so a looped FinalizeUpload cannot bill forever.
	if d.ScreenAttempts >= int64(s.maxScreenAttempts()) {
		logger.SetRequestField(ctx, fieldAttemptsExhausted, true)
		r, err := s.reject(ctx, d, reasonAttempts)
		return r, 0, err
	}
	// 1. Verify what the signed URL already enforced (defence in depth) and the magic bytes.
	reason, err := s.verify(ctx, d)
	if errors.Is(err, errUploadMissing) {
		return s.uploadMissing(ctx, uid, d, false, nil)
	}
	if err != nil {
		return Result{}, 0, err
	}
	if reason != "" {
		r, err := s.reject(ctx, d, reason)
		return r, 0, err
	}

	// 1b. Claim the image before spending anything (W3-22 M-3): one UpdateTime-preconditioned write that exactly one
	// concurrent call wins. A loser's precondition fails here, before any Vision call, and it answers like a client
	// that finalized too early (MEDIA_NOT_READY, retryable) or, when the winner has finished, with the winner's result.
	// The write moves the document's UpdateTime, so everything below works on the claimed copy. A failed attempt
	// releases the claim so the client's retry is not locked out for the claim's duration.
	until := s.Now().UTC().Add(screeningClaimTTL)
	claimedAt, err := s.Repo.ClaimScreening(ctx, d.ID, d.UpdateTime, until)
	switch {
	case errors.Is(err, ErrConflict):
		return s.screeningElsewhere(ctx, uid, d)
	case err != nil:
		return Result{}, 0, logger.RedactErr(fmt.Errorf("media: claim screening: %w", err), uid)
	}
	claimed := *d
	claimed.UpdateTime, claimed.ScreeningUntil = claimedAt, &until
	claimed.ScreenAttempts++
	d = &claimed
	defer func() {
		if err != nil {
			s.releaseClaim(ctx, d)
		}
	}()

	// 2. Moderate: every image is screened while the monthly cap lasts (ADR-0005).
	units := int64(1)
	if s.screensThumb(d) {
		units = 2
	}
	status := StatusReady
	ok, err := s.vision.reserve(ctx, units)
	if err != nil {
		return Result{}, 0, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
			"image checks are temporarily unavailable, please try again").WithCause(logger.RedactErr(err, uid))
	}
	if ok {
		blocked, answered, err := s.screen(ctx, d)
		// Count what Vision answered, success or per-image error, and release only the units of calls that never got a
		// response (W6-27, security H-3): Google bills an answered call, so releasing it would hide the spend from the cap.
		spent = answered
		if err != nil {
			s.vision.release(units - answered)
			// A GIF the sampler refused (D11) is REJECTED with no Vision spend; a busy slot is the retryable MEDIA_NOT_READY
			// (the deferred releaseClaim frees the claim).
			var refusal *gifRefusal
			switch {
			case errors.As(err, &refusal):
				r, rerr := s.reject(ctx, d, refusal.reason)
				return r, spent, rerr
			case errors.Is(err, errGifBusy):
				return Result{}, spent, mediaNotReady(d.ID, gifMessageBusy)
			case isInvalidImage(err):
				// Vision cannot decode the image: no retry can fix it, so it is terminal (the same answer as a bad magic number).
				r, rerr := s.reject(ctx, d, reasonInvalid)
				return r, spent, rerr
			}
			// Vision fetches the private object, so a concurrent finalize that already published and deleted it
			// surfaces here as a screening failure although the image is READY: converge on its result.
			if r, ok := s.resolvedElsewhere(ctx, d); ok {
				return r, spent, nil
			}
			return Result{}, spent, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
				"image checks are temporarily unavailable, please try again").WithCause(logger.RedactErr(err, uid))
		}
		if blocked {
			r, err := s.reject(ctx, d, reasonPolicy)
			return r, spent, err
		}
	} else {
		logger.SetRequestField(ctx, fieldExhausted, true)
		if d.ContentType == ContentTypeGIF {
			// ADR-0029 F11 point 4: at the cap a GIF is REJECTED for every account, never READY_UNSCREENED (a GIF is not
			// screened by anything but Vision, and report-driven review is slower for an animation).
			r, err := s.reject(ctx, d, reasonCapacity)
			return r, 0, err
		}
		established, err := s.establishedAccount(ctx, uid)
		if err != nil {
			return Result{}, 0, err
		}
		if !established {
			r, err := s.reject(ctx, d, reasonCapacity)
			return r, 0, err
		}
		status = StatusReadyUnscreened
	}

	// 3. Publish: copy into the public bucket, then flip the document, then drop the private copies.
	pub, pubThumb := publicObject(d.ID, d.NameSuffix, extension(d.ContentType)), publicThumbObject(d.ID, d.NameSuffix, extension(d.ThumbType()))
	if err := s.Objects.Publish(ctx, d.UploadPath, pub, d.ContentType); err != nil {
		if errors.Is(err, objstore.ErrObjectNotFound) {
			r, _, rerr := s.uploadMissing(ctx, uid, d, true, err)
			return r, spent, rerr
		}
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: publish full: %w", err), uid)
	}
	if err := s.Objects.Publish(ctx, d.ThumbUploadPath, pubThumb, d.ThumbType()); err != nil {
		if errors.Is(err, objstore.ErrObjectNotFound) {
			r, _, rerr := s.uploadMissing(ctx, uid, d, true, err)
			s.dropOrphanedCopies(ctx, d, r, pub)
			return r, spent, rerr
		}
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: publish thumb: %w", err), uid)
	}
	err = s.Repo.Resolve(ctx, d.ID, d.UpdateTime, Resolution{Status: status, PublicPath: pub, ThumbPath: pubThumb, Blurhash: blurhash})
	switch {
	case errors.Is(err, ErrConflict):
		r, spent, rerr := s.reload(ctx, uid, d.ID, spent)
		if rerr == nil {
			logger.SetRequestField(ctx, fieldConverged, true)
			s.dropOrphanedCopies(ctx, d, r, pub, pubThumb)
		}
		return r, spent, rerr
	case err != nil:
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: resolve: %w", err), uid)
	}
	s.deleteUploads(ctx, d)
	out := *d
	out.Status, out.PublicPath, out.ThumbPath, out.Blurhash = string(status), pub, pubThumb, blurhash
	return s.resultOf(&out), spent, nil
}

// screeningElsewhere answers a finalize that found another call holding the screening claim, or lost the race for it
// (W3-22 M-3). It spends nothing and writes nothing: the document is read once (1 read) and the answer is the
// idempotent result when the other call has finished, otherwise the retryable MEDIA_NOT_READY (uploadMissing with
// afterVerify false), which the client already handles as "try again shortly".
func (s *service) screeningElsewhere(ctx context.Context, uid string, d *Doc) (Result, int64, error) {
	logger.SetRequestField(ctx, fieldBusy, true)
	return s.uploadMissing(ctx, uid, d, false, nil)
}

// releaseClaim clears the screening claim after a failed attempt (best effort, 1 write). The write is conditional on
// the claim's own UpdateTime, so it never undoes a newer state; a conflict means the document already moved on
// (another call resolved it, or the claim expired and was retaken) and is not an error. A failure is only logged:
// the claim expires on its own after screeningClaimTTL.
func (s *service) releaseClaim(ctx context.Context, d *Doc) {
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), claimReleaseTimeout)
	defer cancel()
	if err := s.Repo.ReleaseScreening(rctx, d.ID, d.UpdateTime); err != nil && !errors.Is(err, ErrConflict) {
		s.Log.WarnContext(ctx, "media_claim_release_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, d.OwnerID))}, logger.TraceAttrs(ctx)...)...)
	}
}

// errUploadMissing is verify's signal that a private upload object is not there.
var errUploadMissing = errors.New("media: upload object missing")

// resolvedElsewhere reports the result of a document a concurrent FinalizeUpload already resolved (1 read, only
// on error paths). ok is false when the document is still PENDING or cannot be read.
func (s *service) resolvedElsewhere(ctx context.Context, d *Doc) (Result, bool) {
	r, _, err := s.reload(ctx, d.OwnerID, d.ID, 0)
	if err != nil || r.Status == StatusPending {
		return Result{}, false
	}
	logger.SetRequestField(ctx, fieldConverged, true)
	return r, true
}

// dropOrphanedCopies deletes public objects this call copied when the document turned out to be resolved without
// them (REJECTED by the winner: a REJECTED doc has no public path, so nothing else would ever remove them). A
// READY result owns the same deterministic object names, so those are kept.
func (s *service) dropOrphanedCopies(ctx context.Context, d *Doc, r Result, objects ...string) {
	if r.Status == "" || r.Status == StatusPending || r.Ref != nil {
		return
	}
	for _, o := range objects {
		if err := s.Objects.DeletePublic(ctx, o); err != nil {
			s.Log.WarnContext(ctx, "media_public_delete_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, d.OwnerID))}, logger.TraceAttrs(ctx)...)...)
		}
	}
}

// uploadMissing answers a finalize that found a private upload object gone. Two causes look identical from the
// bucket: the client has not finished uploading, or a concurrent FinalizeUpload (a client retry) already published
// the image and deleted the private copies after this call loaded the document as PENDING. The document tells them
// apart (1 read, only on this path): a resolved document is the idempotent answer, a still-PENDING one is genuinely
// not uploaded yet. afterVerify is true on the Publish path, where verify had just seen the objects: a still
// PENDING document then is not a lost race but a broken source or bucket, so it is an internal error (visible in
// Error Reporting) rather than a silent client retry. screeningElsewhere reuses it with afterVerify false: a still-PENDING
// document held by another call's screening claim is retryable for the same reason.
func (s *service) uploadMissing(ctx context.Context, uid string, d *Doc, afterVerify bool, cause error) (Result, int64, error) {
	r, _, err := s.reload(ctx, uid, d.ID, 0)
	if err != nil {
		return Result{}, 0, err
	}
	if r.Status != StatusPending {
		logger.SetRequestField(ctx, fieldConverged, true)
		return r, 0, nil
	}
	if afterVerify {
		return Result{}, 0, logger.RedactErr(fmt.Errorf("media: publish: source missing after verify: %w", cause), uid)
	}
	return Result{}, 0, mediaNotReady(d.ID, "the upload is not complete yet")
}

// reload returns the document another concurrent FinalizeUpload resolved first (1 read).
func (s *service) reload(ctx context.Context, uid, id string, spent int64) (Result, int64, error) {
	docs, err := s.Repo.GetMany(ctx, []string{id})
	if err != nil {
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: reload: %w", err), uid)
	}
	d, ok := docs[id]
	if !ok {
		return Result{}, spent, notFound()
	}
	return s.resultOf(d), spent, nil
}

// verify checks both objects against the declared size, type and MD5 and sniffs their magic bytes. reason is
// non-empty for a rejection; an error is an infrastructure failure (the client may retry). An object that is not
// there yet is reported as errUploadMissing (the caller decides: the client has not finished uploading, or a
// concurrent finalize already published and deleted it).
func (s *service) verify(ctx context.Context, d *Doc) (reason string, err error) {
	maxFull, maxThumb := capsFor(Purpose(d.Purpose))
	for _, o := range []struct {
		object, md5, contentType string
		size                     int64
		max                      int64
	}{
		{d.UploadPath, d.FullMD5, d.ContentType, d.Bytes, maxFull},
		{d.ThumbUploadPath, d.ThumbMD5, d.ThumbType(), d.ThumbBytes, maxThumb},
	} {
		a, err := s.Objects.UploadAttrs(ctx, o.object)
		switch {
		case errors.Is(err, objstore.ErrObjectNotFound):
			return "", errUploadMissing
		case err != nil:
			return "", fmt.Errorf("media: object attrs: %w", err)
		}
		want, derr := base64.StdEncoding.DecodeString(o.md5)
		switch {
		case a.Size <= 0 || a.Size > o.max || a.Size != o.size:
			return reasonInvalid, nil
		case a.ContentType != o.contentType:
			return reasonInvalid, nil
		case derr != nil || string(a.MD5) != string(want):
			return reasonInvalid, nil
		}
		head, err := s.Objects.UploadHead(ctx, o.object, 512)
		switch {
		case errors.Is(err, objstore.ErrObjectNotFound):
			return "", errUploadMissing
		case err != nil:
			return "", fmt.Errorf("media: object head: %w", err)
		}
		if sniffImage(head) != o.contentType {
			return reasonInvalid, nil
		}
	}
	return "", nil
}

// screensThumb reports whether the thumbnail is screened too: always for a BANNER (ADR-0024 D1: 2 Vision units, the
// thumb is a separate upload) and for a GIF (ADR-0029 D11, W6-10: sheet by bytes + thumbnail = 2 units; the thumbnail is
// a client-made still that lists show, and nothing ties it to the GIF's frames), otherwise per VISION_SCREEN_THUMB.
func (s *service) screensThumb(d *Doc) bool {
	return s.ScreenThumb || d.Purpose == string(PurposeBanner) || d.ContentType == ContentTypeGIF
}

// screen runs SafeSearch on the full image and, when screensThumb, the thumbnail (the small image is what lists
// show, and it is uploaded separately). It reports whether either is blocked by the policy. A GIF is screened by its
// sampled frames instead (screenGIF).
func (s *service) screen(ctx context.Context, d *Doc) (blocked bool, answered int64, err error) {
	if d.ContentType == ContentTypeGIF {
		return s.screenGIF(ctx, d)
	}
	calls := []func(context.Context) (SafeSearch, error){
		func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearch(c, d.UploadPath) },
	}
	if s.screensThumb(d) {
		calls = append(calls, func(c context.Context) (SafeSearch, error) { return s.Moderator.SafeSearch(c, d.ThumbUploadPath) })
	}
	return s.screenAll(ctx, d, calls)
}

// isInvalidImage reports whether err is Vision's per-image INVALID_ARGUMENT.
func isInvalidImage(err error) bool {
	var ans *VisionAnsweredError
	return errors.As(err, &ans) && ans.Invalid()
}

// maxScreenAttempts is MEDIA_MAX_SCREEN_ATTEMPTS (default 3).
func (s *service) maxScreenAttempts() int {
	if s.MediaMaxScreenAttempts > 0 {
		return s.MediaMaxScreenAttempts
	}
	return 3
}

// screenAll runs the Vision calls in parallel (a bounded 1 or 2) and reports whether any verdict is blocked by the policy.
// answered is the number of calls Vision answered, with a verdict or with a per-image error (VisionAnsweredError): Google
// bills each of them, so the caller counts them even when err is non-nil (W6-27, security H-3). err is the first failure,
// preferring an answered INVALID_ARGUMENT, so a broken image is not mistaken for a retryable outage.
func (s *service) screenAll(ctx context.Context, d *Doc, calls []func(context.Context) (SafeSearch, error)) (blocked bool, answered int64, err error) {
	type out struct {
		ss  SafeSearch
		err error
	}
	outs := make([]out, len(calls))
	var wg sync.WaitGroup
	for i, call := range calls {
		wg.Add(1)
		go func() {
			defer wg.Done()
			outs[i].ss, outs[i].err = call(ctx)
		}()
	}
	wg.Wait()
	for _, o := range outs {
		var ans *VisionAnsweredError
		switch {
		case o.err == nil:
			answered++
			if blockedBySafeSearch(o.ss, Purpose(d.Purpose)) {
				blocked = true
			}
		case errors.As(o.err, &ans):
			answered++
			if err == nil || ans.Invalid() {
				err = o.err
			}
		case err == nil:
			err = o.err
		}
	}
	if err != nil {
		return false, answered, err
	}
	return blocked, answered, nil
}

// blockedBySafeSearch is ADR-0005's policy: LIKELY or VERY_LIKELY adult or violence, and racy for avatars and
// banners (ADR-0024 D1).
func blockedBySafeSearch(ss SafeSearch, p Purpose) bool {
	if ss.Adult >= LikelihoodLikely || ss.Violence >= LikelihoodLikely {
		return true
	}
	return (p == PurposeAvatar || p == PurposeBanner) && ss.Racy >= LikelihoodLikely
}

// establishedAccount reports whether uid may publish unscreened once the cap is spent (ADR-0005): the policy
// allows it and the account is older than 7 days. There is no upheld-report signal until the reports slice (P7).
func (s *service) establishedAccount(ctx context.Context, uid string) (bool, error) {
	if s.Policy != config.VisionPolicyEstablished {
		return false, nil
	}
	created, err := s.Directory.AccountCreatedAt(ctx, uid)
	if err != nil {
		return false, logger.RedactErr(fmt.Errorf("media: load account: %w", err), uid)
	}
	return !created.IsZero() && s.Now().Sub(created) >= AccountAgeForUnscreened, nil
}

// reject deletes the private objects and records REJECTED (kept for PendingTTL so a replayed FinalizeUpload gets
// the same answer, then removed by the TTL policy).
func (s *service) reject(ctx context.Context, d *Doc, reason string) (Result, error) {
	// Resolve first: deleting the objects before the document is resolved lets a rejecting loser pull them from
	// under a winner that is about to publish, and a failed Resolve would strand a PENDING doc with no objects.
	err := s.Repo.Resolve(ctx, d.ID, d.UpdateTime, Resolution{
		Status: StatusRejected, RejectionReason: reason, ExpireAt: s.Now().UTC().Add(PendingTTL),
	})
	switch {
	case errors.Is(err, ErrConflict):
		r, _, rerr := s.reload(ctx, d.OwnerID, d.ID, 0)
		return r, rerr
	case err != nil:
		return Result{}, logger.RedactErr(fmt.Errorf("media: reject: %w", err), d.OwnerID)
	}
	s.deleteUploads(ctx, d)
	return Result{MediaID: d.ID, Status: StatusRejected, RejectionReason: reason}, nil
}

// deleteUploads removes both private objects. A failure is only logged: the upload bucket's 2-day lifecycle rule
// removes whatever is left, and the objects are private either way.
func (s *service) deleteUploads(ctx context.Context, d *Doc) {
	for _, o := range []string{d.UploadPath, d.ThumbUploadPath} {
		if err := s.Objects.DeleteUpload(ctx, o); err != nil {
			s.Log.WarnContext(ctx, "media_upload_delete_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, d.OwnerID))}, logger.TraceAttrs(ctx)...)...)
		}
	}
}

// finalizeContentType is the content type to log for a finalize: the shared one, or "MIXED". Values come from stored
// documents (validated at CreateUpload), never from the request.
func finalizeContentType(docs map[string]*Doc, ids []string) string {
	t := ""
	for _, id := range ids {
		switch d := docs[id].ContentType; {
		case t == "":
			t = d
		case t != d:
			return "MIXED"
		}
	}
	return t
}
