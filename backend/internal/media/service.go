package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"
	"golang.org/x/sync/singleflight"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// Request-log fields. They ride on the mw.Logging line; values are enums, counts and booleans only: never a uid,
// object path or URL.
const (
	fieldOp                = "media_op"
	fieldPurpose           = "purpose" // POST, AVATAR or BANNER (enum only)
	fieldOutcome           = "outcome"
	fieldImages            = "media_images"
	fieldContentType       = "content_type" // image/jpeg, image/webp or image/gif (validated or from the stored document)
	fieldReady             = "media_ready"
	fieldUnscreened        = "media_unscreened"
	fieldRejected          = "media_rejected"
	fieldVisionUnits       = "vision_units"
	fieldExhausted         = "vision_cap_exhausted"
	fieldAttemptsExhausted = "attempts_exhausted"  // "assessed" or "claims" (A5.4 pre-check)
	fieldConverged         = "finalize_converged"  // a lost finalize race answered with the winner's result
	fieldBusy              = "finalize_busy"       // another call holds the screening claim (W3-22 M-3): MEDIA_NOT_READY, no Vision units
	fieldJoined            = "finalize_joined"     // answered with the result of a same-instance call already finalizing this image
	fieldScreenOutcome     = "screen_outcome"      // ready, rejected_policy, rejected_invalid, assessed (an attempt consumed) or unassessed (a retry consumed)
	fieldScreenClaims      = "screen_claims"       // the doc's screenAttempts after this call's claim
	fieldScreenAssessed    = "screen_assessed"     // the doc's screenAssessed after this call
	fieldUnitsRefused      = "units_daily_refused" // media_vision_units_daily refused the call before the claim (A5.5)
	fieldGifBusy           = "gif_busy"            // the GIF slot stayed busy for GifQueueWait: no claim, no write (A5.1)
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
	reasonAttempts = "We couldn't check this image. Remove it and choose another."
	// reasonGifLarge is the pre-scan refusal and the decode deadline (ADR-0029 D11).
	reasonGifLarge = "This GIF is too large or too long."
)

// Deps is everything New needs.
type Deps struct {
	Repo      Repo
	Signer    Signer
	Objects   Objects
	Moderator Moderator
	Directory Directory
	IDs       IDGenerator
	// NameSuffix returns the random suffix of a new upload's public object names; nil means newNameSuffix (crypto/rand).
	// Overridable for tests only.
	NameSuffix func() (string, error)
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
	// GifMaxEdge is GIF_MAX_EDGE (ADR-0029 D11): the largest declared GIF width or height at CreateUpload. 0 means 1,280.
	// GifMaxFrames and GifMaxFrameAreaSum are GIF_MAX_FRAMES and GIF_MAX_FRAME_AREA_SUM, the pre-scan limits of
	// FinalizeUpload's frame-sampled screen (D11). 0 means 300 and 50,000,000 pixels.
	GifMaxEdge         int
	GifMaxFrames       int
	GifMaxFrameAreaSum int64
	// MediaMaxScreenAttempts is MEDIA_MAX_SCREEN_ATTEMPTS (W6-27): screening claims per media document before it is REJECTED. 0 means 3.
	// MediaMaxScreenAttempts is MEDIA_MAX_SCREEN_ATTEMPTS (revised by W6-40, ADR-0029 Amendment 1 A5.4): attempts that produced a valid assessment
	// (screenAssessed) before the document is REJECTED. 0 means 3.
	MediaMaxScreenAttempts int
	// MediaMaxScreenRetries is MEDIA_MAX_SCREEN_RETRIES: claimed attempts with no valid assessment. nil means 5; a pointer because 0 is a valid setting.
	// With the attempts it sets the claims ceiling on screenAttempts.
	MediaMaxScreenRetries *int
	// VisionUnitsPerDay and VisionUnitsPerDayNewAccount are MEDIA_VISION_UNITS_PER_DAY and MEDIA_VISION_UNITS_PER_DAY_NEW_ACCOUNT: the per-uid Vision
	// units a day this instance allows (A5.5). 0 means 60 and 12.
	VisionUnitsPerDay           int64
	VisionUnitsPerDayNewAccount int64
	// GifQueueWait is how long a GIF waits for the per-instance screening slot before MEDIA_NOT_READY (0 = 5 s) and
	// GifDecodeTimeout the sampler's deadline (0 = 2 s). Overridable for tests.
	GifQueueWait     time.Duration
	GifDecodeTimeout time.Duration
	// Now is overridable for tests; nil means time.Now.
	Now func() time.Time
	Log *slog.Logger
}

