package media

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// The Vision attempt cap and the per-uid Vision-units cap (W6-40, ADR-0029 Amendment 1 A5; revises W6-27, security H-3).
//
// Counters on the media doc, at +0 writes (A5.4):
//   - screenAttempts counts CLAIMS. ClaimScreening increments it before any Vision call, so a lost release write or a dead instance cannot
//     escape the ceiling MEDIA_MAX_SCREEN_ATTEMPTS + MEDIA_MAX_SCREEN_RETRIES.
//   - screenAssessed counts the claims that produced a valid assessment and did not end the document. ReleaseScreening increments it in the
//     release write it already makes.
//   - Retries = screenAttempts - screenAssessed.
//
// The per-doc worst case is therefore 8 claims x 2 units = 16 billable units (#535: 3 x 2 = 6).

const (
	// defaultScreenRetries is MEDIA_MAX_SCREEN_RETRIES.
	defaultScreenRetries = 5
	// defaultVisionUnitsPerDay and defaultVisionUnitsPerDayNewAccount are the per-instance media_vision_units_daily limits.
	defaultVisionUnitsPerDay           = 60
	defaultVisionUnitsPerDayNewAccount = 12
	// limitVisionUnitsDaily is the limit_name / metadata["limit"] of a refusal by the per-uid Vision-units cap.
	limitVisionUnitsDaily = "media_vision_units_daily"
	// screeningRetryAfter is the retry_after of the screening UNAVAILABLE; the client retries the same FinalizeUpload after it.
	screeningRetryAfter = 5 * time.Second
)

// maxScreenRetries is MEDIA_MAX_SCREEN_RETRIES (default 5; 0 is a valid setting).
func (s *service) maxScreenRetries() int {
	if s.MediaMaxScreenRetries != nil && *s.MediaMaxScreenRetries >= 0 {
		return *s.MediaMaxScreenRetries
	}
	return defaultScreenRetries
}

// attemptsExhausted is the step 0b pre-check (A5.4). It reports which counter is spent: "assessed" when the doc used all its
// attempts with a valid assessment, "claims" when it reached the claims ceiling, "" when it may still be screened.
func (s *service) attemptsExhausted(d *Doc) string {
	switch {
	case d.ScreenAssessed >= int64(s.maxScreenAttempts()):
		return "assessed"
	case d.ScreenAttempts >= int64(s.maxScreenAttempts()+s.maxScreenRetries()):
		return "claims"
	}
	return ""
}

// screenUnits is the Vision units one screening of d bills when every call is made: 1, or 2 with the thumbnail.
func (s *service) screenUnits(d *Doc) int64 {
	if s.screensThumb(d) {
		return 2
	}
	return 1
}

// chargeUnits counts units against uid's media_vision_units_daily cap before anything is claimed or sent (A5.5). The tier follows the account's
// age (the same new-account window as the upload quota). A refusal is RATE_LIMITED, retry_after to IST midnight, and writes nothing. If the
// account's age cannot be read the stricter new-account tier applies, so a directory outage never widens the cap.
func (s *service) chargeUnits(ctx context.Context, uid string, units int64) (*ratelimit.DailyCap, error) {
	c := s.unitsCap
	if s.isNewAccount(ctx, uid) {
		c = s.unitsCapNew
	}
	if c.AllowN(uid, units) {
		return c, nil
	}
	logger.SetRequestField(ctx, fieldUnitsRefused, true)
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.LimitName = limitVisionUnitsDaily
	}
	return nil, apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "too many image checks today, please try again tomorrow").
		WithMeta("limit", limitVisionUnitsDaily).WithRetryAfter(quota.UntilNextDay(s.Now()))
}

// isNewAccount reports whether uid is inside the new-account window. The age comes cache-first from the profile the account-status interceptor
// already read (identity.Directory), so it adds no read. An error or an unknown age counts as new (the stricter tier).
func (s *service) isNewAccount(ctx context.Context, uid string) bool {
	created, err := s.Directory.AccountCreatedAt(ctx, uid)
	if err != nil || created.IsZero() {
		return true
	}
	return s.Now().Sub(created) < s.NewAccountWindow
}

// screeningUnavailable is the retryable "image checks are temporarily unavailable" answer, with retry_after (A5.6).
func screeningUnavailable(cause error) error {
	return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
		"image checks are temporarily unavailable, please try again").WithCause(cause).WithRetryAfter(screeningRetryAfter)
}

// neverSent reports whether a failed Vision call can have been billed: a context error (our deadline, or the client hanging up while the call
// was in flight) may have been, so it is never refunded to the per-uid cap; any other failure before a response was not.
func neverSent(err error) bool {
	return err != nil && !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled)
}
