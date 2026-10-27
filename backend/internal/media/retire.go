// retire.go is the `profile_media_retired` job (ADR-0024 Amendment 1 A4): when a profile's avatar or banner is replaced
// or removed, the old image's public objects (full and thumbnail) are scheduled for deletion after a grace of at least
// 24 h. It rides the shared `jobs` Pub/Sub topic like `post_delete` (no new topic, Scheduler job, collection or index):
// identity.Lifecycle routes messages of this kind to RetireHandler.
//
// Publish: after an UpdateProfile commit that changed or cleared an image, identity calls ProfileImageReplaced (through
// identity.MediaRetirer) with the old URLs it already read, so the request path costs 0 extra reads.
//
// Handle (Retire): the message is never trusted on its own word, so the step re-reads. In order, cheapest refusal first:
//
//	validate the message                         dropped:invalid_message   0 reads
//	PROFILE_MEDIA_RETIRE does not allow it       disabled                  0 reads
//	parse the media id from the object names     unparseable               0 reads
//	users/{uid}, fresh: old image still current  still_current             1 read
//	media/{id}: missing or already retired       duplicate                 2 reads
//	            not this owner, purpose, or published   refused            2 reads
//	customTime = changedAt on both objects (objects first), then
//	media/{id}.retiredAt + expireAt (document last, LastUpdateTime precondition)    retired   2 reads, 1 write, 2 Class A
//
// A crash between the two last steps leaves tagged objects and an unretired document; the redelivery repeats the tag
// (same value, accepted by Cloud Storage) and writes the document, so it converges. A redelivery after completion finds
// retiredAt and does nothing: 0 writes, no GCS call. The objects are deleted by the media bucket's lifecycle rule
// (delete when daysSinceCustomTime >= 1, infra/terraform/modules/media-buckets) 24-48 h after changedAt, and nothing
// else in the application ever sets customTime (TestCustomTimeIsSetOnlyByTheRetireStep). Until the document's own TTL
// (changedAt + RetiredDocTTL) removes it, it keeps the image inside the account eraser and the export.
package media

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// JobKindProfileMediaRetired is the JobMessage.Kind of this job.
const JobKindProfileMediaRetired = "profile_media_retired"

// RetiredDocTTL is how long a retired media document lives after retiredAt (its expireAt, the TTL field the PENDING
// path already uses). It is longer than the deletion lag of the lifecycle rule (24-48 h), so the objects are gone first.
const RetiredDocTTL = 72 * time.Hour

// maxImageURLLen bounds a URL in a message; a real one is about 100 characters.
const maxImageURLLen = 512

// RetireMessage is the payload of a profile_media_retired job. Purpose is the stored purpose name ("AVATAR" or
// "BANNER"). The URLs are the old users/{uid} values; the thumbnail may be empty. ChangedAt is the commit time of the
// profile change, the start of the grace.
type RetireMessage struct {
	Kind        string    `json:"kind"`
	UID         string    `json:"uid"`
	Purpose     string    `json:"purpose"`
	OldURL      string    `json:"oldUrl"`
	OldThumbURL string    `json:"oldThumbUrl,omitempty"`
	ChangedAt   time.Time `json:"changedAt"`
}

// PublicTagger sets customTime on an object of the public bucket (1 Class A each; a missing object is success).
// *Buckets implements it. It is a seam of its own so that opsctl and the tests need no upload bucket.
type PublicTagger interface {
	SetPublicCustomTime(ctx context.Context, object string, t time.Time) error
}

// ProfileImages reports, from a fresh read that bypasses every cache, the image URLs users/{uid} holds right now: the
// avatar, its thumbnail, the banner and its thumbnail, empty ones omitted (1 read). found is false when the document
// does not exist. *identity.FirestoreRepo implements it (a job never acts on a message's word alone).
type ProfileImages interface {
	ProfileImageURLs(ctx context.Context, uid string) (urls []string, found bool, err error)
}

// RetireDeps is what the retire step needs on top of the post_delete job's. Mode is PROFILE_MEDIA_RETIRE; its zero value
// is off, so a Jobs built without the step deletes nothing. Now nil means time.Now.
type RetireDeps struct {
	Mode   config.ProfileMediaRetire
	Users  ProfileImages
	Tagger PublicTagger
	Now    func() time.Time
}

