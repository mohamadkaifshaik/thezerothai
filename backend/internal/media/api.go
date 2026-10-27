// Package media owns media/{mediaId} and the SafeSearch counter admin/vision-{yyyymm} (ADR-0003, ADR-0005). It
// exposes Service (consumed by server.go, the Connect handler), Attacher and AvatarReader (consumed by posts and
// identity through their own consumer-side interfaces), the PostDelete job handler, and the Eraser/Exporter seams
// the account-lifecycle job uses.
//
// The pipeline (ADR-0005): CreateUpload reserves 1-4 media ids and signs PUT URLs for a PRIVATE upload bucket;
// the client PUTs straight to GCS (media never passes through the API, CLAUDE.md rule 7); FinalizeUpload verifies
// size, type, MD5 and magic bytes, screens the image with SafeSearch (bounded by VISION_MONTHLY_CAP), and only then
// copies it into the PUBLIC bucket. Unmoderated bytes are therefore never publicly readable.
package media

import (
	"context"
	"errors"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/objstore"
)

// FlagName is the wire name MediaService checks (FEATURE_MEDIA <-> "media").
const FlagName = "media"

// Status mirrors mediav1.MediaStatus as a plain string stored in the document.
type Status string

const (
	StatusPending         Status = "PENDING"
	StatusReady           Status = "READY"
	StatusReadyUnscreened Status = "READY_UNSCREENED"
	StatusRejected        Status = "REJECTED"
)

// Purpose mirrors mediav1.MediaPurpose.
type Purpose string

const (
	PurposePost   Purpose = "POST"
	PurposeAvatar Purpose = "AVATAR"
	// PurposeBanner is the profile cover image (ADR-0024 D1): exactly one image, full 1500 x 500 and thumb 600 x 200.
	PurposeBanner Purpose = "BANNER"
)

// ProfileExtrasFlagName is the wire name of FEATURE_PROFILE_EXTRAS (ADR-0024 D9). CreateUpload(BANNER) needs it on
// for the caller on top of FlagName. Defined here because media must not import identity.
const ProfileExtrasFlagName = "profile_extras"

// Limits (ADR-0005).
const (
	// MaxPerPost is the most images one post carries (and one CreateUpload reserves).
	MaxPerPost = 4
	// MaxFullBytes and MaxThumbBytes are the signed x-goog-content-length-range upper bounds (POST and AVATAR;
	// BANNER has its own, stricter caps below, see capsFor).
	MaxFullBytes  = 2 << 20
	MaxThumbBytes = 256 << 10
	// BannerMaxFullBytes and BannerMaxThumbBytes are the BANNER caps (ADR-0024 D1): a 1500 x 500 WebP q75 is about
	// 60-150 KB, a 600 x 200 thumb about 20 KB.
	BannerMaxFullBytes  = 1 << 20
	BannerMaxThumbBytes = 128 << 10
	// BannerMaxWidth and BannerMaxHeight bound the declared banner size; the declared shape must be 3:1 within
	// 2% (see validateBannerShape).
	BannerMaxWidth  = 1500
	BannerMaxHeight = 500
	// BannerVisionUnits is what one banner costs: SafeSearch on the full image and the thumbnail.
	BannerVisionUnits = 2
	// MaxDimension bounds the declared width/height (the client resizes to <= 1600 px; this is a sanity bound).
	MaxDimension = 4096
	// MaxBlurhashLen is the BlurHash length bound (common.MediaRef.blurhash <= 64 chars).
	MaxBlurhashLen = 64
	// UploadURLTTL is how long a signed PUT URL is valid.
	UploadURLTTL = 10 * time.Minute
	// PendingTTL is how long a PENDING (or REJECTED) document lives before Firestore's TTL removes it; it equals
	// the upload bucket's 2-day lifecycle rule.
	PendingTTL = 48 * time.Hour
	// AccountAgeForUnscreened is the age an account needs before its uploads may publish unscreened once the
	// Vision cap is spent (ADR-0005).
	AccountAgeForUnscreened = 7 * 24 * time.Hour
)

// Ref is a published image (common.v1.MediaRef without the alt text, which belongs to the post).
type Ref struct {
	ID       string
	URL      string
	ThumbURL string
	Width    int
	Height   int
	Blurhash string
}

// Errors.
var (
	// ErrNotReady means a media id is missing, owned by someone else, of the wrong purpose, not READY, or already
	// attached to a post: one answer for all of them (no oracle).
	ErrNotReady = errors.New("media: not ready")
	// ErrInvalidID is returned for an id that is not a media id.
	ErrInvalidID = errors.New("media: invalid media id")
)

// Likelihood mirrors Vision's likelihood scale.
type Likelihood int

const (
	LikelihoodUnknown Likelihood = iota
	LikelihoodVeryUnlikely
	LikelihoodUnlikely
	LikelihoodPossible
	LikelihoodLikely
	LikelihoodVeryLikely
)

