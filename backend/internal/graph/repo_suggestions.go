package graph

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// maxEdgesByFollowers is the most follower uids one ListEdgesByFollowers call may name: the Firestore `in` limit.
const maxEdgesByFollowers = 30

// maxEdgesLimit is the largest Limit a ListEdgesByFollowers call may ask for (CLAUDE.md rule 5: max 50).
const maxEdgesLimit = 50

// ListEdgesByFollowers implements Repo for ListSuggestedUsers (ADR-0024 D8):
//
//	follows where followerId in [<= 30] order by createdAt desc, __name__ desc limit N
//
// the newest follows made by any of the named accounts. It is served by the existing COLLECTION-scope index
// follows (followerId ASC, createdAt DESC): `in` on the first index field, then the order by createdAt, with
// __name__ following the direction of the last field. No new index. Reads: len(result), minimum 1.
// followers must hold 1 to 30 valid uids and limit 1 to 50; anything else is a programming error, refused without a
// read (a snapshot array only ever holds valid uids, ADR-0008 A3).
func (r *FirestoreRepo) ListEdgesByFollowers(ctx context.Context, followers []string, limit int) ([]Edge, error) {
	if len(followers) == 0 || len(followers) > maxEdgesByFollowers {
		return nil, fmt.Errorf("graph: list edges by followers: %d followers, want 1 to %d", len(followers), maxEdgesByFollowers)
	}
	if limit < 1 || limit > maxEdgesLimit {
		return nil, fmt.Errorf("graph: list edges by followers: limit %d, want 1 to %d", limit, maxEdgesLimit)
	}
	for _, uid := range followers {
		if !ids.ValidUID(uid) {
			return nil, fmt.Errorf("graph: list edges by followers: invalid follower uid")
		}
	}
	query := r.client.Collection(followsCollection).
		Where("followerId", "in", followers).
		OrderBy("createdAt", firestore.Desc).
		OrderBy(firestore.DocumentID, firestore.Desc).
		Limit(limit)
	return runEdgeQuery(ctx, query, "list edges by followers")
}
