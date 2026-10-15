// jobs.go is the engagement half of the `post_delete` job (ADR-0018 D6, D10, D11). The message is the media
// job's (kind, uid, postId, mediaIds): apiserver runs both handlers on it and acknowledges only when both do.
//
// The job never acts on a message's word alone (the IAM control C1 pattern): ids are validated and the post must
// really be gone (a fresh read, not an instance cache). It only touches collections keyed by the post id.
// Everything is idempotent and resumable: handled documents leave the queries, so a redelivery, a crash or a
// second concurrent delivery converges on the same end state.
//
// Work is done in pages with a bounded number of pages per delivery. A post with thousands of likes republishes
// the same message and acknowledges instead of nacking, so it can never exhaust the subscription's
// maxDeliveryAttempts (D11).
package engagement

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// JobKindPostDelete is the shared jobs-topic kind (media.JobKindPostDelete; engagement does not import media).
const JobKindPostDelete = "post_delete"

const (
	// jobPage is the page size of the job's queries (an ops path, ADR-0003 purge rule).
	jobPage = 100
	// jobMaxPages bounds the pages of all kinds one delivery processes before it republishes (D11).
	jobMaxPages = 10
)

// postDeleteMessage is the part of the media job's payload this job reads. Its own mediaIds are not used here.
type postDeleteMessage struct {
	Kind   string `json:"kind"`
	UID    string `json:"uid"`
	PostID string `json:"postId"`
}

// PostGone reports, from a fresh read, whether the post no longer exists (1 read). Implemented by an apiserver
// adapter over the posts repo; it is the same shape media.PostGone has.
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}

// JobPublisher publishes one message to the shared jobs topic (*pubsubpublish.Publisher).
type JobPublisher interface {
	Publish(ctx context.Context, data []byte) error
}

// Jobs handles post_delete messages for engagement.
type Jobs struct {
	repo    *FirestoreRepo
	cleanup posts.Cleanup
	posts   PostGone
	pub     JobPublisher
}

// NewJobs builds the job. pub may be nil in tests that never exceed one delivery's page budget.
func NewJobs(repo *FirestoreRepo, cleanup posts.Cleanup, gone PostGone, pub JobPublisher) *Jobs {
	return &Jobs{repo: repo, cleanup: cleanup, posts: gone, pub: pub}
}

// Handle implements identity.JobHandler. Reads: 1 (the post) + 1 per query page (an empty query bills 1): 4 for a
// post with no dependants. Writes: 0; deletes: likes (1 each) and reposts (2 each), REPOST reposter postsCount
// -1 and quote tombstones as writes.
func (j *Jobs) Handle(ctx context.Context, data []byte) (string, error) {
	var m postDeleteMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if m.Kind != JobKindPostDelete || !ids.ValidUID(m.UID) || !ids.ValidPostID(m.PostID) {
		return "dropped:invalid_message", nil
	}
	gone, err := j.posts.PostGone(ctx, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("engagement: post_delete: check post: %w", err), m.UID)
	}
	if !gone {
		return "refused", nil // the post still exists: a message never makes a live post's dependants deletable
	}

	steps := []struct {
		name string
		run  func() (n int, full bool, err error)
	}{
		// Likes: delete the docs; the counter died with the post.
		{"likes", func() (int, bool, error) {
			return j.repo.deleteLikesOf(ctx, m.PostID, jobPage)
		}},
		// Reposts: REPOST posts, their reposts docs and the reposters' postsCount.
		{"reposts", func() (int, bool, error) {
			return j.cleanup.RemoveReposts(ctx, m.PostID, false, jobPage)
		}},
		// Quotes: replace the embeds with a tombstone.
		{"quotes", func() (int, bool, error) {
			return j.cleanup.TombstoneQuotes(ctx, m.PostID, jobPage)
		}},
	}
	pages, more := 0, false
steps:
	for _, st := range steps {
		for {
			if pages >= jobMaxPages {
				more = true
				break steps
			}
			n, full, err := st.run()
			if err != nil {
				return "", logger.RedactErr(fmt.Errorf("engagement: post_delete: %s: %w", st.name, err), m.UID)
			}
			pages++
			if !full {
				break
			}
			// A full page that removed nothing would repeat (and re-publish) forever; stop the step and let
			// the residue sweep and the runbook name what is left.
			if n == 0 {
				slog.ErrorContext(ctx, "engagement_post_delete_no_progress", "step", st.name)
				break
			}
		}
	}
	if more {
		// A full page was the last one this delivery had budget for: hand the rest to a fresh delivery.
		if j.pub == nil {
			return "", errors.New("engagement: post_delete: more pages and no publisher")
		}
		if err := j.pub.Publish(ctx, data); err != nil {
			return "", logger.RedactErr(fmt.Errorf("engagement: post_delete: republish: %w", err), m.UID)
		}
		slog.InfoContext(ctx, "engagement_post_delete_continued")
		return "continued", nil
	}
	return "done", nil
}

// deleteLikesOf deletes up to limit like docs of postID (Q-L: likes where postId == X LIMIT n, automatic index).
// full reports whether the page was full (more may remain). Blind deletes in one batch; reads len(page), minimum 1.
func (r *FirestoreRepo) deleteLikesOf(ctx context.Context, postID string, limit int) (n int, full bool, err error) {
	docs, err := r.client.Collection(likesCollection).Where("postId", "==", postID).Limit(limit).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return 0, false, fmt.Errorf("engagement: likes query: %w", err)
	}
	if len(docs) == 0 {
		return 0, false, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, false, fmt.Errorf("engagement: delete likes: %w", err)
	}
	return len(docs), len(docs) >= limit, nil
}
