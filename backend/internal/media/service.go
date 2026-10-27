package media

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-log fields. They ride on the mw.Logging line; values are enums, counts and booleans only: never a uid,
// object path or URL.
const (
	fieldOp          = "media_op"
	fieldPurpose     = "purpose" // POST, AVATAR or BANNER (enum only)
	fieldOutcome     = "outcome"
	fieldImages      = "media_images"
	fieldReady       = "media_ready"
	fieldUnscreened  = "media_unscreened"
	fieldRejected    = "media_rejected"
	fieldVisionUnits = "vision_units"
	fieldExhausted   = "vision_cap_exhausted"
	fieldConverged   = "finalize_converged" // a lost finalize race answered with the winner's result
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

// capsFor returns the signed-URL and verification byte caps of a purpose (ADR-0005; ADR-0024 D1 for BANNER).
func capsFor(p Purpose) (full, thumb int64) {
	if p == PurposeBanner {
		return BannerMaxFullBytes, BannerMaxThumbBytes
	}
	return MaxFullBytes, MaxThumbBytes
}

func validateUploadItem(i int, p Purpose, it UploadItem) error {
	field := func(name string) string { return fmt.Sprintf("items[%d].%s", i, name) }
	maxFull, maxThumb := capsFor(p)
	switch {
	case it.ContentType != "image/webp" && it.ContentType != "image/jpeg":
		return apierr.Validation(field("content_type"), "content_type must be image/webp or image/jpeg")
	case it.FullBytes <= 0 || it.FullBytes > maxFull:
		return apierr.Validation(field("full_size_bytes"), fmt.Sprintf("the image must be at most %s after compression", byteSize(maxFull)))
	case it.ThumbBytes <= 0 || it.ThumbBytes > maxThumb:
		return apierr.Validation(field("thumb_size_bytes"), fmt.Sprintf("the thumbnail must be at most %s", byteSize(maxThumb)))
	case it.Width <= 0 || it.Width > MaxDimension || it.Height <= 0 || it.Height > MaxDimension:
		return apierr.Validation(field("width"), "width and height must be between 1 and 4096")
	case !md5b64Pattern.MatchString(it.FullMD5):
		return apierr.Validation(field("full_md5"), "full_md5 must be the base64 MD5 of the file")
	case !md5b64Pattern.MatchString(it.ThumbMD5):
		return apierr.Validation(field("thumb_md5"), "thumb_md5 must be the base64 MD5 of the file")
	}
	if p == PurposeBanner {
		return validateBannerShape(field("width"), it.Width, it.Height)
	}
	return nil
}

// byteSize renders a cap for a validation message (1 MiB, 256 KiB).
func byteSize(n int64) string {
	if n >= 1<<20 {
		return fmt.Sprintf("%d MiB", n>>20)
	}
	return fmt.Sprintf("%d KiB", n>>10)
}

// validateBannerShape checks the declared banner size (ADR-0024 D1): width <= 1500, height <= 500 and 3:1 within 2%
// (294*h <= 100*w <= 306*h, integer arithmetic, bounds inclusive). The server checks the declaration, not pixels.
func validateBannerShape(field string, w, h int) error {
	if w > BannerMaxWidth || h > BannerMaxHeight || 100*w < 294*h || 100*w > 306*h {
		return apierr.Validation(field, "a banner must be 3:1, at most 1500 x 500")
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
	if in.Purpose != PurposePost && in.Purpose != PurposeAvatar && in.Purpose != PurposeBanner {
		return nil, apierr.Validation("purpose", "purpose must be POST, AVATAR or BANNER")
	}
	logger.SetRequestField(ctx, fieldPurpose, string(in.Purpose))
	n := len(in.Items)
	switch {
	case n == 0:
		return nil, apierr.Validation("items", "at least one image is required")
	case n > MaxPerPost:
		return nil, apierr.Validation("items", "at most 4 images per upload")
	case in.Purpose == PurposeAvatar && n != 1:
		return nil, apierr.Validation("items", "an avatar is exactly one image")
	case in.Purpose == PurposeBanner && n != 1:
		return nil, apierr.Validation("items", "a banner is exactly one image")
	}
	for i, it := range in.Items {
		if err := validateUploadItem(i, in.Purpose, it); err != nil {
			return nil, err
		}
	}
	logger.SetRequestField(ctx, fieldImages, n)

	createdAt, err := s.Directory.AccountCreatedAt(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("media: load account: %w", err), uid)
	}
	now := s.Now().UTC()
	maxFull, maxThumb := capsFor(in.Purpose)
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
		full, err := s.sign(ctx, uploadObject(uid, ids[i], ext), it.ContentType, it.FullMD5, maxFull, now)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("media: sign full: %w", err), uid)
		}
		thumb, err := s.sign(ctx, uploadThumbObject(uid, ids[i], ext), it.ContentType, it.ThumbMD5, maxThumb, now)
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
