package media

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"

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
			r, spent, err := s.finalizeOne(ctx, uid, docs[it.MediaID], it.Blurhash)
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

// finalizeOne verifies, screens and publishes one image. spent is the Vision units it consumed.
func (s *service) finalizeOne(ctx context.Context, uid string, d *Doc, blurhash string) (_ Result, spent int64, err error) {
	if d.Status != string(StatusPending) {
		return s.resultOf(d), 0, nil // idempotent: already READY / REJECTED
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

	// 2. Moderate: every image is screened while the monthly cap lasts (ADR-0005).
	units := int64(1)
	if s.ScreenThumb {
		units = 2
	}
	status := StatusReady
	ok, err := s.vision.reserve(ctx, units)
	if err != nil {
		return Result{}, 0, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
			"image checks are temporarily unavailable, please try again").WithCause(logger.RedactErr(err, uid))
	}
	if ok {
		blocked, err := s.screen(ctx, d)
		if err != nil {
			s.vision.release(units)
			// Vision fetches the private object, so a concurrent finalize that already published and deleted it
			// surfaces here as a screening failure although the image is READY: converge on its result.
			if r, ok := s.resolvedElsewhere(ctx, d); ok {
				return r, 0, nil
			}
			return Result{}, 0, apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
				"image checks are temporarily unavailable, please try again").WithCause(logger.RedactErr(err, uid))
		}
		spent = units
		if blocked {
			r, err := s.reject(ctx, d, reasonPolicy)
			return r, spent, err
		}
	} else {
		logger.SetRequestField(ctx, fieldExhausted, true)
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
	ext := extension(d.ContentType)
	pub, pubThumb := publicObject(d.ID, ext), publicThumbObject(d.ID, ext)
	if err := s.Objects.Publish(ctx, d.UploadPath, pub, d.ContentType); err != nil {
		if errors.Is(err, objstore.ErrObjectNotFound) {
			r, _, rerr := s.uploadMissing(ctx, uid, d, true, err)
			return r, spent, rerr
		}
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: publish full: %w", err), uid)
	}
	if err := s.Objects.Publish(ctx, d.ThumbUploadPath, pubThumb, d.ContentType); err != nil {
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
// Error Reporting) rather than a silent client retry.
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
	return Result{}, 0, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
		"the upload is not complete yet").WithMeta("media_id", d.ID)
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
	for _, o := range []struct {
		object, md5 string
		size        int64
		max         int64
	}{
		{d.UploadPath, d.FullMD5, d.Bytes, MaxFullBytes},
		{d.ThumbUploadPath, d.ThumbMD5, d.ThumbBytes, MaxThumbBytes},
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
		case a.ContentType != d.ContentType:
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
		if sniffImage(head) != d.ContentType {
			return reasonInvalid, nil
		}
	}
	return "", nil
}

// screen runs SafeSearch on the full image and, when ScreenThumb, the thumbnail (the small image is what lists
// show, and it is uploaded separately). It reports whether either is blocked by the policy.
func (s *service) screen(ctx context.Context, d *Doc) (blocked bool, err error) {
	objects := []string{d.UploadPath}
	if s.ScreenThumb {
		objects = append(objects, d.ThumbUploadPath)
	}
	type out struct {
		ss  SafeSearch
		err error
	}
	outs := make([]out, len(objects))
	var wg sync.WaitGroup
	for i, o := range objects {
		wg.Add(1)
		go func() {
			defer wg.Done()
			outs[i].ss, outs[i].err = s.Moderator.SafeSearch(ctx, o)
		}()
	}
	wg.Wait()
	for _, o := range outs {
		if o.err != nil {
			return false, o.err
		}
		if blockedBySafeSearch(o.ss, Purpose(d.Purpose)) {
			blocked = true
		}
	}
	return blocked, nil
}

// blockedBySafeSearch is ADR-0005's policy: LIKELY or VERY_LIKELY adult or violence, and racy for avatars.
func blockedBySafeSearch(ss SafeSearch, p Purpose) bool {
	if ss.Adult >= LikelihoodLikely || ss.Violence >= LikelihoodLikely {
		return true
	}
	return p == PurposeAvatar && ss.Racy >= LikelihoodLikely
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
