package media

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	vision "google.golang.org/api/vision/v1"
)

// visionTimeout bounds one SafeSearch call (every outbound call has a deadline).
const visionTimeout = 10 * time.Second

// Vision is the Cloud Vision SafeSearch Moderator. It reads the object through its gs:// URI with the runtime
// service account's own credentials (roles/storage.objectAdmin on the upload bucket), so image bytes never cross
// the API. The service is built lazily on the first call, so nothing happens before ListenAndServe.
type Vision struct {
	bucket string

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
	svc, err := vision.NewService(context.WithoutCancel(ctx))
	if err != nil {
		return nil, fmt.Errorf("media: build vision service: %w", err)
	}
	v.svc = svc
	return svc, nil
}

// SafeSearch implements Moderator. An empty or error response is an error (fail closed: nothing is published
// without an answer).
func (v *Vision) SafeSearch(ctx context.Context, object string) (SafeSearch, error) {
	ctx, cancel := context.WithTimeout(ctx, visionTimeout)
	defer cancel()
	svc, err := v.service(ctx)
	if err != nil {
		return SafeSearch{}, err
	}
	req := &vision.BatchAnnotateImagesRequest{Requests: []*vision.AnnotateImageRequest{{
		Image:    &vision.Image{Source: &vision.ImageSource{ImageUri: "gs://" + v.bucket + "/" + object}},
		Features: []*vision.Feature{{Type: "SAFE_SEARCH_DETECTION"}},
	}}}
	resp, err := svc.Images.Annotate(req).Context(ctx).Do()
	if err != nil {
		return SafeSearch{}, fmt.Errorf("media: vision annotate: %w", err)
	}
	if len(resp.Responses) != 1 {
		return SafeSearch{}, fmt.Errorf("media: vision returned %d responses, want 1", len(resp.Responses))
	}
	r := resp.Responses[0]
	if r.Error != nil {
		return SafeSearch{}, fmt.Errorf("media: vision error code %d", r.Error.Code)
	}
	if r.SafeSearchAnnotation == nil {
		return SafeSearch{}, errors.New("media: vision returned no SafeSearch annotation")
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

var _ Moderator = AllowAll{}
