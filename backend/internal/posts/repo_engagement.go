// repo_engagement.go holds the storage paths engagement (P5, ADR-0018) drives through posts' seams. posts owns
// posts/*, so every write to a post doc made on behalf of a like, a repost, a quote or its clean-up lives here:
//
//	batch staging (EngagementWriter): likeCount / repostCount increments, the REPOST create, the REPOST delete
//	clean-up (Cleanup): RemoveReposts, TombstoneQuotes
//	  Q-O  posts where repostOfId == X LIMIT n         -> automatic single-field index
//	  Q-Q  posts where quoteOfId == X LIMIT n          -> automatic single-field index
//	  Q-C  posts where embeddedAuthorId == uid LIMIT n -> automatic single-field index (purge copy phase)
//
// None of them needs a composite index: single-equality filters with a Limit and no ordering. Deleted and
// tombstoned documents drop out of the next page, so every loop is self-resuming.
package posts

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// CleanupPage is the page size of the clean-up queries (an ops path, ADR-0003 purge rule; one page is at most
// 3 writes per document, so a batch stays under Firestore's 500).
const CleanupPage = 100

// EngagementWriter is the batch-staging seam engagement uses to change posts docs inside its own transaction or
// batch (the identity.Counters pattern: posts appends, engagement commits). *FirestoreRepo implements it.
type EngagementWriter interface {
	// StageLikeCount appends FieldValue.Increment(delta) on posts/{id}.likeCount. The Update carries an implicit
	// Exists precondition, so a post deleted in between fails the commit with NotFound (0 writes).
	StageLikeCount(b store.Batch, postID string, delta int64)
	// StageRepostCount is StageLikeCount for repostCount.
	StageRepostCount(b store.Batch, postID string, delta int64)
	// StagePollVote appends the blind counter bump of one vote: Increment(poll.counts.<choice>) and Increment(poll.total) on
	// posts/{id} in ONE Update (one write), with the implicit Exists precondition, so a post deleted in between fails the commit
	// with NotFound (0 writes). The field paths are firestore.FieldPath values, not dotted strings: the counts keys are numeric
	// strings (ADR-0029 D1). The one counter helper of polls: sharding replaces its body, not its callers.
	StagePollVote(b store.Batch, postID string, choice int)
	// StagePollChange appends the blind counter move of one vote change (ADR-0029 Amendment 1 A2.3): Increment(poll.counts.<from>, -1) and
	// Increment(poll.counts.<to>, +1) on posts/{id} in ONE Update (one write); poll.total is not touched. Same Exists precondition and field-path
	// rule as StagePollVote. With StagePollVote, the only poll counter writers: sharding replaces both bodies, not their callers.
	StagePollChange(b store.Batch, postID string, from, to int)
	// StageRepost appends the Create of a REPOST post doc.
	StageRepost(b store.Batch, p *Post)
	// StageDelete appends the delete of posts/{id}; mustExist adds the Exists precondition.
	StageDelete(b store.Batch, postID string, mustExist bool)
}

// Cleanup is the dependants clean-up seam of a post that is gone or hidden (engagement's post_delete job, the
// account purge, opsctl takedown). *FirestoreRepo implements it. Every call handles one page and reports whether
// more may remain; calling again continues because handled documents leave the query.
type Cleanup interface {
	// RemoveReposts deletes up to max REPOST posts of originalID with their reposts docs (through RepostLinks) and
	// the reposters' postsCount -1; when originalExists it also decrements the original's repostCount in the same
	// batch (a takedown keeps the post, so the invariant must hold). Reads len(page), minimum 1; writes 2 per
	// repost + 1, deletes 2 per repost.
	RemoveReposts(ctx context.Context, originalID string, originalExists bool, max int) (removed int, more bool, err error)
	// TombstoneQuotes replaces the embed of up to max quotes of originalID with {postId, unavailable}, clearing
	// quoteOfId and embeddedAuthorId. Reads len(page), minimum 1; writes len(page).
	TombstoneQuotes(ctx context.Context, originalID string, max int) (changed int, more bool, err error)
}