// WithProfileRetire enables the profile_media_retired step on j and returns it.
func (j *Jobs) WithProfileRetire(d RetireDeps) *Jobs {
	if d.Now == nil {
		d.Now = time.Now
	}
	j.retire = d
	return j
}

// ProfileImageReplaced publishes the retire job for an avatar or banner that was replaced or removed. It is called after
// the profile change committed, with the old URLs identity already read; 0 reads. PROFILE_MEDIA_RETIRE is checked first,
// in memory: a switch that does not allow the purpose publishes nothing and returns nil. An error means the image falls
// back to the account eraser (it is deleted with the account), so the caller logs it at ERROR.
func (j *Jobs) ProfileImageReplaced(ctx context.Context, uid string, purpose Purpose, oldURL, oldThumbURL string, changedAt time.Time) error {
	if !j.retire.Mode.Allows(string(purpose)) {
		return nil
	}
	if j.pub == nil {
		return errors.New("media: no job publisher configured")
	}
	data, err := json.Marshal(RetireMessage{
		Kind: JobKindProfileMediaRetired, UID: uid, Purpose: string(purpose),
		OldURL: oldURL, OldThumbURL: oldThumbURL, ChangedAt: changedAt.UTC(),
	})
	if err != nil {
		return fmt.Errorf("media: encode profile_media_retired job: %w", err)
	}
	return j.pub.Publish(ctx, data)
}

// RetireHandler is the identity.JobHandler of the profile_media_retired kind (Jobs.Handle is post_delete's).
type RetireHandler struct{ j *Jobs }

// RetireHandler returns the handler apiserver registers with identity.Lifecycle.RegisterJobHandler.
func (j *Jobs) RetireHandler() *RetireHandler { return &RetireHandler{j: j} }

// Handle decodes one delivery and runs Retire. A malformed message is acknowledged and dropped (the DLQ, not a retry
// storm, holds poison); a Firestore or GCS error nacks so Pub/Sub redelivers.
func (h *RetireHandler) Handle(ctx context.Context, data []byte) (string, error) {
	var m RetireMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if m.Kind != JobKindProfileMediaRetired {
		return "dropped:invalid_message", nil
	}
	return h.j.Retire(ctx, m)
}

// Retire is the step itself, shared by the Pub/Sub handler and `opsctl clear-profile-fields` (called in process, no
// Pub/Sub). It returns the outcome named in the file comment. Reads: 0 to 2 (users/{uid} fresh, media/{id}); writes: 1
// only for "retired" (retiredAt and expireAt, one field-level Update with a LastUpdateTime precondition); GCS: 2 Class A
// for "retired", none otherwise. A redelivery after completion is "duplicate": 0 writes, no GCS call. A changedAt in
// the future is clamped to now, because Cloud Storage never lets customTime move back and a far-future value would
// outlive the document's TTL and escape the account eraser.
func (j *Jobs) Retire(ctx context.Context, m RetireMessage) (string, error) {
	if !ids.ValidUID(m.UID) || (m.Purpose != string(PurposeAvatar) && m.Purpose != string(PurposeBanner)) ||
		m.OldURL == "" || len(m.OldURL) > maxImageURLLen || len(m.OldThumbURL) > maxImageURLLen || m.ChangedAt.IsZero() {
		return "dropped:invalid_message", nil
	}
	if !j.retire.Mode.Allows(m.Purpose) {
		return "disabled", nil
	}
	id, ok := parseRetiredImage(m.OldURL, m.OldThumbURL)
	if !ok {
		return "unparseable", nil // an object name media does not own: left to the account eraser
	}
	if j.retire.Users == nil || j.retire.Tagger == nil {
		return "", errors.New("media: profile_media_retired: the step is not wired")
	}
	// Microseconds: Firestore timestamps carry no finer precision, and the same value goes on the objects and the document.
	changedAt := m.ChangedAt.UTC().Truncate(time.Microsecond)
	if now := j.retire.Now().UTC().Truncate(time.Microsecond); changedAt.After(now) {
		changedAt = now
	}

	urls, _, err := j.retire.Users.ProfileImageURLs(ctx, m.UID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("media: profile_media_retired: read profile: %w", err), m.UID)
	}
	for _, u := range urls {
		if cur, ok := ParseImageURL(u); ok && cur.ID == id {
			return "still_current", nil // a message never retires an image the profile shows (either purpose)
		}
	}

	docs, err := j.repo.GetMany(ctx, []string{id})
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("media: profile_media_retired: load: %w", err), m.UID)
	}
	d, ok := docs[id]
	switch {
	case !ok || d.RetiredAt != nil:
		return "duplicate", nil // already retired, or gone with its account
	case d.OwnerID != m.UID || d.Purpose != m.Purpose || !d.Published():
		return "refused", nil // not this user's image of this purpose: never touched on a message's word
	}

	// Objects first, from the document's own names (never from the message's URLs), document last.
	for _, name := range publicNames(d) {
		if err := j.retire.Tagger.SetPublicCustomTime(ctx, name, changedAt); err != nil {
			return "", logger.RedactErr(fmt.Errorf("media: profile_media_retired: tag objects: %w", err), m.UID)
		}
	}
	if err := j.repo.Retire(ctx, id, d.UpdateTime, changedAt, changedAt.Add(RetiredDocTTL)); err != nil {
		// ErrConflict: the document moved since it was read (a concurrent delivery, or the eraser). Nack; the
		// redelivery decides from a fresh read.
		return "", logger.RedactErr(fmt.Errorf("media: profile_media_retired: mark retired: %w", err), m.UID)
	}
	return "retired", nil
}

