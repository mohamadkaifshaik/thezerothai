package graph

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Lists is one read of graph/{uid} for the own-list RPCs: the ordered arrays plus the Snapshot of the same doc.
type Lists struct {
	Snapshot Snapshot
	// Blocked and Muted are in insertion order (ArrayUnion appends), oldest first.
	Blocked []string
	Muted   []string
}

// GetLists implements Repo: 1 read.
func (r *FirestoreRepo) GetLists(ctx context.Context, uid string) (Lists, error) {
	d, err := r.getGraph(ctx, uid)
	if err != nil {
		return Lists{}, err
	}
	return Lists{Snapshot: d.toSnapshot(), Blocked: d.Blocked, Muted: d.Muted}, nil
}

// Edge is one follows/{followerId}_{followeeId} document.
type Edge struct {
	DocID      string
	FollowerID string
	FolloweeID string
	CreatedAt  time.Time
}

// otherUID is the counterpart of the listed user: the follower when listing followers, else the followee.
func (e Edge) otherUID(followers bool) string {
	if followers {
		return e.FollowerID
	}
	return e.FolloweeID
}

// EdgeQuery selects one page of follow edges. Limit must already be clamped by the caller.
type EdgeQuery struct {
	UID       string
	Followers bool // true: edges where followeeId == UID; false: where followerId == UID
	Limit     int
	After     *cursor.Cursor // nil = first page
}

// ListEdges implements Repo: `follows where <field> == uid order by createdAt desc, __name__ desc limit N`
// (existing composite indexes). Reads: len(result), minimum 1 (Firestore bills an empty query as one read).
func (r *FirestoreRepo) ListEdges(ctx context.Context, q EdgeQuery) ([]Edge, error) {
	field := "followerId"
	if q.Followers {
		field = "followeeId"
	}
	query := r.client.Collection(followsCollection).
		Where(field, "==", q.UID).
		OrderBy("createdAt", firestore.Desc).
		OrderBy(firestore.DocumentID, firestore.Desc).
		Limit(q.Limit)
	if q.After != nil {
		query = query.StartAfter(q.After.CreatedAt, r.client.Collection(followsCollection).Doc(q.After.DocID))
	}
	return runEdgeQuery(ctx, query, "list edges "+q.UID)
}

// runEdgeQuery executes a follows query, charges its reads to the request budget (len(result), minimum 1: Firestore
// bills an empty query as one read) and decodes the documents. what names the caller in the error text.
func runEdgeQuery(ctx context.Context, query firestore.Query, what string) ([]Edge, error) {
	docs, err := query.Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, fmt.Errorf("graph: %s: %w", what, err)
	}
	out := make([]Edge, 0, len(docs))
	for _, d := range docs {
		var f followDoc
		if err := d.DataTo(&f); err != nil {
			return nil, fmt.Errorf("graph: decode follow %s: %w", d.Ref.ID, err)
		}
		out = append(out, Edge{DocID: d.Ref.ID, FollowerID: f.FollowerID, FolloweeID: f.FolloweeID, CreatedAt: f.CreatedAt})
	}
	return out, nil
}
