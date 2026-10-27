package identity

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// postDeleteJobKind is the shared jobs-topic kind of the post_delete job (media.JobKindPostDelete and
// engagement.JobKindPostDelete spell the same string; identity imports neither).
const postDeleteJobKind = "post_delete"

// pinJobMessage is the part of the post_delete payload the identity step reads.
type pinJobMessage struct {
	Kind   string `json:"kind"`
	UID    string `json:"uid"`
	PostID string `json:"postId"`
}

// PostGone reports, from a fresh read that bypasses every cache, whether the post no longer exists (1 read). It is the
// same shape as media.PostGone and engagement.PostGone; apiserver's postGone adapter over the posts repo implements all
// three, so a job never acts on a message's word alone (the JobHandler contract).
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}

// PinJobs is the identity step of the post_delete job (ADR-0024 D3): when the deleted post is the author's pinned
// post, the pin is cleared. apiserver runs it next to the media and engagement steps on the same message. It is
// never flag-gated (a pin set while profile_extras was on must still be cleaned up when the flag is off), and a
// takedown does not run it (a restore brings the pin back).
type PinJobs struct {
	pins   Pins
	gone   PostGone
	forget func(uids ...string)
}

// NewPinJobs builds the step over the Pins seam (*FirestoreRepo) and the fresh post-existence check. forget, when not nil,
// evicts a uid from this instance's profile cache after a pin was cleared (Directory.Forget, 0 reads), so the instance
// that ran the job stops showing the pin at once; other instances keep it for at most CACHE_TTL.
func NewPinJobs(p Pins, gone PostGone, forget func(uids ...string)) *PinJobs {
	return &PinJobs{pins: p, gone: gone, forget: forget}
}

// Handle implements JobHandler. Reads: 2 per message (the post, fresh; then users/{uid}, fresh, in the transaction),
// writes: 1 only when the stored pin is exactly this post (outcome "pin_cleared"), otherwise 0 ("noop"). A message
// for a post that still exists is "refused" (nothing read or written beyond the existence check). The step can never
// unpin anything but that exact post id. A malformed message is acknowledged and dropped (the DLQ, not a retry storm,
// holds poison); a Firestore error nacks so Pub/Sub redelivers, and the step is idempotent. The profile cache of
// other instances keeps showing the pin for at most CACHE_TTL; clients hide the row when GetPost answers NOT_FOUND.
func (j *PinJobs) Handle(ctx context.Context, data []byte) (string, error) {
	var m pinJobMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if m.Kind != postDeleteJobKind || !ids.ValidUID(m.UID) || !ids.ValidPostID(m.PostID) {
		return "dropped:invalid_message", nil
	}
	gone, err := j.gone.PostGone(ctx, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("identity: post_delete: check post: %w", err), m.UID)
	}
	if !gone {
		return "refused", nil // the post still exists: a message never unpins a live post
	}
	cleared, err := j.pins.ClearIfPinned(ctx, m.UID, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("identity: post_delete: clear pin: %w", err), m.UID)
	}
	if !cleared {
		return "noop", nil
	}
	if j.forget != nil {
		j.forget(m.UID)
	}
	return "pin_cleared", nil
}

var _ JobHandler = (*PinJobs)(nil)
