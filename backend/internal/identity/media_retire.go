// media_retire.go is the identity side of the profile_media_retired job (ADR-0024 Amendment 1 A4): when an UpdateProfile
// commit replaces or removes the avatar or the banner, the old image's public objects are scheduled for deletion after a
// grace. identity only says "this image was replaced"; the media module (behind MediaRetirer, the BannerResolver
// pattern) owns the object names, the switch PROFILE_MEDIA_RETIRE and the job.
package identity

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

// ProfileImage names which of a profile's two images a MediaRetirer call is about. The values are the media purposes.
type ProfileImage string

const (
	ProfileImageAvatar ProfileImage = "AVATAR"
	ProfileImageBanner ProfileImage = "BANNER"
)

// MediaRetirer is the consumer-side seam to the media module (ADR-0002; apiserver adapts media.Jobs). RetireProfileImage
// hands over an image that an UpdateProfile commit replaced or removed: oldURL and oldThumbURL are the values the profile
// held (the thumbnail URL may be empty) and changedAt is the commit time. It runs after the commit, costs identity 0
// extra reads (the old values come from the document the transaction already read), and is best effort: an error means
// the image is deleted with the account instead (the old behaviour), and the caller logs it at ERROR. Whether anything
// happens at all is the media module's PROFILE_MEDIA_RETIRE switch, checked there.
type MediaRetirer interface {
	RetireProfileImage(ctx context.Context, uid string, image ProfileImage, oldURL, oldThumbURL string, changedAt time.Time) error
}

// retiredImage is an old image UpdateProfile's transaction found replaced or removed.
type retiredImage struct {
	image    ProfileImage
	url      string
	thumbURL string
}

// retiredImages returns the avatar and banner that differ between the profile as read (before) and as it will be written
// (after), when the profile held one before: a replace or a removal. A first-time set (nothing before) and an unchanged
// image return nothing. Pure: no reads.
func retiredImages(before, after Profile) []retiredImage {
	var out []retiredImage
	add := func(img ProfileImage, oldURL, oldThumb, newURL, newThumb string) {
		if (oldURL != "" || oldThumb != "") && (oldURL != newURL || oldThumb != newThumb) {
			out = append(out, retiredImage{image: img, url: oldURL, thumbURL: oldThumb})
		}
	}
	add(ProfileImageAvatar, before.AvatarURL, before.AvatarThumbURL, after.AvatarURL, after.AvatarThumbURL)
	add(ProfileImageBanner, before.BannerURL, before.BannerThumbURL, after.BannerURL, after.BannerThumbURL)
	return out
}

// mediaRetire is the wired MediaRetirer and the logger its failures go to.
type mediaRetire struct {
	r   MediaRetirer
	log *slog.Logger
}

// WithMediaRetirer wires the retire step (ADR-0024 Amendment 1 A4). Nil keeps UpdateProfile publishing nothing, which is
// the pre-A4 behaviour (an image is deleted with the account). log receives the ERROR for a failed hand-over; nil means
// slog.Default().
func WithMediaRetirer(r MediaRetirer, log *slog.Logger) Option {
	return func(s *service) {
		if r == nil {
			return
		}
		if log == nil {
			log = slog.Default()
		}
		s.retire = &mediaRetire{r: r, log: log}
	}
}

// retireImages hands each replaced or removed image to the MediaRetirer after the profile commit. Best effort: a failure
// is reported at ERROR (Error Reporting, uid scrubbed) and never reaches the caller. The call runs under a short
// deadline of its own, detached from the request's cancellation like the snapshot enqueue, so a client that hangs up
// right after the commit does not turn a delete-after-grace into delete-with-account.
func (s *service) retireImages(ctx context.Context, uid string, imgs []retiredImage, at time.Time) {
	if s.retire == nil {
		return
	}
	for _, im := range imgs {
		pctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), publishTimeout)
		err := s.retire.r.RetireProfileImage(pctx, uid, im.image, im.url, im.thumbURL, at)
		cancel()
		if err != nil {
			mw.ReportError(ctx, s.retire.log.With("image", string(im.image)), "profile_media_retire_enqueue_failed",
				logger.RedactErr(fmt.Errorf("profile_media_retire_enqueue_failed: %w", err), uid))
		}
	}
}
