// privacy.go is the service side of the is_private toggle (ADR-0025 D8, W3-26a): wiring options and the glue around
// the PrivacyRepo transaction. The transaction itself is repo_privacy_firestore.go.
package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// Request-log fields (ADR-0025 W3-26a observability).
const (
	fieldPrivacyToggle         = "privacy_toggle"          // on | off | noop | quota | cap
	fieldPrivacyToggleAttempts = "privacy_toggle_attempts" // transaction attempts; the hot-doc signal (D3)
)

// privacyDeps is what WithPrivacy wires.
type privacyDeps struct {
	repo   PrivacyRepo
	set    *ProtectedSetLoader
	limits PrivacyLimits
}

// PrivacyDeps are the dependencies of the is_private toggle. Nil Repo (the default) keeps is_private=true refused as
// "coming soon" and is_private=false a plain field write, the W3-25b behaviour.
type PrivacyDeps struct {
	Repo PrivacyRepo
	// Set receives the committing instance's own toggle at once (Install on a protect, Apply on an unprotect). May be nil.
	Set    *ProtectedSetLoader
	Limits PrivacyLimits
}

// WithPrivacy wires the is_private toggle (ADR-0025 D8).
func WithPrivacy(d PrivacyDeps) Option {
	return func(s *service) {
		if d.Repo != nil {
			s.privacy = &privacyDeps{repo: d.Repo, set: d.Set, limits: d.Limits}
		}
	}
}

// privacyListener is the BecamePublic hand-over (nil = publishes nothing; apiserver wires graph.PrivacyListener since W3-28b).
type privacyListener struct {
	l   PrivacyListener
	log *slog.Logger
}

// WithPrivacyListener wires the "this account went public" hand-over (ADR-0025 AQ1). Nil publishes nothing. log receives
// the ERROR for a failed hand-over; nil means slog.Default().
func WithPrivacyListener(l PrivacyListener, log *slog.Logger) Option {
	return func(s *service) {
		if l == nil {
			return
		}
		if log == nil {
			log = slog.Default()
		}
		s.listener = &privacyListener{l: l, log: log}
	}
}

// afterPrivacyCommit runs the post-commit steps of a committed toggle: the instance's own copy of the set, then (for an
// unprotect) the detached, short-deadline BecamePublic hand-over. A failed hand-over is ERROR privacy_public_enqueue_failed
// and never fails the toggle. No Firestore access.
func (s *service) afterPrivacyCommit(ctx context.Context, uid string, up PrivacyUpdate, at time.Time) {
	switch up.Toggle {
	case PrivacyOn:
		logger.SetRequestField(ctx, fieldPrivacyToggle, "on")
		if s.privacy.set != nil {
			s.privacy.set.Install(up.SetUIDs, at)
		}
	case PrivacyOff:
		logger.SetRequestField(ctx, fieldPrivacyToggle, "off")
		if s.privacy.set != nil {
			s.privacy.set.Apply(uid, false)
		}
		if s.listener != nil {
			pctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), publishTimeout)
			err := s.listener.l.BecamePublic(pctx, uid, at)
			cancel()
			if err != nil {
				mw.ReportError(ctx, s.listener.log, "privacy_public_enqueue_failed",
					logger.RedactErr(fmt.Errorf("privacy_public_enqueue_failed: %w", err), uid))
			}
		}
	default:
		logger.SetRequestField(ctx, fieldPrivacyToggle, "noop")
	}
}

// privacyRefusal turns the toggle transaction's refusals into their wire answers and records privacy_toggle. It returns
// nil when err is not one of them.
func privacyRefusal(ctx context.Context, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrProtectedSetFull):
		logger.SetRequestField(ctx, fieldPrivacyToggle, "cap")
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "private accounts are at capacity").
			WithMeta("limit", "private_accounts")
	case errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED:
		logger.SetRequestField(ctx, fieldPrivacyToggle, "quota")
		return err
	}
	return nil
}
