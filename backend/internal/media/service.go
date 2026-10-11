package media

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// Request-log fields. They ride on the mw.Logging line; values are enums, counts and booleans only: never a uid,
// object path or URL.
const (
	fieldOp          = "media_op"
	fieldOutcome     = "outcome"
	fieldImages      = "media_images"
	fieldReady       = "media_ready"
	fieldUnscreened  = "media_unscreened"
	fieldRejected    = "media_rejected"
	fieldVisionUnits = "vision_units"
	fieldExhausted   = "vision_cap_exhausted"
)

// mediaIDPattern is the media id shape (19-digit zero-padded Snowflake decimal, like post ids).
var mediaIDPattern = regexp.MustCompile(`^[0-9]{19}$`)

// base83 is BlurHash's alphabet.
var blurhashPattern = regexp.MustCompile(`^[0-9A-Za-z#$%*+,\-.:;=?@\[\]^_{|}~]{0,64}$`)

// md5b64Pattern is the base64 of a 16-byte MD5 (22 chars + "==").
var md5b64Pattern = regexp.MustCompile(`^[A-Za-z0-9+/]{22}==$`)

// Rejection reasons are safe to show to the user (MediaResult.rejection_reason).
const (
	reasonInvalid  = "This image could not be used. Please choose a different one."
	reasonPolicy   = "This image can't be used because it may break the community rules."
	reasonCapacity = "Image uploads are temporarily limited. Please try again later."
)

// Deps is everything New needs.
type Deps struct {
	Repo      Repo
	Signer    Signer
	Objects   Objects
	Moderator Moderator
	Directory Directory
	IDs       IDGenerator
	// PublicBaseURL is the URL prefix public objects are served from, no trailing slash.
	PublicBaseURL string
	// Daily upload quotas (units are images) and the new-account window (config.QuotaConfig).
	MediaPerDay           int64
	NewAccountMediaPerDay int64
	NewAccountWindow      time.Duration
	// VisionMonthlyCap, Policy and ScreenThumb are ADR-0005's runaway-bill guard and its fallback.
	VisionMonthlyCap int64
	Policy           config.VisionExhaustedPolicy
	ScreenThumb      bool
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
	Log *slog.Logger
}

type service struct {
	Deps
	vision *visionBudget
}

// New builds the media service. Missing dependencies are a programming error caught at startup.
func New(d Deps) (Service, error) {
	switch {
	case d.Repo == nil || d.Signer == nil || d.Objects == nil || d.Moderator == nil || d.Directory == nil || d.IDs == nil:
		return nil, errors.New("media: service needs Repo, Signer, Objects, Moderator, Directory and IDs")
	case d.PublicBaseURL == "":
		return nil, errors.New("media: service needs PublicBaseURL")
	}
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Policy == "" {
		d.Policy = config.VisionPolicyEstablished
	}
	return &service{Deps: d, vision: &visionBudget{repo: d.Repo, cap: d.VisionMonthlyCap, now: d.Now}}, nil
}

// extension maps an accepted content type to the object extension.
func extension(contentType string) string {
	if contentType == "image/webp" {
		return "webp"
	}
	return "jpg"
}

func uploadObject(uid, id, ext string) string      { return "u/" + uid + "/" + id + "." + ext }
func uploadThumbObject(uid, id, ext string) string { return "u/" + uid + "/" + id + "_t." + ext }
func publicObject(id, ext string) string           { return "m/" + id + "." + ext }
func publicThumbObject(id, ext string) string      { return "m/" + id + "_t." + ext }

func joinIDs(ids []string) string { return strings.Join(ids, ",") }

func splitIDs(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}