// SafeSearch is the subset of Vision's SafeSearch annotation the policy uses.
type SafeSearch struct {
	Adult, Violence, Racy Likelihood
}

// Moderator screens one object of the upload bucket. The Vision implementation reads it through a gs:// URI, so
// no image bytes cross the API.
type Moderator interface {
	SafeSearch(ctx context.Context, object string) (SafeSearch, error)
}

// Signer signs a V4 PUT URL for an object of the upload bucket (no GCS call).
type Signer interface {
	SignPut(ctx context.Context, object, contentType, md5b64 string, maxBytes int64, ttl time.Duration, now time.Time) (url string, headers map[string]string, err error)
}

// Objects is the two-bucket object seam FinalizeUpload and the cleanup paths use.
type Objects interface {
	// UploadAttrs and UploadHead read an object of the private upload bucket (1 Class B each).
	UploadAttrs(ctx context.Context, object string) (objstore.Attrs, error)
	UploadHead(ctx context.Context, object string, n int64) ([]byte, error)
	// Publish copies an upload object into the public bucket with a long immutable Cache-Control (1 Class A).
	Publish(ctx context.Context, uploadObject, publicObject, contentType string) error
	// DeleteUpload and DeletePublic remove an object; a missing object is success (free operations).
	DeleteUpload(ctx context.Context, object string) error
	DeletePublic(ctx context.Context, object string) error
}

// Directory is the one thing media needs from identity: the account's creation time (new-account quotas and the
// exhausted-cap policy). Implemented by a consumer-side adapter in apiserver over identity.Directory.
type Directory interface {
	AccountCreatedAt(ctx context.Context, uid string) (time.Time, error)
}

// FlagChecker is *flags.Registry's Enabled.
type FlagChecker interface {
	Enabled(uid, name string) bool
}

// IDGenerator draws media ids (*snowflake.Node).
type IDGenerator interface{ Generate() string }

// UploadItem is one requested image of CreateUpload.
type UploadItem struct {
	ContentType string
	FullBytes   int64
	ThumbBytes  int64
	Width       int
	Height      int
	// FullMD5 and ThumbMD5 are base64 MD5s of the files.
	FullMD5  string
	ThumbMD5 string
}

// SignedPut is one signed upload URL.
type SignedPut struct {
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}

// UploadTarget is the signed pair for one media id.
type UploadTarget struct {
	MediaID string
	Full    SignedPut
	Thumb   SignedPut
}

// FinalizeItem is one image of FinalizeUpload.
type FinalizeItem struct {
	MediaID  string
	Blurhash string
}

// Result is one image's finalize outcome. Ref is set for READY and READY_UNSCREENED.
type Result struct {
	MediaID         string
	Status          Status
	Ref             *Ref
	RejectionReason string
}

// Service is the Connect handler's dependency.
type Service interface {
	// CreateUpload reserves len(items) media ids and signs their PUT URLs. Firestore: reads 2 (idempotency,
	// quotas), writes 2 + len(items) (idempotency, quotas, one media doc each); replay: 1 read, 0 writes. GCS: 0.
	// A BANNER (ADR-0024 D1) is exactly one item with its own byte caps (1 MiB / 128 KiB) and a 3:1 declared shape; same
	// reads and writes (2 / 3), and the Server additionally needs profile_extras on for the caller (0 reads when off).
	CreateUpload(ctx context.Context, uid string, in CreateUploadInput) ([]UploadTarget, error)
	// FinalizeUpload verifies, screens and publishes the uploaded objects. Idempotent per item. Firestore: reads
	// 2*len(items) + 1 (media docs, the Vision counter cached 60 s, +1 per item whose upload is missing, whose
	// screening fails or whose finalize race is lost), plus the interceptor read; writes len(items) + 1.
	// Vision units: 1 per image, 2 with VISION_SCREEN_THUMB and always 2 for a BANNER.
	FinalizeUpload(ctx context.Context, uid string, items []FinalizeItem) ([]Result, error)
}

// CreateUploadInput is the CreateUpload request at the domain layer.
type CreateUploadInput struct {
	IdempotencyKey string
	Purpose        Purpose
	Items          []UploadItem
}

// Reader is what other modules' adapters use to turn media ids into published refs.
type Reader interface {
	// ResolveAvatar returns the READY (or READY_UNSCREENED) AVATAR media id owned by uid. ErrNotReady otherwise.
	// Reads: 1.
	ResolveAvatar(ctx context.Context, uid, mediaID string) (Ref, error)
	// ResolveBanner returns the READY (or READY_UNSCREENED) BANNER media id owned by uid (ADR-0024 D1; Ref.URL is the
	// 1500 px image, Ref.ThumbURL the 600 px one). ErrNotReady for every other case: missing, someone else's,
	// another purpose, PENDING or REJECTED. Reads: 1.
	ResolveBanner(ctx context.Context, uid, mediaID string) (Ref, error)
}