// ImageObject is a public profile-image object name taken apart.
type ImageObject struct {
	// Name is the object name, "m/{id}.{ext}" or "m/{id}_t.{ext}".
	Name string
	// ID is the media id (19 digits).
	ID string
	// Ext is "jpg" or "webp" (what extension() returns).
	Ext string
	// Thumb is true for the "_t" thumbnail object.
	Thumb bool
}

var imageObjectPattern = regexp.MustCompile(`^m/([0-9]{19})(_t)?\.(jpg|webp)$`)

// ParseObjectName parses an object name of the public bucket. It is the one place that knows the names media writes
// (publicObject and publicThumbObject); any other name is not an image this module owns.
func ParseObjectName(name string) (ImageObject, bool) {
	m := imageObjectPattern.FindStringSubmatch(name)
	if m == nil {
		return ImageObject{}, false
	}
	return ImageObject{Name: name, ID: m[1], Ext: m[3], Thumb: m[2] != ""}, true
}

// ObjectNameFromURL returns the public-bucket object name ("m/<tail>") a profile image URL points at, or "" when the URL
// has no such tail. The public base URL in front of it is deployment config that media's callers (the job in another
// revision, opsctl) may not share, so it keys on the last "/m/" path segment. The name is not validated here: use
// ParseObjectName or ParseImageURL for that.
func ObjectNameFromURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	i := strings.LastIndex(u.Path, "/m/")
	if i < 0 {
		return ""
	}
	name := u.Path[i+1:]
	if len(name) <= len("m/") || strings.Contains(name[len("m/"):], "/") {
		return ""
	}
	return name
}

// ParseImageURL is ParseObjectName(ObjectNameFromURL(raw)).
func ParseImageURL(raw string) (ImageObject, bool) {
	return ParseObjectName(ObjectNameFromURL(raw))
}

// parseRetiredImage returns the media id behind a message's URLs: the full URL must name a full object, and a thumbnail
// URL, when present, a thumbnail object of the same id and extension. Anything else is unparseable.
func parseRetiredImage(oldURL, oldThumbURL string) (string, bool) {
	full, ok := ParseImageURL(oldURL)
	if !ok || full.Thumb {
		return "", false
	}
	if oldThumbURL != "" {
		th, ok := ParseImageURL(oldThumbURL)
		if !ok || !th.Thumb || th.ID != full.ID || th.Ext != full.Ext {
			return "", false
		}
	}
	return full.ID, true
}
