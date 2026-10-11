// snapshot.go implements the posts side of the profile-snapshot-refresh job (P2, ADR-0003 "Author snapshot
// refresh"): rewrite `author` (and snapshotVersion) on an author's newest posts after a profile edit.
package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// SnapshotRefreshLimit is how many of an author's newest posts one refresh covers (ADR-0003). It is also the
// batch bound: one atomic batch, far below Firestore's 500 writes.
const SnapshotRefreshLimit = 100

// refreshAttempts bounds the re-query after a post was deleted between the query and the commit (an Update's
// implicit exists precondition fails the whole batch).
const refreshAttempts = 3

// RefreshAuthor rewrites `author` and `snapshotVersion` on uid's newest SnapshotRefreshLimit posts (replies
// included) whose snapshotVersion is below version, and returns how many it rewrote. Replay-safe: documents
// already at or above version are skipped, so a replay writes nothing. Only the two fields are updated (field
// paths, never a whole-document write), so concurrent counter increments are not clobbered.
//
// Firestore: reads one per post returned (<= 100; an author with no posts costs 1), writes one per stale post
// (<= 100, one batch). It uses the existing (authorId, createdAt DESC) index (Q-E, purge.go).
//
// userId, handle, displayName, avatarUrl and verified are written exactly as AuthorSnapshot carries them.
func (r *FirestoreRepo) RefreshAuthor(ctx context.Context, uid string, author AuthorSnapshot, version int64) (int, error) {
	author.UserID = uid
	for attempt := 0; attempt < refreshAttempts; attempt++ {
		docs, err := r.authorQuery(uid).Select("snapshotVersion").Limit(SnapshotRefreshLimit).Documents(ctx).GetAll()
		reads := int64(len(docs))
		if reads == 0 {
			reads = 1
		}
		budget.FromContext(ctx).AddReads(reads)
		if err != nil {
			return 0, fmt.Errorf("posts: refresh author %s: query: %w", logger.HashUID(uid), err)
		}
		b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
		stale := 0
		for _, d := range docs {
			var cur struct {
				SnapshotVersion int64 `firestore:"snapshotVersion"`
			}
			if err := d.DataTo(&cur); err != nil {
				return 0, fmt.Errorf("posts: refresh author %s: decode: %w", logger.HashUID(uid), err)
			}
			if cur.SnapshotVersion >= version {
				continue
			}
			b.Update(d.Ref, []firestore.Update{
				{Path: "author", Value: authorDoc(author)},
				{Path: "snapshotVersion", Value: version},
			})
			stale++
		}
		if stale == 0 {
			return 0, nil
		}
		if err := b.Commit(ctx); err != nil {
			if isNotFound(err) {
				continue // a post vanished under the batch: re-query without it
			}
			return 0, fmt.Errorf("posts: refresh author %s: %w", logger.HashUID(uid), err)
		}
		// The instance caches (posts, author-recent) are not evicted: they expire within CACHE_TTL (<= 60 s),
		// which is the staleness bound the slice promises.
		return stale, nil
	}
	return 0, errors.New("posts: refresh author: posts kept disappearing under the batch")
}

// isNotFound reports a gRPC NotFound anywhere in err's chain.
func isNotFound(err error) bool {
	for e := err; e != nil; e = errors.Unwrap(e) {
		if status.Code(e) == codes.NotFound {
			return true
		}
	}
	return false
}