type service struct {
	Deps
	vision *visionBudget
	// flight collapses concurrent FinalizeUpload calls for one media id on this instance (W3-22 M-3, part a); the
	// screening claim (part b) covers the other instances.
	flight singleflight.Group
	// gifSlot is the GIF screening semaphore (capacity 1): at most one GIF is read and sampled at a time on this instance.
	gifSlot chan struct{}
	// unitsCap and unitsCapNew are the per-uid Vision-units daily cap (media_vision_units_daily, A5.5), established and new-account tiers; in memory
	// per instance, reset by a restart.
	unitsCap, unitsCapNew *ratelimit.DailyCap
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
	if d.NameSuffix == nil {
		d.NameSuffix = newNameSuffix
	}
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Policy == "" {
		d.Policy = config.VisionPolicyEstablished
	}
	if d.VisionUnitsPerDay <= 0 {
		d.VisionUnitsPerDay = defaultVisionUnitsPerDay
	}
	if d.VisionUnitsPerDayNewAccount <= 0 {
		d.VisionUnitsPerDayNewAccount = defaultVisionUnitsPerDayNewAccount
	}
	return &service{
		Deps: d, vision: &visionBudget{repo: d.Repo, cap: d.VisionMonthlyCap, now: d.Now}, gifSlot: make(chan struct{}, 1),
		unitsCap: ratelimit.NewDailyCap(d.VisionUnitsPerDay).WithClock(d.Now), unitsCapNew: ratelimit.NewDailyCap(d.VisionUnitsPerDayNewAccount).WithClock(d.Now),
	}, nil
}

// extension maps an accepted content type to the object extension.
func extension(contentType string) string {
	switch contentType {
	case ContentTypeWebP:
		return "webp"
	case ContentTypeGIF:
		return "gif"
	}
	return "jpg"
}

// thumbTypeOf is the thumbnail type of an upload item: its own, else the full image's (an older client sends none).
func thumbTypeOf(it UploadItem) string {
	if it.ThumbContentType != "" {
		return it.ThumbContentType
	}
	return it.ContentType
}

// storedThumbType is what the media doc stores: "" when the thumbnail has the full image's type (absent = same).
func storedThumbType(it UploadItem) string {
	if it.ThumbContentType == it.ContentType {
		return ""
	}
	return it.ThumbContentType
}

func uploadObject(uid, id, ext string) string      { return "u/" + uid + "/" + id + "." + ext }
func uploadThumbObject(uid, id, ext string) string { return "u/" + uid + "/" + id + "_t." + ext }

// nameSuffixLen is the number of random bytes behind a public object name suffix (128 bits, W3-39).
const nameSuffixLen = 16

