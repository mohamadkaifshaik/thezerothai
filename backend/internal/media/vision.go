package media

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"
	"time"

	vision "google.golang.org/api/vision/v1"
)

// visionTimeout bounds one SafeSearch call (every outbound call has a deadline). The call's context is also bounded by what is left of the
// request's own deadline (FinalizeUpload's 20 s), so a call gets the lesser of the two; screenAll refuses to start one with under minVisionBudget left.
const visionTimeout = 10 * time.Second

// errNotSent marks a Moderator failure that happened before any request reached Google (the Vision service could not be built: no credentials,
// a metadata-server failure). Nothing can have been billed, so the call's unit is returned to both counters (unbilled, W6-49).
var errNotSent = errors.New("media: vision request not sent")

// Vision is the Cloud Vision SafeSearch Moderator. SafeSearch reads the object through its gs:// URI with the runtime
// service account's own credentials (roles/storage.objectAdmin on the upload bucket), so a client's image bytes never
// cross the API; SafeSearchBytes sends the server-built GIF contact sheet inline. The service is built lazily on the first call, so nothing happens before ListenAndServe.
type Vision struct {
	bucket string
	// newService builds the API client on the first call; nil means vision.NewService. Overridable for tests only.
	newService func(ctx context.Context) (*vision.Service, error)

	mu  sync.Mutex
	svc *vision.Service
}

// NewVision returns a Moderator for objects of bucket. It does no I/O.
func NewVision(uploadBucket string) (*Vision, error) {
	if uploadBucket == "" {
		return nil, errors.New("media: vision needs the upload bucket name")
	}
	return &Vision{bucket: uploadBucket}, nil
}

var _ Moderator = (*Vision)(nil)

func (v *Vision) service(ctx context.Context) (*vision.Service, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.svc != nil {
		return v.svc, nil
	}
	build := v.newService
	if build == nil {
		build = func(ctx context.Context) (*vision.Service, error) { return vision.NewService(ctx) }
	}
	svc, err := build(context.WithoutCancel(ctx))
	if err != nil {
		return nil, fmt.Errorf("%w: build vision service: %w", errNotSent, err) // before any request: unbilled
	}
	v.svc = svc
	return svc, nil
}

// SafeSearch implements Moderator. An empty or error response is an error (fail closed: nothing is published
// without an answer).
func (v *Vision) SafeSearch(ctx context.Context, object string) (SafeSearch, error) {
	return v.annotate(ctx, &vision.Image{Source: &vision.ImageSource{ImageUri: "gs://" + v.bucket + "/" + object}})
}

// SafeSearchBytes implements Moderator: the image is sent inline (base64 in the JSON request; a GIF's contact sheet is
// under 1 MiB, far below Vision's 10 MB request cap).
func (v *Vision) SafeSearchBytes(ctx context.Context, image []byte) (SafeSearch, error) {
	return v.annotate(ctx, &vision.Image{Content: base64.StdEncoding.EncodeToString(image)})
}

func (v *Vision) annotate(ctx context.Context, img *vision.Image) (SafeSearch, error) {
	ctx, cancel := context.WithTimeout(ctx, visionTimeout)
	defer cancel()
	svc, err := v.service(ctx)
	if err != nil {
		return SafeSearch{}, err
	}
	req := &vision.BatchAnnotateImagesRequest{Requests: []*vision.AnnotateImageRequest{{
		Image:    img,
		Features: []*vision.Feature{{Type: "SAFE_SEARCH_DETECTION"}},
	}}}
	resp, err := svc.Images.Annotate(req).Context(ctx).Do()
	if err != nil {
		return SafeSearch{}, fmt.Errorf("media: vision annotate: %w", err)
	}
	if len(resp.Responses) != 1 {
		return SafeSearch{}, &VisionAnsweredError{Code: -1}
	}
	r := resp.Responses[0]
	if r.Error != nil {
		return SafeSearch{}, &VisionAnsweredError{Code: r.Error.Code}
	}
	if r.SafeSearchAnnotation == nil {
		return SafeSearch{}, &VisionAnsweredError{Code: -1}
	}
	a := r.SafeSearchAnnotation
	return SafeSearch{Adult: likelihood(a.Adult), Violence: likelihood(a.Violence), Racy: likelihood(a.Racy)}, nil
}

func likelihood(s string) Likelihood {
	switch s {
	case "VERY_UNLIKELY":
		return LikelihoodVeryUnlikely
	case "UNLIKELY":
		return LikelihoodUnlikely
	case "POSSIBLE":
		return LikelihoodPossible
	case "LIKELY":
		return LikelihoodLikely
	case "VERY_LIKELY":
		return LikelihoodVeryLikely
	default:
		return LikelihoodUnknown
	}
}

// AllowAll is the local-development Moderator (ENV=local only; wired in apiserver): there is no Vision emulator,
// so it reports every image as VERY_UNLIKELY. It must never be used outside ENV=local.
type AllowAll struct{}

// SafeSearch implements Moderator.
func (AllowAll) SafeSearch(context.Context, string) (SafeSearch, error) {
	return SafeSearch{Adult: LikelihoodVeryUnlikely, Violence: LikelihoodVeryUnlikely, Racy: LikelihoodVeryUnlikely}, nil
}

// SafeSearchBytes implements Moderator.
func (a AllowAll) SafeSearchBytes(ctx context.Context, _ []byte) (SafeSearch, error) {
	return a.SafeSearch(ctx, "")
}

var _ Moderator = AllowAll{}

// codeInvalidArgument is google.rpc.Code INVALID_ARGUMENT, which Vision reports per image for undecodable bytes
// ("Bad image data").
const codeInvalidArgument int64 = 3

// VisionAnsweredError is a Moderator error for a call that reached Vision and got an answer: a per-image error, an
// empty response, or a response without a SafeSearch annotation. Google bills such a call, so the screen counts its
// unit against VISION_MONTHLY_CAP (W6-27, security H-3). A failure without a response is not one: whether its unit comes back is decided by
// unbilled (only an HTTP 429 or 5xx answer or a failure before the request was sent; a timeout, a reset or an EOF may have been billed, W6-49).
// Code is the response's google.rpc.Code, or -1 when there was none.
type VisionAnsweredError struct{ Code int64 }

func (e *VisionAnsweredError) Error() string {
	return fmt.Sprintf("media: vision answered with error code %d", e.Code)
}

// Invalid reports whether Vision found the image undecodable (INVALID_ARGUMENT): a retry cannot fix it.
func (e *VisionAnsweredError) Invalid() bool { return e.Code == codeInvalidArgument }
