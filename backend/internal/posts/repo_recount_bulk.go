// repo_recount_bulk.go serves `opsctl recount-children` (the bulk replyCount / quoteCount repair after erasures that ran
// before the #913 counter fix) and the unwired lazy helper RepairChildCounts.
//
//	Q-SC posts ORDER BY __name__ ASC [StartAfter(after)] EndBefore(MinID(before)) LIMIT page  (page <= RecountChildPage)
//	     -> the automatic __name__ index. Post ids are Snowflakes and createdAt is the id's millisecond
//	     (repo_create.go, repo_publish_scheduled.go), so "id < MinID(before)" is exactly "createdAt < before" and the last
//	     id is an exact, stable resume cursor. No firestore.indexes.json change.
//	Q-RC / Q-QC  the two count() aggregations of repo_recount.go (automatic single-field indexes).
//
// Read cost (Firestore bills a count() 1 read per 1,000 index entries matched, at least 1): a scanned post costs 1 document
// read in its page plus 2 aggregations, so about 3 reads (3,000 per 1,000 posts, +1 per 1,000 children counted). A REPOST
// costs its page read only: a reply or quote to a REPOST resolves to the original (service_thread.go replyParent), so a
// REPOST's counters stay 0 and are never counted. A stale post repaired with write costs 1 more document read, the 2
// aggregations again (inside the transaction) and 1 write. A page query that returns nothing still bills 1 read.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// RecountChildPage is the most posts one ScanChildParents call reads (an ops page, below opsPage).
const RecountChildPage = 100

// RecountChildMaxWrites is the most document writes one `opsctl recount-children --write` run issues (the backfill rule of
// BackfillMaxWrites, ADR-0024 D4): a bigger repair is finished by a resumed run.
const RecountChildMaxWrites = 5_000

// ChildParent is one scanned post: its id, kind and the two stored counters (absent = 0).
type ChildParent struct {
	ID      string
	Kind    Kind
	Replies int64
	Quotes  int64
}

// Countable reports whether the post can hold replies or quotes: every kind but REPOST (a missing kind counts).
func (p ChildParent) Countable() bool { return p.Kind != KindRepost }

// ChildRepair is the outcome of CountChildParent or RepairChildCounts for both counters.
type ChildRepair struct {
	Replies ChildRecount
	Quotes  ChildRecount
	// Repost is set for a REPOST: nothing was counted or written.
	Repost bool
	// Reads is the estimated billed reads of the call (aggregations, and the transaction's document read), excluding the
	// page read of the scan. Transaction retries add theirs.
	Reads int64
}

// Stale reports whether a counter differs from its count and is not capped (the case a repair writes).
func (c ChildRepair) Stale() bool { return c.Replies.stale() || c.Quotes.stale() }

// Wrote reports whether the call wrote the post document (one write for both fields).
func (c ChildRepair) Wrote() bool { return c.Replies.Written || c.Quotes.Written }

func (c ChildRecount) stale() bool { return c.Stored != c.Counted && !c.Capped }

// ChildBulkRecounter is the seam of `opsctl recount-children` (*FirestoreRepo).
type ChildBulkRecounter interface {
	// ScanChildParents returns up to limit (<= RecountChildPage) posts created before `before`, in id order, after the post
	// id `after` ("" = from the start). One query, a projection of kind and the two counters.
	ScanChildParents(ctx context.Context, before time.Time, after string, limit int) ([]ChildParent, error)
	// CountChildParent counts the replies and quotes of p outside any transaction and compares them with p's stored
	// counters as the page read them. It writes nothing: 2 aggregations (none for a REPOST).
	CountChildParent(ctx context.Context, p ChildParent) (ChildRepair, error)
	// RepairChildCounts recounts one post and fixes the counters that are stale; see FirestoreRepo.RepairChildCounts.
	RepairChildCounts(ctx context.Context, postID string) (ChildRepair, error)
}

var _ ChildBulkRecounter = (*FirestoreRepo)(nil)

// ScanChildParents implements ChildBulkRecounter (Q-SC).
func (r *FirestoreRepo) ScanChildParents(ctx context.Context, before time.Time, after string, limit int) ([]ChildParent, error) {
	if before.IsZero() {
		return nil, errors.New("posts: scan child parents: a before bound is required")
	}
	if after != "" && !ids.ValidPostID(after) {
		return nil, ErrInvalidID
	}
	if limit <= 0 || limit > RecountChildPage {
		limit = RecountChildPage
	}
	q := r.client.Collection(postsCollection).Select("kind", fieldReplyCount, fieldQuoteCount).
		OrderBy(firestore.DocumentID, firestore.Asc).EndBefore(r.ref(snowflake.MinID(before)))
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("posts: scan child parents: %w", err)
	}
	out := make([]ChildParent, len(snaps))
	for i, s := range snaps {
		out[i] = childParentOf(s.Ref.ID, s.Data())
	}
	return out, nil
}

// childParentOf reads a projected posts document. A counter that is absent or not an integer reads 0, so a repair sets it.
func childParentOf(id string, data map[string]any) ChildParent {
	kind, _ := data["kind"].(string)
	replies, _ := data[fieldReplyCount].(int64)
	quotes, _ := data[fieldQuoteCount].(int64)
	return ChildParent{ID: id, Kind: Kind(kind), Replies: replies, Quotes: quotes}
}

