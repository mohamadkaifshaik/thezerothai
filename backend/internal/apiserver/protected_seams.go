package apiserver

import (
	"errors"
	"fmt"
	"reflect"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// buildOption changes how build wires the handler. Only tests pass one; Build passes none.
type buildOption func(*buildOpts)

type buildOpts struct {
	// audienceSource maps the posts service to the one posts.AudienceOf reads for the engagement lists. A test returns
	// a wrapper that hides the concrete type, to prove Build refuses to start without the seam (W3-36 L-5).
	audienceSource func(posts.Service) posts.Service
}

// protectedSeam is one place the ADR-0025 protected-author set (or the Audience built on it) is wired into a module.
// Every module treats a nil seam as "nobody is protected" (by design for unit tests), so a wiring regression would
// fail open silently; Build checks them all at startup instead (W3-36 L-5, W3-40a).
type protectedSeam struct {
	name  string
	value any
}

// requireProtectedSeams returns an error naming every seam that is nil (including a typed nil), or nil when all eight
// are wired. It runs before ListenAndServe, so a refactor that drops one fails the deploy, not a user's privacy.
func requireProtectedSeams(seams []protectedSeam) error {
	var missing []string
	for _, s := range seams {
		if isNilSeam(s.value) {
			missing = append(missing, s.name)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	return fmt.Errorf("protected-author seams not wired (would fail open): %s: %w", strings.Join(missing, ", "), errProtectedSeamMissing)
}

var errProtectedSeamMissing = errors.New("apiserver: protected-author seam missing")

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
