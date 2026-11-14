// purge_release.go is the counter half of PurgeUser phase 0: an erased user's replies and quotes are deleted with
// the replyCount / quoteCount they held on other posts, in the same atomic batch, so the counters end exact (the
// same release DeletePost does through releaseParent and releaseEngagement, which are best effort and per post).
package posts

import (
	"cmp"
	"context"
	"fmt"
	"slices"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	fieldReplyToID  = "replyToId"
	fieldQuoteOfID  = "quoteOfId"
	fieldReplyCount = "replyCount"
	fieldQuoteCount = "quoteCount"
	maxBatchWrites  = 500
)

// purgeOwnPage is the phase-0 page: every doc is one delete plus at most one counter target (a post cannot both
// reply and quote, CreatePost refuses it), so a page is at most 2*purgeOwnPage writes, within Firestore's 500.
// A page that would exceed the bound anyway (malformed data carrying both fields) goes to the per-doc path.
const purgeOwnPage = maxBatchWrites / 2

// ownRow is one of the erased user's posts as phase 0 reads it: the ids of the posts it holds a counter on.
type ownRow struct {
	ref     *firestore.DocumentRef
	replyTo string
	quoteOf string
}

// counterDelta is a summed decrement on one counter field of one post.
type counterDelta struct {
	postID string
	field  string
	delta  int64
}

// releaseDeltas sums the decrements rows hold, one entry per (post, field), sorted for a deterministic batch.
// A target in skip (a post of the same page, deleted in the same batch: a self-reply or self-quote) is dropped, its
// counter dies with it; a target on a later page still exists and is decremented, which is harmless.
func releaseDeltas(rows []ownRow, skip map[string]bool) []counterDelta {
	sums := map[[2]string]int64{}
	add := func(id, field string) {
		if id == "" || skip[id] {
			return
		}
		sums[[2]string{id, field}]--
	}
	for _, rw := range rows {
		add(rw.replyTo, fieldReplyCount)
		add(rw.quoteOf, fieldQuoteCount)
	}
	out := make([]counterDelta, 0, len(sums))
	for k, d := range sums {
		out = append(out, counterDelta{postID: k[0], field: k[1], delta: d})
	}
	slices.SortFunc(out, func(a, b counterDelta) int {
		return cmp.Or(cmp.Compare(a.postID, b.postID), cmp.Compare(a.field, b.field))
	})
	return out
}

// pageWrites is the number of writes one batch for rows takes: a delete per row and an update per delta.
func pageWrites(rows int, deltas []counterDelta) int { return rows + len(deltas) }

// stringField reads a string field of a (Select-ed) snapshot; an absent or non-string field is "".
func stringField(d *firestore.DocumentSnapshot, field string) string {
	v, err := d.DataAt(field)
	if err != nil {
		return ""
	}
	s, _ := v.(string)
	return s
}

func ownRows(docs []*firestore.DocumentSnapshot) ([]ownRow, map[string]bool) {
	rows := make([]ownRow, 0, len(docs))
	inPage := make(map[string]bool, len(docs))
	for _, d := range docs {
		rows = append(rows, ownRow{ref: d.Ref, replyTo: stringField(d, fieldReplyToID), quoteOf: stringField(d, fieldQuoteOfID)})
		inPage[d.Ref.ID] = true
	}
	return rows, inPage
}

// stageDelta appends one decrement through the counter helpers (a sharded counter later swaps only their body).
func (r *FirestoreRepo) stageDelta(b store.Batch, d counterDelta) {
	if d.field == fieldReplyCount {
		bumpReplyCount(b, r.ref(d.postID), d.delta)
		return
	}
	bumpCount(b, r.ref(d.postID), d.field, d.delta)
}

// purgeOwn deletes docs (the erased user's posts of one page) with their counter releases and reports how many
// posts it deleted and how many counter updates it committed.
//
// Idempotency: every delete carries firestore.Exists and the batch is atomic, so a decrement commits only together
// with the delete of the post that held it, and exactly once: a redelivery (crash after the commit, before the
// checkpoint was stored) re-queries and no longer finds the deleted posts; a racing or stale run holding the same
// page fails the Exists precondition. The fast path fails as a whole on a precondition (a target post already
// deleted, whose counter died with it, or a doc deleted by a concurrent run), and the fallback then commits one
// batch per doc: counter and delete first, delete only second; a doc that fails both is already gone and is skipped.
func (r *FirestoreRepo) purgeOwn(ctx context.Context, uid string, docs []*firestore.DocumentSnapshot) (deleted, released int, err error) {
	rows, inPage := ownRows(docs)
	deltas := releaseDeltas(rows, inPage)
	if pageWrites(len(rows), deltas) <= maxBatchWrites {
		b := store.NewFirestoreBatch(r.client)
		for _, rw := range rows {
			b.Delete(rw.ref, firestore.Exists)
		}
		for _, d := range deltas {
			r.stageDelta(b, d)
		}
		switch err := b.Commit(ctx); {
		case err == nil:
			return len(rows), len(deltas), nil
		case !store.IsPreconditionFailed(err):
			return 0, 0, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
		}
	}
	for _, rw := range rows {
		// Up to 2 commits per doc: stop at the invocation deadline and let the checkpointed job resume.
		if err := ctx.Err(); err != nil {
			return deleted, released, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
		}
		own := releaseDeltas([]ownRow{rw}, inPage)
		for _, withCounters := range []bool{true, false} {
			if !withCounters && len(own) == 0 {
				break // the delete-only batch would repeat the one that just failed
			}
			b := store.NewFirestoreBatch(r.client)
			b.Delete(rw.ref, firestore.Exists)
			if withCounters {
				for _, d := range own {
					r.stageDelta(b, d)
				}
			}
			err := b.Commit(ctx)
			if err == nil {
				deleted++
				if withCounters {
					released += len(own)
				}
				break
			}
			if !store.IsPreconditionFailed(err) {
				return deleted, released, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
			}
		}
	}
	return deleted, released, nil
}
