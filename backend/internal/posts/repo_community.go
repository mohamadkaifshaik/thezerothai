package posts

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// ByCommunity implements Repo: `posts where communityId == cid ORDER BY __name__ DESC LIMIT n` with the window as document-id bounds
// (forms 1 to 3 and the settle sentinel). It never goes through run(): run() orders by createdAt, which needs a composite
// index the community feed does not have. The equality plus a __name__ order is served by the automatic single-field index (checked on
// dzeroth-dev, 2026-11-01). No isReply filter: communityId is written only on root posts and quotes, and an added filter would leave the
// proven shapes. Reads: len(result), minimum 1.
func (r *FirestoreRepo) ByCommunity(ctx context.Context, cid string, w Window, limit int) ([]*Post, error) {
	q := r.client.Collection(postsCollection).Where("communityId", "==", cid).OrderBy(firestore.DocumentID, firestore.Desc)
	b := communityBoundsOf(w)
	if b.startAfter != "" {
		q = q.StartAfter(r.ref(b.startAfter))
	}
	switch {
	case b.endAt != "":
		q = q.EndAt(r.ref(b.endAt))
	case b.endBefore != "":
		q = q.EndBefore(r.ref(b.endBefore))
	}
	docs, err := q.Limit(limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, fmt.Errorf("posts: community query: %w", err)
	}
	out := make([]*Post, 0, len(docs))
	for _, s := range docs {
		var d postDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("posts: decode post %s: %w", s.Ref.ID, err)
		}
		out = append(out, d.toPost(s.Ref.ID))
	}
	return out, nil
}
