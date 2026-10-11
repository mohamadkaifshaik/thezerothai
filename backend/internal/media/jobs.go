// jobs.go is the `post_delete` job (P4, ADR-0005 "Deletes"): when a post that carried images is deleted, its public
// objects and media documents are removed. It rides the shared `jobs` Pub/Sub topic (ADR-0011 D-A, no new topic):
// identity.Lifecycle routes messages of this kind to Jobs.Handle.
//
// The job never acts on a message's word alone (the IAM control C1 pattern): it re-reads each media document and
// requires that it belongs to the message's uid and is attached to the message's post, and that the post really
// is gone (a fresh read, not the instance cache). Every step is idempotent and ordered objects first, document
// last, so a redelivery, a crash or a second concurrent delivery converges on the same end state.
package media

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// JobKindPostDelete is the JobMessage.Kind of this job.
const JobKindPostDelete = "post_delete"

var postIDPattern = regexp.MustCompile(`^[0-9]{19}$`)

// PostDeleteMessage is the payload of a post_delete job.
type PostDeleteMessage struct {
	Kind     string   `json:"kind"`
	UID      string   `json:"uid"`
	PostID   string   `json:"postId"`
	MediaIDs []string `json:"mediaIds"`
}

// JobPublisher publishes one message to the shared `jobs` topic. *pubsubpublish.Publisher implements it.
type JobPublisher interface {
	Publish(ctx context.Context, data []byte) error
}

// PostGone reports, from a fresh read, whether the post no longer exists. Implemented by a consumer-side adapter
// in apiserver over the posts repo (1 read).
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}

// Jobs publishes and handles post_delete jobs.
type Jobs struct {
	repo    Repo
	objects Objects
	posts   PostGone
	pub     JobPublisher
}

// NewJobs builds the job side. pub may be nil in tests that only exercise Handle.
func NewJobs(repo Repo, objects Objects, posts PostGone, pub JobPublisher) *Jobs {
	return &Jobs{repo: repo, objects: objects, posts: posts, pub: pub}
}

// PostDeleted publishes the cleanup job for a deleted post that carried images (posts.MediaJobs). It is called
// after the post's delete committed; an error means the objects will linger until the account is deleted, so
// the caller logs it at ERROR.
func (j *Jobs) PostDeleted(ctx context.Context, uid, postID string, mediaIDs []string) error {
	if j.pub == nil {
		return errors.New("media: no job publisher configured")
	}
	data, err := json.Marshal(PostDeleteMessage{Kind: JobKindPostDelete, UID: uid, PostID: postID, MediaIDs: mediaIDs})
	if err != nil {
		return fmt.Errorf("media: encode post_delete job: %w", err)
	}
	return j.pub.Publish(ctx, data)
}

// Handle implements identity.JobHandler. Reads: len(MediaIDs) + 1 (the post); deletes: len(MediaIDs) documents;
// GCS: free deletes, 4 per image.
func (j *Jobs) Handle(ctx context.Context, data []byte) (string, error) {
	var m PostDeleteMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if !ids.ValidUID(m.UID) || !postIDPattern.MatchString(m.PostID) || len(m.MediaIDs) == 0 || len(m.MediaIDs) > MaxPerPost {
		return "dropped:invalid_message", nil
	}
	seen := make(map[string]struct{}, len(m.MediaIDs))
	for _, id := range m.MediaIDs {
		if !mediaIDPattern.MatchString(id) {
			return "dropped:invalid_message", nil
		}
		if _, dup := seen[id]; dup {
			return "dropped:invalid_message", nil
		}
		seen[id] = struct{}{}
	}

	gone, err := j.posts.PostGone(ctx, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("media: post_delete: check post: %w", err), m.UID)
	}
	if !gone {
		return "refused", nil // the post still exists: a message never makes a live post's images deletable
	}
	docs, err := j.repo.GetMany(ctx, m.MediaIDs)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("media: post_delete: load: %w", err), m.UID)
	}
	var toDelete []string
	for _, id := range m.MediaIDs {
		d, ok := docs[id]
		if !ok {
			continue // already cleaned up: idempotent
		}
		if d.OwnerID != m.UID || d.PostID != m.PostID {
			continue // not this post's image: never delete it on a message's word
		}
		if err := deleteObjects(ctx, j.objects, d); err != nil {
			return "", logger.RedactErr(fmt.Errorf("media: post_delete: objects: %w", err), m.UID)
		}
		toDelete = append(toDelete, id)
	}
	if err := j.repo.DeleteDocs(ctx, toDelete); err != nil {
		return "", logger.RedactErr(fmt.Errorf("media: post_delete: docs: %w", err), m.UID)
	}
	if len(toDelete) == 0 {
		return "duplicate", nil
	}
	return "done", nil
}
