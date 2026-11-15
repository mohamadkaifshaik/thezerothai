// repo_top_posts.go is the top-posts read of F2 Creator Studio insights (identity's GetCreatorInsights, through the
// consumer-side identity.TopPostsReader wired in apiserver):
//
//	Q-TP posts where authorId == uid ORDER BY viewCount DESC LIMIT n
//	     -> composite index (authorId ASC, viewCount DESC) in firebase/firestore.indexes.json: until it is READY
//	        Firestore answers FAILED_PRECONDITION, which is ErrTopPostsIndexMissing, and the RPC answers with no top
//	        posts.
//
// Lifetime viewCount, not views gained in a window (that needs per-post daily deltas; v1 design 2026-11-15). Posts
// without a viewCount field (never rolled up) are not returned by the ordering at all.
package posts

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TopPostsMax bounds TopPostsByViews.
const TopPostsMax = 5

// ErrTopPostsIndexMissing is Q-TP's FAILED_PRECONDITION: the composite index is not deployed.
var ErrTopPostsIndexMissing = errors.New("posts: top posts index missing")

// TopPostsByViews returns up to limit (at most TopPostsMax) of uid's visible, non-REPOST posts with at least one view,
// most viewed first. One query with Limit(limit), so a hidden post among the top rows leaves the list shorter.
func (r *FirestoreRepo) TopPostsByViews(ctx context.Context, uid string, limit int) ([]*Post, error) {
	limit = min(max(limit, 1), TopPostsMax)
	docs, err := r.client.Collection(postsCollection).Where("authorId", "==", uid).
		OrderBy("viewCount", firestore.Desc).Limit(limit).Documents(ctx).GetAll()
	if status.Code(err) == codes.FailedPrecondition {
		return nil, ErrTopPostsIndexMissing
	}
	if err != nil {
		return nil, fmt.Errorf("posts: top posts %s: %w", logger.HashUID(uid), err)
	}
	return topPostsOf(docsToPosts(docs), limit), nil
}

// docsToPosts decodes query rows, skipping a row that does not decode (it is never shown).
func docsToPosts(docs []*firestore.DocumentSnapshot) []*Post {
	out := make([]*Post, 0, len(docs))
	for _, s := range docs {
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			continue
		}
		out = append(out, d.toPost(s.Ref.ID))
	}
	return out
}

// topPostsOf keeps the visible, non-REPOST posts with views, in order, at most limit. Pure.
func topPostsOf(ps []*Post, limit int) []*Post {
	out := make([]*Post, 0, limit)
	for _, p := range ps {
		if len(out) == limit {
			break
		}
		if p.Kind == KindRepost || !p.Visible() || p.ViewCount <= 0 {
			continue
		}
		out = append(out, p)
	}
	return out
}
