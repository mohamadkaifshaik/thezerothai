package apiserver

import (
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// buildOption changes how build wires the handler. Only tests pass one; Build passes none.
type buildOption func(*buildOpts)

type buildOpts struct {
	// audienceSource maps the posts service to the one posts.AudienceOf reads for the engagement lists. A test returns
	// a wrapper that hides the concrete type, to prove Build refuses to start without the seam (L-5).
	audienceSource func(posts.Service) posts.Service
	// outboxNow is the outbox's clock (staging and sweeping), so a test can make a staged item due. Nil: time.Now.
	outboxNow func() time.Time
	// inlinePostDeleteJobs wraps the publisher DeletePost calls inline (never the outbox sweep's), so a test can lose
	// the inline publish and watch the sweep deliver it.
	inlinePostDeleteJobs func(posts.PostDeleteJobs) posts.PostDeleteJobs
	// inlineBeaconEvents wraps the Events the beacons service calls inline (never the outbox sweep's beacon_cancelled
	// handler), so a test can lose the inline cancellation notices and watch the sweep deliver them.
	inlineBeaconEvents func(beacons.Events) beacons.Events
}

// protectedSeam is one place the protected-author set (or the Audience built on it) is wired into a module.
// Every module treats a nil seam as "nobody is protected" (by design for unit tests), so a wiring regression would
// fail open silently; Build checks them all at startup instead (L-5).
type protectedSeam struct {
	name  string
	value any
}

// requireProtectedSeams returns an error naming every seam that is nil (including a typed nil), or nil when all eight
// are wired. It runs before ListenAndServe, so a refactor that drops one fails the deploy, not a user's privacy.
func requireProtectedSeams(seams []protectedSeam) error {
	missing := nilSeams(seams)
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("protected-author seams not wired (would fail open): %s: %w", strings.Join(missing, ", "), errProtectedSeamMissing)
}

var errProtectedSeamMissing = errors.New("apiserver: protected-author seam missing")

// requireAuthorStatusSeams is the same startup check for the author-status Directory a read surface filters rows with
// (F-03: SearchPosts and the timeline feeds drop rows whose author is not ACTIVE). search.WithPosts already refuses to build
// SearchPosts without it (Unimplemented, never unfiltered rows) and the feeds fail a page closed; this makes the wiring
// regression fail the deploy instead of switching search or the feeds off.
func requireAuthorStatusSeams(seams []protectedSeam) error {
	missing := nilSeams(seams)
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("author-status seams not wired: %s: %w", strings.Join(missing, ", "), errAuthorStatusSeamMissing)
}

var errAuthorStatusSeamMissing = errors.New("apiserver: author-status seam missing")

// nilSeams names every seam that is nil, typed nils included, in order.
func nilSeams(seams []protectedSeam) []string {
	var missing []string
	for _, s := range seams {
		if isNilSeam(s.value) {
			missing = append(missing, s.name)
		}
	}
	return missing
}

func isNilSeam(v any) bool {
	if v == nil {
		return true
	}
	rv := reflect.ValueOf(v)
	switch rv.Kind() {
	case reflect.Pointer, reflect.Interface, reflect.Func, reflect.Map, reflect.Slice, reflect.Chan:
		return rv.IsNil()
	}
	return false
}