// CopiedLister finds the posts of one author that other accounts have copied (reposted or quoted), so a suspension
// can clean the copies up (issue #151, ADR-0018). *FirestoreRepo implements it.
type CopiedLister interface {
	// ListCopied pages uid's posts newest first (up to hidePage = 250 per call) and returns the ids of those whose
	// repostCount or quoteCount is above zero. next is where to resume; done reports the last page. Reads one per post
	// paged (minimum 1), no writes. The counters are written in the same batch as the copy, so they are not stale.
	ListCopied(ctx context.Context, uid string, after *Position) (ids []string, next *Position, done bool, err error)
}

var (
	_ EngagementWriter = (*FirestoreRepo)(nil)
	_ Cleanup          = (*FirestoreRepo)(nil)
	_ CopiedLister     = (*FirestoreRepo)(nil)
)

// SetRepostLinks gives the repo engagement's reposts-doc seam, needed by RemoveReposts and the purge copy phase.
// Call once at startup (the service has its own SetRepostLinks). Any RepostLinks satisfies it.
func (r *FirestoreRepo) SetRepostLinks(l ReleaseStager) { r.links = l }

// StageLikeCount implements EngagementWriter.
func (r *FirestoreRepo) StageLikeCount(b store.Batch, postID string, delta int64) {
	bumpCount(b, r.ref(postID), "likeCount", delta)
}

// StageRepostCount implements EngagementWriter.
func (r *FirestoreRepo) StageRepostCount(b store.Batch, postID string, delta int64) {
	bumpCount(b, r.ref(postID), "repostCount", delta)
}

// StagePollVote implements EngagementWriter.
func (r *FirestoreRepo) StagePollVote(b store.Batch, postID string, choice int) {
	b.Update(r.ref(postID), []firestore.Update{
		{FieldPath: firestore.FieldPath{"poll", "counts", strconv.Itoa(choice)}, Value: firestore.Increment(1)},
		{FieldPath: firestore.FieldPath{"poll", "total"}, Value: firestore.Increment(1)},
	})
}

// StagePollChange implements EngagementWriter.
func (r *FirestoreRepo) StagePollChange(b store.Batch, postID string, from, to int) {
	b.Update(r.ref(postID), []firestore.Update{
		{FieldPath: firestore.FieldPath{"poll", "counts", strconv.Itoa(from)}, Value: firestore.Increment(-1)},
		{FieldPath: firestore.FieldPath{"poll", "counts", strconv.Itoa(to)}, Value: firestore.Increment(1)},
	})
}

// StageRepost implements EngagementWriter.
func (r *FirestoreRepo) StageRepost(b store.Batch, p *Post) {
	b.Create(r.ref(p.ID), toDoc(p))
}

// StageDelete implements EngagementWriter.
func (r *FirestoreRepo) StageDelete(b store.Batch, postID string, mustExist bool) {
	if mustExist {
		b.Delete(r.ref(postID), firestore.Exists)
		return
	}
	b.Delete(r.ref(postID))
}

// pageDocs runs a single-equality query with a Limit and charges the reads (minimum 1: an empty query bills 1).
func (r *FirestoreRepo) pageDocs(ctx context.Context, field, value string, limit int) ([]*firestore.DocumentSnapshot, error) {
	docs, err := r.client.Collection(postsCollection).Where(field, "==", value).Limit(limit).Documents(ctx).GetAll()
	n := int64(len(docs))
	if n == 0 {
		n = 1
	}
	budget.FromContext(ctx).AddReads(n)
	if err != nil {
		return nil, fmt.Errorf("posts: %s query: %w", field, err)
	}
	return docs, nil
}

// repostRow is the part of a REPOST doc the removal needs.
type repostRow struct{ id, authorID, originalID string }

