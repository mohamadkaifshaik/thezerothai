// purge.go implements Eraser, PurgePlan and Exporter on FirestoreRepo (ADR-0010 D19 Q-E, plan T10): the
// right-to-delete and right-to-access paths for `posts`.
//
// Q-E:  posts where authorId == uid ORDER BY createdAt DESC, __name__ DESC LIMIT 500. Descending, so it uses the
// existing (authorId ASC, createdAt DESC) index (no firestore.indexes.json change). The Limit(500) is an ops path
// (ADR-0003 purge rule); CLAUDE.md rule 5's maximum of 50 governs RPC pagination only.
package posts

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

// opsPage is the page size of the purge and export queries, and the batch bound (Firestore's 500 writes).
const opsPage = 500

// planCountCap bounds the dry-run count aggregation (a count query is billed 1 read per 1,000 index entries).
const planCountCap = 100_000

var (
	_ Eraser   = (*FirestoreRepo)(nil)
	_ Exporter = (*FirestoreRepo)(nil)
)

// PurgePlan is the dry-run result of PlanPurge.
type PurgePlan struct {
	// Posts is the number of posts authored by the user (capped at planCountCap).
	Posts int64
}

// authorQuery is Q-E: the user's posts, newest first, with the explicit tie-breaker.
func (r *FirestoreRepo) authorQuery(uid string) firestore.Query {
	return r.client.Collection(postsCollection).Where("authorId", "==", uid).
		OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
}

// PurgeUser implements Eraser. One call deletes one page (the newest <= 500 remaining posts) in one atomic
// batch. Deleted docs drop out of the next page, so the purge is self-resuming after a crash and the checkpoint
// only carries the running count. There are no counter updates: the user doc is deleted anyway (runbook).
// Reads: one per post returned (1 for an empty page); deletes: one per post.
func (r *FirestoreRepo) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	docs, err := r.authorQuery(uid).Select().Limit(opsPage).Documents(ctx).GetAll()
	reads := int64(len(docs))
	if reads == 0 {
		reads = 1
	}
	budget.FromContext(ctx).AddReads(reads)
	if err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
	}
	next := Checkpoint{Deleted: cp.Deleted + len(docs)}
	slog.InfoContext(ctx, "posts_purge_batch", "uid_hash", logger.HashUID(uid), "posts", len(docs), "deleted_total", next.Deleted)
	// A short page was the last one (the account is DELETING, so nothing new arrives).
	return next, len(docs) < opsPage, nil
}

// PlanPurge counts the user's posts without writing anything (opsctl purge-posts --dry-run). Reads: one per
// 1,000 counted index entries, minimum 1.
func (r *FirestoreRepo) PlanPurge(ctx context.Context, uid string) (PurgePlan, error) {
	q := r.client.Collection(postsCollection).Where("authorId", "==", uid).Limit(planCountCap)
	res, err := q.NewAggregationQuery().WithCount("n").Get(ctx)
	if err != nil {
		return PurgePlan{}, fmt.Errorf("posts: plan purge %s: %w", logger.HashUID(uid), err)
	}
	var out struct {
		N int64 `firestore:"n"`
	}
	if err := res.DataTo(&out); err != nil {
		return PurgePlan{}, fmt.Errorf("posts: plan purge decode: %w", err)
	}
	n := out.N
	reads := n/1000 + 1
	budget.FromContext(ctx).AddReads(reads)
	return PurgePlan{Posts: n}, nil
}

// exportedPost is one post in the manual export (ADR-0003 "Deletes & privacy"): id, text, createdAt, hashtags and
// mentions as handles only (never the mentioned users' uids).
type exportedPost struct {
	ID        string    `json:"id"`
	Text      string    `json:"text"`
	CreatedAt time.Time `json:"createdAt"`
	Hashtags  []string  `json:"hashtags"`
	Mentions  []string  `json:"mentions"`
}

// ExportUser implements Exporter: it streams {"userId": ..., "posts": [...]} to w, newest first, in pages of
// opsPage (memory stays bounded). Reads: one per post, minimum 1.
func (r *FirestoreRepo) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := fmt.Fprintf(w, `{"userId":%q,"posts":[`, uid); err != nil {
		return fmt.Errorf("posts: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	var last *firestore.DocumentSnapshot
	for {
		q := r.authorQuery(uid).Limit(opsPage)
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
			return fmt.Errorf("posts: export %s: query: %w", logger.HashUID(uid), err)
		}
		for _, s := range docs {
			var d postDoc
			if err := s.DataTo(&d); err != nil {
				return fmt.Errorf("posts: export decode post %s: %w", s.Ref.ID, err)
			}
			ep := exportedPost{ID: s.Ref.ID, Text: d.Text, CreatedAt: d.CreatedAt.UTC(), Hashtags: d.Hashtags, Mentions: make([]string, 0, len(d.Mentions))}
			if ep.Hashtags == nil {
				ep.Hashtags = []string{}
			}
			for _, m := range d.Mentions {
				ep.Mentions = append(ep.Mentions, m.Handle)
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("posts: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(ep); err != nil {
				return fmt.Errorf("posts: write export: %w", err)
			}
		}
		if len(docs) < opsPage {
			break
		}
		last = docs[len(docs)-1]
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("posts: write export: %w", err)
	}
	return nil
}
