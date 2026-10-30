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
	if cp.Phase >= 2 {
		return r.purgeRemovals(ctx, uid, cp)
	}
	if cp.Phase >= 1 {
		return r.purgeCopies(ctx, uid, cp)
	}
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
		return Checkpoint{Deleted: cp.Deleted, Phase: 1}, false, nil
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
	// A short page was the last one (the account is DELETING, so nothing new arrives): continue with the copies.
	if len(docs) < opsPage {
		next.Phase = 1
	}
	return next, false, nil
}

// purgeCopies is phase 1 of PurgeUser (ADR-0018 D14): the deleted user's text also lives inside other users'
// REPOST docs (removed, with their reposts docs and the reposter's postsCount) and QUOTE docs (embed replaced by
// a tombstone). One page of at most CleanupPage per call (Q-C, single equality, no index change). Reads one per
// doc (minimum 1); writes <= 3 per doc.
func (r *FirestoreRepo) purgeCopies(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	if r.w.Counters == nil || r.links == nil {
		return cp, false, fmt.Errorf("posts: purge %s: repo has no Counters or RepostLinks configured", logger.HashUID(uid))
	}
	docs, err := r.pageDocs(ctx, "embeddedAuthorId", uid, CleanupPage)
	if err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
	}
	var rows []repostRow
	var quotes []*firestore.DocumentSnapshot
	for _, d := range docs {
		var pd postDoc
		if err := d.DataTo(&pd); err != nil {
			return cp, false, fmt.Errorf("posts: purge decode %s: %w", d.Ref.ID, err)
		}
		switch Kind(pd.Kind) {
		case KindRepost:
			rows = append(rows, repostRow{id: d.Ref.ID, authorID: pd.AuthorID, originalID: pd.RepostOfID})
		case KindQuote:
			quotes = append(quotes, d)
		}
	}
	// The original (the deleted user's post) is gone or going: no repostCount to keep exact.
	removed, err := r.removeRepostRows(ctx, rows, false)
	if err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
	}
	items := make([]quoteItem, 0, len(quotes))
	for _, q := range quotes {
		var pd postDoc
		if err := q.DataTo(&pd); err != nil {
			return cp, false, fmt.Errorf("posts: purge decode %s: %w", q.Ref.ID, err)
		}
		items = append(items, quoteItem{ref: q.Ref, originalID: pd.QuoteOfID})
	}
	// One commit per page (CleanupPage <= 500 writes), not one per quote.
	tombstoned, err := r.tombstoneItems(ctx, items)
	if err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: %w", logger.HashUID(uid), err)
	}
	next := Checkpoint{Deleted: cp.Deleted, Phase: 1, Copies: cp.Copies + removed + tombstoned}
	slog.InfoContext(ctx, "posts_purge_copies", "uid_hash", logger.HashUID(uid), "reposts", removed, "quotes", tombstoned)
	// A full page that made no progress would repeat forever; stop and let the residue sweep name it.
	stuck := len(docs) > 0 && removed+tombstoned == 0
	if stuck {
		// Error severity: this reaches Error Reporting; the residue sweep and the runbook name the way out.
		slog.ErrorContext(ctx, "posts_purge_copies_stuck", "uid_hash", logger.HashUID(uid), "docs", len(docs))
	}
	// A short page was the last one: continue with the user's postRemovals entries (phase 2) unless stuck.
	if len(docs) < CleanupPage && !stuck {
		next.Phase = 2
		return next, false, nil
	}
	return next, stuck, nil
}

// purgeRemovals is phase 2 of PurgeUser (amendment 2026-10-18 (b)): postRemovals entries carry the author's uid
// (pseudonymous link), so they are deleted with the account: authorId == uid, one equality filter served by the
// single-field index, Limit(opsPage), no ordering. Deleted docs drop out of the next page (self-resuming). Reads
// one per entry (minimum 1); deletes one per entry. Normally 0 or a handful of entries (only moderated posts).
func (r *FirestoreRepo) purgeRemovals(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	docs, err := r.client.Collection(removalsCollection).Where("authorId", "==", uid).Select().Limit(opsPage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(int64(max(len(docs), 1)))
	if err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: removals query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return cp, false, fmt.Errorf("posts: purge %s: removals: %w", logger.HashUID(uid), err)
	}
	slog.InfoContext(ctx, "posts_purge_removals", "uid_hash", logger.HashUID(uid), "entries", len(docs))
	return cp, len(docs) < opsPage, nil
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
	// ReplyToPostID is set for replies (P3); the parent's author is not exported (not the user's data).
	ReplyToPostID string `json:"replyToPostId,omitempty"`
	// Kind is set only for REPOST and QUOTE docs (P5), with the id of the post they copy, so plain posts export
	// byte for byte as before. The copied text and its author are not the user's data and are not exported.
	Kind       string `json:"kind,omitempty"`
	RepostOfID string `json:"repostOfPostId,omitempty"`
	QuoteOfID  string `json:"quoteOfPostId,omitempty"`
	// The author's own disclosure labels (ADR-0021 D3); omitted when false so older exports are byte-identical.
	PaidPartnership bool `json:"paidPartnership,omitempty"`
	MadeWithAI      bool `json:"madeWithAi,omitempty"`
	// The effective reply policy of the conversation (ADR-0021 D2; a reply exports the policy it inherited); omitted when EVERYONE. Holds no user id.
	ReplyPolicy string `json:"replyPolicy,omitempty"`
	// The author's own poll (ADR-0029 D8): choices, closesAt, per-choice counts and the total; omitted for a post without a poll,
	// so plain posts export byte for byte as before. Counts are anonymous totals.
	Poll *exportedPoll `json:"poll,omitempty"`
}

// exportedPoll is a poll in the export.
type exportedPoll struct {
	Choices  []string  `json:"choices"`
	ClosesAt time.Time `json:"closesAt"`
	Counts   []int64   `json:"counts"`
	Total    int64     `json:"total"`
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
			ep := exportedPost{ID: s.Ref.ID, Text: d.Text, CreatedAt: d.CreatedAt.UTC(), Hashtags: d.Hashtags, Mentions: make([]string, 0, len(d.Mentions)), ReplyToPostID: d.ReplyToID,
				PaidPartnership: d.PaidPartnership, MadeWithAI: d.MadeWithAI, ReplyPolicy: d.ReplyPolicy}
			if po := d.Poll.toPoll(); po != nil {
				ep.Poll = &exportedPoll{Choices: po.Options, ClosesAt: po.ClosesAt, Counts: po.Counts, Total: po.Total}
			}
			if k := Kind(d.Kind); k == KindRepost || k == KindQuote {
				ep.Kind, ep.RepostOfID, ep.QuoteOfID = d.Kind, d.RepostOfID, d.QuoteOfID
			}
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