// RemoveReposts implements Cleanup.
func (r *FirestoreRepo) RemoveReposts(ctx context.Context, originalID string, originalExists bool, limit int) (int, bool, error) {
	if r.w.Counters == nil || r.links == nil {
		return 0, false, errors.New("posts: repo has no Counters or RepostLinks configured")
	}
	limit = min(limit, CleanupPage)
	docs, err := r.pageDocs(ctx, "repostOfId", originalID, limit)
	if err != nil {
		return 0, false, err
	}
	rows := make([]repostRow, 0, len(docs))
	for _, d := range docs {
		var pd postDoc
		if err := d.DataTo(&pd); err != nil {
			return 0, false, fmt.Errorf("posts: decode repost %s: %w", d.Ref.ID, err)
		}
		if Kind(pd.Kind) != KindRepost {
			continue // only REPOST docs carry repostOfId; anything else is never touched
		}
		rows = append(rows, repostRow{id: d.Ref.ID, authorID: pd.AuthorID, originalID: originalID})
	}
	removed, err := r.removeRepostRows(ctx, rows, originalExists)
	return removed, len(docs) >= limit, err
}

// removeRepostRows deletes the rows in one batch (3 writes each, +1) and falls back to one batch per row, with
// fewer counters each time, when the batch fails with a precondition error: a REPOST deleted concurrently, a
// reposter's users doc that is gone, or an original that is gone.
func (r *FirestoreRepo) removeRepostRows(ctx context.Context, rows []repostRow, originalExists bool) (int, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	c := budget.FromContext(ctx)
	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	for _, row := range rows {
		r.stageRepostRemoval(b, row, true)
	}
	if originalExists {
		bumpCount(b, r.ref(rows[0].originalID), "repostCount", -int64(len(rows)))
	}
	err := b.Commit(ctx)
	switch {
	case err == nil:
		c.AddWrites(scratch.Writes())
		c.AddDeletes(scratch.Deletes())
		return len(rows), nil
	case !store.IsPreconditionFailed(err):
		return 0, fmt.Errorf("posts: remove reposts: %w", err)
	}
	removed := 0
	for _, row := range rows {
		ok, err := r.removeOneRepost(ctx, row, originalExists)
		if err != nil {
			return removed, err
		}
		if ok {
			removed++
		}
	}
	return removed, nil
}

func (r *FirestoreRepo) stageRepostRemoval(b store.Batch, row repostRow, postsCount bool) {
	b.Delete(r.ref(row.id), firestore.Exists)
	r.links.StageRelease(b, row.originalID, row.authorID)
	if postsCount {
		r.w.Counters.AddPostsCount(b, row.authorID, -1)
	}
}

// removeOneRepost tries the full variant, then without the reposter's postsCount (users doc gone), then without
// the original's repostCount (original gone). A last failure means the REPOST is already gone: nothing to do.
func (r *FirestoreRepo) removeOneRepost(ctx context.Context, row repostRow, originalExists bool) (bool, error) {
	return r.removeOneRepostWith(ctx, row, originalExists, nil)
}

// removeOneRepostWith is removeOneRepost; extra, when set, stages more writes in the same batch of every variant
// (Takedown adds the removal-log entry, so a REPOST is never deleted without being logged).
func (r *FirestoreRepo) removeOneRepostWith(ctx context.Context, row repostRow, originalExists bool, extra func(store.Batch)) (bool, error) {
	c := budget.FromContext(ctx)
	for _, v := range []struct{ postsCount, repostCount bool }{
		{true, originalExists}, {false, originalExists}, {true, false}, {false, false},
	} {
		if !originalExists && v.repostCount {
			continue
		}
		var scratch budget.Counter
		b := store.NewFirestoreBatch(r.client, &scratch)
		r.stageRepostRemoval(b, row, v.postsCount)
		if extra != nil {
			extra(b)
		}
		if v.repostCount {
			bumpCount(b, r.ref(row.originalID), "repostCount", -1)
		}
		err := b.Commit(ctx)
		switch {
		case err == nil:
			c.AddWrites(scratch.Writes())
			c.AddDeletes(scratch.Deletes())
			return true, nil
		case !store.IsPreconditionFailed(err):
			return false, fmt.Errorf("posts: remove repost: %w", logger.RedactErr(err, row.authorID))
		}
	}
	return false, nil
}

