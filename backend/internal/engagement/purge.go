// purge.go implements Eraser and the export section for engagement (ADR-0018 D7): the right-to-delete and
// right-to-access paths for likes/*, reposts/* and userLikes/*.
//
//	Q-U  likes   where uid == X LIMIT 100            -> automatic single-field index
//	Q-V  reposts where uid == X LIMIT 100            -> automatic single-field index
//	Q-X  export: the same with ORDER BY __name__, StartAfter(last), pages of 500
//
// The Limit(100) pages are an ops path (ADR-0003 purge rule; CLAUDE.md rule 5's maximum of 50 governs RPC
// pagination only). The step runs after the posts step: the user's own REPOST posts are gone by then, so only the
// reposts docs and the original's repostCount remain.
package engagement

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	purgePage  = 100
	exportPage = 500

	purgeStepLikes   = 0
	purgeStepReposts = 1
	purgeStepDoc     = 2
)

var _ Eraser = (*FirestoreRepo)(nil)

// PurgeUser implements Eraser. One call does one bounded unit of work. Each like/repost is an atomic pair (delete
// with Exists, the post's counter -1); a page whose batch hits a deleted post falls back to one delete-only
// batch per doc. Reads: one per doc paged (1 for an empty page); writes: one counter per doc; deletes: one per
// doc, +1 for userLikes.
func (r *FirestoreRepo) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if err := r.ready(); err != nil {
		return cp, false, err
	}
	switch cp.Step {
	case purgeStepLikes:
		n, full, err := r.purgePage(ctx, uid, likesCollection, true)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Step: purgeStepLikes, Deleted: cp.Deleted + n}
		if !full {
			next.Step = purgeStepReposts
		}
		return next, false, nil
	case purgeStepReposts:
		n, full, err := r.purgePage(ctx, uid, repostsCollection, false)
		if err != nil {
			return cp, false, err
		}
		next := Checkpoint{Step: purgeStepReposts, Deleted: cp.Deleted + n}
		if !full {
			next.Step = purgeStepDoc
		}
		return next, false, nil
	default:
		b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
		b.Delete(r.userLikesRef(uid))
		if err := b.Commit(ctx); err != nil {
			return cp, false, fmt.Errorf("engagement: purge %s: delete userLikes: %w", logger.HashUID(uid), err)
		}
		slog.InfoContext(ctx, "engagement_purge_done", "uid_hash", logger.HashUID(uid), "deleted_total", cp.Deleted)
		return Checkpoint{Step: purgeStepDoc, Deleted: cp.Deleted}, true, nil
	}
}

// purgePage deletes up to purgePage docs of the user's likes or reposts with their post's counter.
func (r *FirestoreRepo) purgePage(ctx context.Context, uid, collection string, likes bool) (n int, full bool, err error) {
	docs, err := r.client.Collection(collection).Where("uid", "==", uid).Limit(purgePage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return 0, false, fmt.Errorf("engagement: purge %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return 0, false, nil
	}
	type row struct {
		ref    *firestore.DocumentRef
		postID string
	}
	rows := make([]row, 0, len(docs))
	for _, d := range docs {
		pid, _ := d.DataAt("postId")
		s, _ := pid.(string)
		rows = append(rows, row{ref: d.Ref, postID: s})
	}
	c := budget.FromContext(ctx)
	stage := func(b store.Batch, rw row, counter bool) {
		b.Delete(rw.ref, firestore.Exists)
		if !counter || rw.postID == "" {
			return
		}
		if likes {
			r.w.Writer.StageLikeCount(b, rw.postID, -1)
		} else {
			r.w.Writer.StageRepostCount(b, rw.postID, -1)
		}
	}
	var scratch budget.Counter
	b := store.NewFirestoreBatch(r.client, &scratch)
	for _, rw := range rows {
		stage(b, rw, true)
	}
	switch err := b.Commit(ctx); {
	case err == nil:
		c.AddWrites(scratch.Writes())
		c.AddDeletes(scratch.Deletes())
		return len(rows), len(docs) >= purgePage, nil
	case !store.IsPreconditionFailed(err):
		return 0, false, fmt.Errorf("engagement: purge %s: %w", logger.HashUID(uid), err)
	}
	// A post in the page is gone (its job removes the likes, but may not have run yet), or a doc was deleted by
	// a concurrent run: one batch per doc, with the counter first and without it second.
	done := 0
	for _, rw := range rows {
		for _, counter := range []bool{true, false} {
			var one budget.Counter
			sb := store.NewFirestoreBatch(r.client, &one)
			stage(sb, rw, counter)
			err := sb.Commit(ctx)
			if err == nil {
				c.AddWrites(one.Writes())
				c.AddDeletes(one.Deletes())
				done++
				break
			}
			if !store.IsPreconditionFailed(err) {
				return done, false, fmt.Errorf("engagement: purge %s: %w", logger.HashUID(uid), err)
			}
		}
	}
	return done, len(docs) >= purgePage, nil
}

// Exporter writes the `engagement` export section: the user's likes and reposts as post id and time.
type Exporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

var _ Exporter = (*FirestoreRepo)(nil)

type exportedEntry struct {
	PostID    string    `json:"postId" firestore:"postId"`
	CreatedAt time.Time `json:"createdAt" firestore:"createdAt"`
}

// ExportUser implements Exporter: {"likes":[...],"reposts":[...]} streamed in pages of exportPage (bounded
// memory). Reads: one per doc, minimum 1 per collection.
func (r *FirestoreRepo) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"likes":[`); err != nil {
		return fmt.Errorf("engagement: write export: %w", err)
	}
	if err := r.exportCollection(ctx, uid, likesCollection, w); err != nil {
		return err
	}
	if _, err := io.WriteString(w, `],"reposts":[`); err != nil {
		return fmt.Errorf("engagement: write export: %w", err)
	}
	if err := r.exportCollection(ctx, uid, repostsCollection, w); err != nil {
		return err
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("engagement: write export: %w", err)
	}
	return nil
}

func (r *FirestoreRepo) exportCollection(ctx context.Context, uid, collection string, w io.Writer) error {
	enc := json.NewEncoder(w)
	first := true
	var last *firestore.DocumentSnapshot
	for {
		q := r.client.Collection(collection).Where("uid", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc).Limit(exportPage)
		if last != nil {
			q = q.StartAfter(last)
		}
		docs, err := q.Documents(ctx).GetAll()
		reads := int64(len(docs))
		if reads == 0 {
			reads = 1
		}
		budget.FromContext(ctx).AddReads(reads)
		if err != nil {
			return fmt.Errorf("engagement: export %s: query: %w", logger.HashUID(uid), err)
		}
		for _, s := range docs {
			var e exportedEntry
			if err := s.DataTo(&e); err != nil {
				return fmt.Errorf("engagement: export decode %s: %w", s.Ref.ID, err)
			}
			e.CreatedAt = e.CreatedAt.UTC()
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("engagement: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(e); err != nil {
				return fmt.Errorf("engagement: write export: %w", err)
			}
		}
		if len(docs) < exportPage {
			return nil
		}
		last = docs[len(docs)-1]
	}
}