// aggReads is the billed reads of a count() that matched n entries: 1 per 1,000, at least 1.
func aggReads(n int64) int64 {
	if n <= 0 {
		return 1
	}
	return (n + 999) / 1000
}

// childRecountOf compares a stored counter with its count; a count at planCountCap is Capped (the true count may be higher).
func childRecountOf(stored, counted int64) ChildRecount {
	return ChildRecount{Stored: stored, Counted: counted, Capped: counted >= planCountCap}
}

// countRefs is the count() of the posts whose ref field equals postID, capped at planCountCap; inside tx when it is set.
func (r *FirestoreRepo) countRefs(ctx context.Context, tx *firestore.Transaction, ref, postID string) (int64, error) {
	q := r.client.Collection(postsCollection).Where(ref, "==", postID).Limit(planCountCap)
	agg := q.NewAggregationQuery().WithCount("n")
	if tx != nil {
		agg = agg.Transaction(tx)
	}
	res, err := agg.Get(ctx)
	if err != nil {
		return 0, fmt.Errorf("posts: count %s: %w", ref, err)
	}
	var n struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&n); err != nil {
		return 0, fmt.Errorf("posts: count %s: decode: %w", ref, err)
	}
	return n.N, nil
}

// CountChildParent implements ChildBulkRecounter. The two aggregations run concurrently; neither reads the post again.
func (r *FirestoreRepo) CountChildParent(ctx context.Context, p ChildParent) (ChildRepair, error) {
	if !p.Countable() {
		return ChildRepair{Repost: true}, nil
	}
	if !ids.ValidPostID(p.ID) {
		return ChildRepair{}, ErrInvalidID
	}
	var replies, quotes int64
	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() (err error) { replies, err = r.countRefs(gctx, nil, fieldReplyToID, p.ID); return err })
	g.Go(func() (err error) { quotes, err = r.countRefs(gctx, nil, fieldQuoteOfID, p.ID); return err })
	if err := g.Wait(); err != nil {
		return ChildRepair{}, fmt.Errorf("posts: count children: %w", err)
	}
	return ChildRepair{
		Replies: childRecountOf(p.Replies, replies),
		Quotes:  childRecountOf(p.Quotes, quotes),
		Reads:   aggReads(replies) + aggReads(quotes),
	}, nil
}

// RepairChildCounts recounts the replies and quotes of one post and sets the stale counters to their counts, in one
// transaction: the post read and both count() aggregations run inside it, so a reply or quote committed meanwhile
// conflicts with the read and the transaction retries instead of writing a wrong value. A counter already in step is not
// written, and a count at its 100,000 cap is never written (the true count may be higher); when neither counter is stale
// nothing is written at all. A REPOST is read and left alone (its counters stay 0). A missing post is ErrNotFound.
//
// Cost per call: 1 document read + 2 aggregations (each 1 read per 1,000 children, at least 1), + 1 write when stale.
//
// It is the lazy repair for an older post and is deliberately NOT wired into any path. Never call it on a read path
// (GetPost, feeds, threads): on a viral old post it would add a transaction per view and, while stale, contend with the
// ~1 write/s per-document limit. Suitable callers are write paths that already touch the post (an owner edit, a new
// reply) or an operator, rate-limited, as `opsctl recount-children --write` does.
func (r *FirestoreRepo) RepairChildCounts(ctx context.Context, postID string) (ChildRepair, error) {
	if !ids.ValidPostID(postID) {
		return ChildRepair{}, ErrInvalidID
	}
	var out ChildRepair
	var reads int64
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		out = ChildRepair{}
		reads++
		snap, err := tx.Get(r.ref(postID))
		if status.Code(err) == codes.NotFound {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		p := childParentOf(postID, snap.Data())
		if !p.Countable() {
			out.Repost = true
			return nil
		}
		replies, err := r.countRefs(ctx, tx, fieldReplyToID, postID)
		if err != nil {
			return err
		}
		quotes, err := r.countRefs(ctx, tx, fieldQuoteOfID, postID)
		if err != nil {
			return err
		}
		reads += aggReads(replies) + aggReads(quotes)
		out.Replies, out.Quotes = childRecountOf(p.Replies, replies), childRecountOf(p.Quotes, quotes)
		var ups []firestore.Update
		if out.Replies.stale() {
			ups = append(ups, setCount(fieldReplyCount, replies))
		}
		if out.Quotes.stale() {
			ups = append(ups, setCount(fieldQuoteCount, quotes))
		}
		if len(ups) == 0 {
			return nil
		}
		out.Replies.Written, out.Quotes.Written = out.Replies.stale(), out.Quotes.stale()
		return tx.Update(r.ref(postID), ups)
	})
	if errors.Is(err, ErrNotFound) {
		return ChildRepair{Reads: reads}, ErrNotFound
	}
	if err != nil {
		return ChildRepair{}, fmt.Errorf("posts: repair child counts: %w", err)
	}
	out.Reads = reads
	return out, nil
}