// tombstoneUpdates is the Update that turns a QUOTE's embed into the tombstone (ADR-0018 D12).
func tombstoneUpdates(originalID string) []firestore.Update {
	return []firestore.Update{
		{Path: "embedded", Value: map[string]any{"postId": originalID, "unavailable": true}},
		{Path: "quoteOfId", Value: firestore.Delete},
		{Path: "embeddedAuthorId", Value: firestore.Delete},
	}
}

// TombstoneQuotes implements Cleanup.
func (r *FirestoreRepo) TombstoneQuotes(ctx context.Context, originalID string, limit int) (int, bool, error) {
	limit = min(limit, CleanupPage)
	docs, err := r.pageDocs(ctx, "quoteOfId", originalID, limit)
	if err != nil {
		return 0, false, err
	}
	n, err := r.tombstoneDocs(ctx, docs, originalID)
	return n, len(docs) >= limit, err
}

// tombstoneDocs updates the quote docs of one original in one batch, one by one when the batch hits a deleted quote.
func (r *FirestoreRepo) tombstoneDocs(ctx context.Context, docs []*firestore.DocumentSnapshot, originalID string) (int, error) {
	items := make([]quoteItem, len(docs))
	for i, d := range docs {
		items[i] = quoteItem{ref: d.Ref, originalID: originalID}
	}
	return r.tombstoneItems(ctx, items)
}

// quoteItem is one quote doc to tombstone with the id of the original it quotes (which may differ per item).
type quoteItem struct {
	ref        *firestore.DocumentRef
	originalID string
}

// tombstoneItems updates the quote docs in one batch (the caller keeps it within one page, <= 500 writes), one
// by one when the batch hits a deleted quote.
func (r *FirestoreRepo) tombstoneItems(ctx context.Context, items []quoteItem) (int, error) {
	if len(items) == 0 {
		return 0, nil
	}
	c := budget.FromContext(ctx)
	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	for _, it := range items {
		b.Update(it.ref, tombstoneUpdates(it.originalID))
	}
	err := b.Commit(ctx)
	switch {
	case err == nil:
		c.AddWrites(scratch.Writes())
		return len(items), nil
	case !store.IsPreconditionFailed(err):
		return 0, fmt.Errorf("posts: tombstone quotes: %w", err)
	}
	n := 0
	for _, it := range items {
		var one budget.Counter
		sb := store.NewFirestoreBatch(r.client, &one)
		sb.Update(it.ref, tombstoneUpdates(it.originalID))
		switch err := sb.Commit(ctx); {
		case err == nil:
			c.AddWrites(one.Writes())
			n++
		case store.IsPreconditionFailed(err):
			// the quote itself was deleted in the meantime
		default:
			return n, fmt.Errorf("posts: tombstone quote: %w", err)
		}
	}
	return n, nil
}

// ListCopied implements CopiedLister.
func (r *FirestoreRepo) ListCopied(ctx context.Context, uid string, after *Position) ([]string, *Position, bool, error) {
	q := r.authorQuery(uid).Select("createdAt", "repostCount", "quoteCount")
	if after != nil {
		q = q.StartAfter(after.CreatedAt, r.ref(after.ID))
	}
	docs, err := q.Limit(hidePage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return nil, after, false, fmt.Errorf("posts: list copied %s: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return nil, after, true, nil
	}
	var ids []string
	for _, s := range docs {
		var d struct {
			RepostCount int64 `firestore:"repostCount"`
			QuoteCount  int64 `firestore:"quoteCount"`
		}
		if err := s.DataTo(&d); err != nil {
			return nil, after, false, fmt.Errorf("posts: list copied decode %s: %w", s.Ref.ID, err)
		}
		if d.RepostCount > 0 || d.QuoteCount > 0 {
			ids = append(ids, s.Ref.ID)
		}
	}
	last := docs[len(docs)-1]
	var ld struct {
		CreatedAt time.Time `firestore:"createdAt"`
	}
	if err := last.DataTo(&ld); err != nil {
		return nil, after, false, fmt.Errorf("posts: list copied decode %s: %w", last.Ref.ID, err)
	}
	return ids, &Position{CreatedAt: ld.CreatedAt.UTC(), ID: last.Ref.ID}, len(docs) < hidePage, nil
}