// newNameSuffix returns 128 bits from crypto/rand as 32 lowercase hex characters. The public bucket is public-read,
// so a name that can be derived from the media id would let anyone who learns an id fetch an image whose post they
// may not see (ADR-0025 note W3-36 M-2); the suffix makes new names unguessable. The alphabet has no "_" and no "-",
// so the suffix can never be confused with the id separator or the thumbnail marker.
func newNameSuffix() (string, error) {
	var b [nameSuffixLen]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("media: name suffix: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}

// publicObject is the public full-size object name: "m/{id}-{suffix}.{ext}", or the pre-W3-39 "m/{id}.{ext}" when
// the document has no nameSuffix (old objects keep their names, founder B1).
func publicObject(id, suffix, ext string) string { return "m/" + id + suffixPart(suffix) + "." + ext }

// publicThumbObject is the thumbnail name: "m/{id}-{suffix}_t.{ext}" or "m/{id}_t.{ext}".
func publicThumbObject(id, suffix, ext string) string {
	return "m/" + id + suffixPart(suffix) + "_t." + ext
}

func suffixPart(suffix string) string {
	if suffix == "" {
		return ""
	}
	return "-" + suffix
}

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

func (s *service) validateUploadItem(i int, p Purpose, it UploadItem) error {
	field := func(name string) string { return fmt.Sprintf("items[%d].%s", i, name) }
	maxFull, maxThumb := capsFor(p)
	switch it.ContentType {
	case ContentTypeWebP, ContentTypeJPEG:
	case ContentTypeGIF:
		if p != PurposePost { // ADR-0029 D10: AVATAR and BANNER refuse
			return apierr.Validation(field("content_type"), "a GIF can only be used in a post")
		}
	default:
		return apierr.Validation(field("content_type"), "content_type must be image/webp, image/jpeg or image/gif")
	}
	if err := validateThumbType(field("thumb_content_type"), it); err != nil {
		return err
	}
	switch {
	case it.FullBytes <= 0 || it.FullBytes > maxFull:
		return apierr.Validation(field("full_size_bytes"), fmt.Sprintf("the image must be at most %s after compression", byteSize(maxFull)))
	case it.ThumbBytes <= 0 || it.ThumbBytes > maxThumb:
		return apierr.Validation(field("thumb_size_bytes"), fmt.Sprintf("the thumbnail must be at most %s", byteSize(maxThumb)))
	case it.Width <= 0 || it.Width > MaxDimension || it.Height <= 0 || it.Height > MaxDimension:
		return apierr.Validation(field("width"), "width and height must be between 1 and 4096")
	case it.ContentType == ContentTypeGIF && (it.Width > s.gifMaxEdge() || it.Height > s.gifMaxEdge()):
		return apierr.Validation(field("width"), fmt.Sprintf("a GIF can be at most %d pixels on each side", s.gifMaxEdge()))
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

// validateThumbType checks thumb_content_type (ADR-0029 D10): for a GIF it is required and must be a still (JPEG or
// WebP); for JPEG and WebP it must be empty or equal to content_type, so an older client is unchanged.
func validateThumbType(field string, it UploadItem) error {
	t := it.ThumbContentType
	if it.ContentType == ContentTypeGIF {
		if t != ContentTypeJPEG && t != ContentTypeWebP {
			return apierr.Validation(field, "a GIF thumbnail must be image/jpeg or image/webp")
		}
		return nil
	}
	if t != "" && t != it.ContentType {
		return apierr.Validation(field, "thumb_content_type must be empty or equal to content_type")
	}
	return nil
}

// gifMaxEdge is GIF_MAX_EDGE (ADR-0029 D11), 1,280 when unset.
func (s *service) gifMaxEdge() int {
	if s.GifMaxEdge > 0 {
		return s.GifMaxEdge
	}
	return 1280
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
		if t := storedThumbType(it); t != "" { // only when it differs, so a pre-W6 request hashes as before
			sb.WriteString(",tt=" + t)
		}
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
	if hasGIF(in.Items) && n != 1 { // ADR-0029 D10: one GIF per upload, never mixed with other items
		return nil, apierr.Validation("items", "a GIF is uploaded on its own")
	}
	for i, it := range in.Items {
		if err := s.validateUploadItem(i, in.Purpose, it); err != nil {
			return nil, err
		}
	}
	logger.SetRequestField(ctx, fieldContentType, in.Items[0].ContentType) // validated above: one of three constants
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
		suffix, err := s.NameSuffix()
		if err != nil {
			return nil, logger.RedactErr(err, uid)
		}
		docs[i] = Doc{
			ID: id, OwnerID: uid, Purpose: string(in.Purpose), Status: string(StatusPending),
			ContentType: it.ContentType, ThumbContentType: storedThumbType(it), Bytes: it.FullBytes, ThumbBytes: it.ThumbBytes, Width: it.Width, Height: it.Height,
			FullMD5: it.FullMD5, ThumbMD5: it.ThumbMD5,
			UploadPath: uploadObject(uid, id, ext), ThumbUploadPath: uploadThumbObject(uid, id, extension(thumbTypeOf(it))),
			NameSuffix: suffix,
			CreatedAt:  now, ExpireAt: &expire,
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
		thumb, err := s.sign(ctx, uploadThumbObject(uid, ids[i], extension(thumbTypeOf(it))), thumbTypeOf(it), it.ThumbMD5, maxThumb, now)
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
		Width: d.Width, Height: d.Height, Blurhash: d.Blurhash, ContentType: d.ContentType,
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
	case len(head) >= 6 && (string(head[0:6]) == "GIF87a" || string(head[0:6]) == "GIF89a"):
		return ContentTypeGIF
	}
	return ""
}

// hasGIF reports whether any item is a GIF.
func hasGIF(items []UploadItem) bool {
	for _, it := range items {
		if it.ContentType == ContentTypeGIF {
			return true
		}
	}
	return false
}
