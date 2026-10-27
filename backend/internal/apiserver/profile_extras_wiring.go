// profile_extras_wiring.go binds the ADR-0024 profile extras (W3-6): the pinned-post check identity consumes from posts
// and the identity step of the post_delete job. The banner resolver lives next to the avatar one in media_wiring.go.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// latePinChecker is identity.PinChecker bound after posts is built: identity is constructed first (posts consumes
// identity.Directory), and identity needs the pin check only per UpdateProfile request. Set once at startup, before
// ListenAndServe, and never again, like lateAccountDirectory. Unset, it fails closed with an error (a 500, never a
// pin of a post nobody checked).
type latePinChecker struct{ c identity.PinChecker }

func (l *latePinChecker) CanPin(ctx context.Context, uid, postID string) (bool, error) {
	if l.c == nil {
		return false, errors.New("pin checker is not wired")
	}
	return l.c.CanPin(ctx, uid, postID)
}