func idemKeyIssue(key string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

func validateUploadItem(i int, it UploadItem) error {
	field := func(name string) string { return fmt.Sprintf("items[%d].%s", i, name) }
	switch {
	case it.ContentType != "image/webp" && it.ContentType != "image/jpeg":
		return apierr.Validation(field("content_type"), "content_type must be image/webp or image/jpeg")
	case it.FullBytes <= 0 || it.FullBytes > MaxFullBytes:
		return apierr.Validation(field("full_size_bytes"), "the image must be at most 2 MiB after compression")
	case it.ThumbBytes <= 0 || it.ThumbBytes > MaxThumbBytes:
		return apierr.Validation(field("thumb_size_bytes"), "the thumbnail must be at most 256 KiB")
	case it.Width <= 0 || it.Width > MaxDimension || it.Height <= 0 || it.Height > MaxDimension:
		return apierr.Validation(field("width"), "width and height must be between 1 and 4096")
	case !md5b64Pattern.MatchString(it.FullMD5):
		return apierr.Validation(field("full_md5"), "full_md5 must be the base64 MD5 of the file")
	case !md5b64Pattern.MatchString(it.ThumbMD5):
		return apierr.Validation(field("thumb_md5"), "thumb_md5 must be the base64 MD5 of the file")
	}
	return nil
}

// requestHash is the canonical body hash for IDEMPOTENCY_KEY_REUSED (fixed field order).
func requestHash(purpose Purpose, items []UploadItem) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "v1|purpose=%s", purpose)
	for _, it := range items {
		fmt.Fprintf(&sb, "|%s,%d,%d,%d,%d,%s,%s", it.ContentType, it.FullBytes, it.ThumbBytes, it.Width, it.Height, it.FullMD5, it.ThumbMD5)
	}
	return idempotency.HashRequest(sb.String())
}

// CreateUpload implements Service (ADR-0005; see the CreateUpload proto comment for the budget).
func (s *service) CreateUpload(ctx context.Context, uid string, in CreateUploadInput) (_ []UploadTarget, err error) {
	logger.SetRequestField(ctx, fieldOp, "create_upload")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := idemKeyIssue(in.IdempotencyKey); err != nil {
		return nil, err
	}
	if in.Purpose != PurposePost && in.Purpose != PurposeAvatar {
		return nil, apierr.Validation("purpose", "purpose must be POST or AVATAR")
	}
	n := len(in.Items)
	switch {
	case n == 0:
		return nil, apierr.Validation("items", "at least one image is required")
	case n > MaxPerPost:
		return nil, apierr.Validation("items", "at most 4 images per upload")
	case in.Purpose == PurposeAvatar && n != 1:
		return nil, apierr.Validation("items", "an avatar is exactly one image")
	}
	for i, it := range in.Items {
		if err := validateUploadItem(i, it); err != nil {
			return nil, err
		}
	}
	logger.SetRequestField(ctx, fieldImages, n)

	createdAt, err := s.Directory.AccountCreatedAt(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("media: load account: %w", err), uid)
	}
	now := s.Now().UTC()
	limit := s.MediaPerDay
	if !createdAt.IsZero() && now.Sub(createdAt) < s.NewAccountWindow {
		limit = s.NewAccountMediaPerDay
	}

	expire := now.Add(PendingTTL)
	docs := make([]Doc, n)
	for i, it := range in.Items {
		id := s.IDs.Generate()
		ext := extension(it.ContentType)
		docs[i] = Doc{
			ID: id, OwnerID: uid, Purpose: string(in.Purpose), Status: string(StatusPending),
			ContentType: it.ContentType, Bytes: it.FullBytes, ThumbBytes: it.ThumbBytes, Width: it.Width, Height: it.Height,
			FullMD5: it.FullMD5, ThumbMD5: it.ThumbMD5,
			UploadPath: uploadObject(uid, id, ext), ThumbUploadPath: uploadThumbObject(uid, id, ext),
			CreatedAt: now, ExpireAt: &expire,
		}
	}
	res, err := s.Repo.CreateUploads(ctx, CreateUploadsParams{
		UID: uid, IdemKey: idempotency.Key(uid, createRPC, in.IdempotencyKey),
		RequestHash: requestHash(in.Purpose, in.Items), QuotaLimit: limit, Docs: docs,
	})
	if err != nil {
		if errors.Is(err, ErrKeyReused) {
			return nil, apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
				"this idempotency_key was already used for a different request")
		}
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return nil, err
		}
		return nil, logger.RedactErr(fmt.Errorf("media: create upload: %w", err), uid)
	}
	ids := make([]string, n)
	for i := range docs {
		ids[i] = docs[i].ID
	}
	outcome := "created"
	if res.ReplayIDs != nil {
		if len(res.ReplayIDs) != n {
			return nil, logger.RedactErr(fmt.Errorf("media: replay holds %d ids for %d items", len(res.ReplayIDs), n), uid)
		}
		ids = res.ReplayIDs
		outcome = "replay"
	}
	logger.SetRequestField(ctx, fieldOutcome, outcome)

	targets := make([]UploadTarget, n)
	for i, it := range in.Items {
		ext := extension(it.ContentType)
		full, err := s.sign(ctx, uploadObject(uid, ids[i], ext), it.ContentType, it.FullMD5, MaxFullBytes, now)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("media: sign full: %w", err), uid)
		}
		thumb, err := s.sign(ctx, uploadThumbObject(uid, ids[i], ext), it.ContentType, it.ThumbMD5, MaxThumbBytes, now)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("media: sign thumb: %w", err), uid)
		}
		targets[i] = UploadTarget{MediaID: ids[i], Full: full, Thumb: thumb}
	}
	return targets, nil
}

