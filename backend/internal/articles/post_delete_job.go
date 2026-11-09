package articles

import (
	"context"
	"encoding/json"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// postDeleteJobKind is the shared jobs-topic kind of the post_delete job (media.JobKindPostDelete spells the same
// string; articles imports neither media nor engagement for it).
const postDeleteJobKind = "post_delete"

// postDeleteMessage is the part of the post_delete payload the articles step reads.
type postDeleteMessage struct {
	Kind   string `json:"kind"`
	UID    string `json:"uid"`
	PostID string `json:"postId"`
}

// rootRemover deletes the published article whose root post is postID and whose author is uid. It reports whether a
// record was deleted. The firestoreRepo implements it with one single-field equality query on postId (auto-indexed;
// no composite index) and a transactional re-check.
type rootRemover interface {
	deleteByRoot(ctx context.Context, uid, postID string) (bool, error)
}

// PostDeleteJobs is the articles step of the post_delete job: when an article's root post is deleted through
// posts.Delete (the post menu, not DeleteArticle), the article body would otherwise stay in the author's library as a
// published record whose post is gone. The step deletes that record, the same end state DeleteArticle reaches. It is
// never flag-gated (an article published while the feature was on must still be cleaned up when it is off).
type PostDeleteJobs struct {
	repo rootRemover
	gone PostGone
}

// NewPostDeleteJobs builds the step over Firestore and the fresh post-existence check.
func NewPostDeleteJobs(client *firestore.Client, gone PostGone) *PostDeleteJobs {
	return &PostDeleteJobs{repo: &firestoreRepo{client}, gone: gone}
}

// Handle checks the post is really gone (a job never acts on a message's word alone), then deletes the author's
// published article rooted at it: outcome "article_deleted", or "noop" when there is none (most posts, and every
// replay). A message for a post that still exists is "refused". A malformed message is acknowledged and dropped. A
// Firestore error nacks so Pub/Sub redelivers; the step is idempotent.
func (j *PostDeleteJobs) Handle(ctx context.Context, data []byte) (string, error) {
	var m postDeleteMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return "dropped:malformed_message", nil
	}
	if m.Kind != postDeleteJobKind || !ids.ValidUID(m.UID) || !ids.ValidPostID(m.PostID) {
		return "dropped:invalid_message", nil
	}
	gone, err := j.gone.PostGone(ctx, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("articles: post_delete: check post: %w", err), m.UID)
	}
	if !gone {
		return "refused", nil
	}
	deleted, err := j.repo.deleteByRoot(ctx, m.UID, m.PostID)
	if err != nil {
		return "", logger.RedactErr(fmt.Errorf("articles: post_delete: delete article: %w", err), m.UID)
	}
	if !deleted {
		return "noop", nil
	}
	return "article_deleted", nil
}

// deleteByRoot implements rootRemover. At most one article roots a post; Limit 2 bounds the read even if a corrupt
// second row existed, and every match is re-checked (author, published, root) inside the transaction.
func (r *firestoreRepo) deleteByRoot(ctx context.Context, uid, postID string) (bool, error) {
	deleted := false
	err := r.client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		deleted = false
		q := r.client.Collection("articles").Where("postId", "==", postID).Limit(2)
		docs, err := tx.Documents(q).GetAll()
		if err != nil {
			return err
		}
		b := store.NewFirestoreTxBatch(tx)
		for _, d := range docs {
			var a record
			if err = d.DataTo(&a); err != nil {
				return err
			}
			if a.AuthorID != uid || !a.Published || a.PostID != postID {
				continue
			}
			b.Delete(d.Ref)
			deleted = true
		}
		return b.Err()
	})
	return deleted, err
}