func (s *service) sign(ctx context.Context, object, contentType, md5b64 string, max int64, now time.Time) (SignedPut, error) {
	u, h, err := s.Signer.SignPut(ctx, object, contentType, md5b64, max, UploadURLTTL, now)
	if err != nil {
		return SignedPut{}, err
	}
	return SignedPut{URL: u, Headers: h, ExpiresAt: now.Add(UploadURLTTL)}, nil
}

func (s *service) refOf(d *Doc) *Ref {
	return &Ref{
		ID: d.ID, URL: s.PublicBaseURL + "/" + d.PublicPath, ThumbURL: s.PublicBaseURL + "/" + d.ThumbPath,
		Width: d.Width, Height: d.Height, Blurhash: d.Blurhash,
	}
}

func (s *service) resultOf(d *Doc) Result {
	r := Result{MediaID: d.ID, Status: Status(d.Status), RejectionReason: d.RejectionReason}
	if d.Published() {
		r.Ref = s.refOf(d)
	}
	return r
}

// notFound is the one answer for a media id that does not exist or is not the caller's.
func notFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "media not found")
}

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
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: publish full: %w", err), uid)
	}
	if err := s.Objects.Publish(ctx, d.ThumbUploadPath, pubThumb, d.ContentType); err != nil {
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: publish thumb: %w", err), uid)
	}
	err = s.Repo.Resolve(ctx, d.ID, d.UpdateTime, Resolution{Status: status, PublicPath: pub, ThumbPath: pubThumb, Blurhash: blurhash})
	switch {
	case errors.Is(err, ErrConflict):
		return s.reload(ctx, uid, d.ID, spent)
	case err != nil:
		return Result{}, spent, logger.RedactErr(fmt.Errorf("media: resolve: %w", err), uid)
	}
	s.deleteUploads(ctx, d)
	out := *d
	out.Status, out.PublicPath, out.ThumbPath, out.Blurhash = string(status), pub, pubThumb, blurhash
	return s.resultOf(&out), spent, nil
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
// there yet is a precondition failure (the client has not finished uploading).
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
			return "", apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
				"the upload is not complete yet").WithMeta("media_id", d.ID)
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
			return "", apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
				"the upload is not complete yet").WithMeta("media_id", d.ID)
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
	s.deleteUploads(ctx, d)
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

// visionBudget is the SafeSearch cost meter: the month's unit count is read from admin/vision-{yyyymm} at most
// once per 60 s per instance and advanced locally by what this instance reserves, so up to max-instances (3)
// instances may overshoot the cap by a few units, which the cap's headroom already covers (ADR-0005).
type visionBudget struct {
	repo Repo
	cap  int64
	now  func() time.Time

	mu     sync.Mutex
	month  string
	used   int64
	loaded time.Time
}

const visionCacheTTL = 60 * time.Second

// monthKey is the counter's month, in UTC like Google Cloud billing.
func monthKey(t time.Time) string { return t.UTC().Format("200601") }

// reserve takes n units if they fit under the cap. It reads the counter (1 read) when the cached value is older
// than visionCacheTTL or from another month.
func (v *visionBudget) reserve(ctx context.Context, n int64) (bool, error) {
	if v.cap <= 0 {
		return false, nil
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	now, month := v.now(), monthKey(v.now())
	if v.month != month || now.Sub(v.loaded) >= visionCacheTTL {
		used, err := v.repo.VisionUsed(ctx, month)
		if err != nil {
			return false, err
		}
		v.month, v.used, v.loaded = month, used, now
	}
	if v.used+n > v.cap {
		return false, nil
	}
	v.used += n
	return true, nil
}

// release returns units reserved for a screening that failed before spending them.
func (v *visionBudget) release(n int64) {
	v.mu.Lock()
	v.used -= n
	v.mu.Unlock()
}

// sniffImage returns the content type the first bytes of an image file claim, or "".
func sniffImage(head []byte) string {
	switch {
	case len(head) >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF:
		return "image/jpeg"
	case len(head) >= 12 && string(head[0:4]) == "RIFF" && string(head[8:12]) == "WEBP":
		return "image/webp"
	}
	return ""
}
