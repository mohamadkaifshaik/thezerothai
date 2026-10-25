// scheduled_purge.go is the right-to-delete and right-to-access path of users/{uid}/scheduled (ADR-0021 "Right to
// delete"). Deleting users/{uid} does not delete its subcollections, so the `scheduled` account-deletion step
// (ScheduledEraser, registered BeforeIdentity after the existing steps) removes the documents, and the `scheduled`
// export section lists every document with the draft wherever one is still held (only PENDING items hold one: FAILED clears it).
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

// ScheduledPurger deletes one page of a user's scheduled documents.
type ScheduledPurger interface {
	// PurgeScheduledPage deletes up to opsPage (500) of uid's scheduled documents in one atomic batch and reports how
	// many. Reads: one per document (minimum 1); deletes: one per document. Deleted documents leave the next page,
	// so repeating the call is self-resuming.
	PurgeScheduledPage(ctx context.Context, uid string) (deleted int, err error)
}

// ScheduledExportSource pages through a user's scheduled documents for the export.
type ScheduledExportSource interface {
	// ExportScheduledPage returns uid's documents (every status) strictly after `after` (nil = from the start),
	// ordered by publishAt then id, at most limit. Reads: len(result), minimum 1.
	ExportScheduledPage(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error)
}

// PurgeScheduledPage implements ScheduledPurger.
func (r *FirestoreRepo) PurgeScheduledPage(ctx context.Context, uid string) (int, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return 0, err
	}
	docs, err := col.Select().Limit(opsPage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return 0, fmt.Errorf("posts: purge scheduled %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, fmt.Errorf("posts: purge scheduled %s: %w", logger.HashUID(uid), err)
	}
	return len(docs), nil
}

// ExportScheduledPage implements ScheduledExportSource.
func (r *FirestoreRepo) ExportScheduledPage(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error) {
	col, err := r.scheduledCol(uid)
	if err != nil {
		return nil, err
	}
	q := col.OrderBy("publishAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, col.Doc(after.ID))
	}
	docs, err := q.Limit(min(max(limit, 1), opsPage)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, fmt.Errorf("posts: export scheduled %s: query: %w", logger.HashUID(uid), err)
	}
	return decodeScheduledAll(docs, uid)
}

// ScheduledCheckpoint resumes ScheduledEraser.PurgeUser across calls. The zero value starts from the beginning.
// Deleted documents drop out of the next page, so the purge is self-resuming and the checkpoint only carries the
// running count for logging.
type ScheduledCheckpoint struct {
	Deleted int
}

// ScheduledEraser is the `scheduled` account-deletion step (ADR-0021): it deletes every users/{uid}/scheduled
// document, one page of at most 500 per call. Normally a handful (at most 25 pending plus seven days of finished
// items).
type ScheduledEraser struct {
	repo ScheduledPurger
}

// NewScheduledEraser builds the step on a ScheduledPurger (FirestoreRepo in production).
func NewScheduledEraser(repo ScheduledPurger) *ScheduledEraser { return &ScheduledEraser{repo: repo} }

// PurgeUser deletes one page. done is true when the page was short, which includes the empty page of an account
// that never scheduled anything (1 read). Reads: one per document (minimum 1); deletes: one per document.
func (e *ScheduledEraser) PurgeUser(ctx context.Context, uid string, cp ScheduledCheckpoint) (ScheduledCheckpoint, bool, error) {
	n, err := e.repo.PurgeScheduledPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := ScheduledCheckpoint{Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "posts_purge_scheduled", "uid_hash", logger.HashUID(uid), "docs", n, "deleted_total", next.Deleted)
	}
	return next, n < opsPage, nil
}

// exportedScheduled is one scheduled document in the manual export. The draft appears only while the document still
// holds one (only PENDING); the requestHash and the attempts counter are operational and not exported.
type exportedScheduled struct {
	ID        string         `json:"id"`
	Status    string         `json:"status"`
	PublishAt time.Time      `json:"publishAt"`
	PostID    string         `json:"postId,omitempty"`
	Failure   string         `json:"failure,omitempty"`
	CreatedAt time.Time      `json:"createdAt"`
	UpdatedAt time.Time      `json:"updatedAt"`
	Draft     *exportedDraft `json:"draft,omitempty"`
}

type exportedDraft struct {
	Text            string               `json:"text"`
	Media           []exportedDraftMedia `json:"media,omitempty"`
	ReplyPolicy     string               `json:"replyPolicy,omitempty"`
	PaidPartnership bool                 `json:"paidPartnership,omitempty"`
	MadeWithAI      bool                 `json:"madeWithAi,omitempty"`
}

type exportedDraftMedia struct {
	MediaID string `json:"mediaId"`
	AltText string `json:"altText,omitempty"`
}

// ScheduledExporter writes the `scheduled` export section.
type ScheduledExporter struct {
	src ScheduledExportSource
}

// NewScheduledExporter builds the section on a ScheduledExportSource (FirestoreRepo in production).
func NewScheduledExporter(src ScheduledExportSource) *ScheduledExporter {
	return &ScheduledExporter{src: src}
}

// ExportUser streams {"userId": ..., "scheduled": [...]} to w, oldest publishAt first, in pages of opsPage (memory
// stays bounded). It lists every document, with the draft where one is held. Reads: one per document, minimum 1.
func (x *ScheduledExporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := fmt.Fprintf(w, `{"userId":%q,"scheduled":[`, uid); err != nil {
		return fmt.Errorf("posts: write scheduled export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	var after *Position
	for {
		page, err := x.src.ExportScheduledPage(ctx, uid, after, opsPage)
		if err != nil {
			return err
		}
		for _, p := range page {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("posts: write scheduled export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(toExportedScheduled(p)); err != nil {
				return fmt.Errorf("posts: write scheduled export: %w", err)
			}
		}
		if len(page) < opsPage {
			break
		}
		last := page[len(page)-1]
		after = &Position{CreatedAt: last.PublishAt, ID: last.ID}
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("posts: write scheduled export: %w", err)
	}
	return nil
}

func toExportedScheduled(p *ScheduledPost) exportedScheduled {
	e := exportedScheduled{
		ID: p.ID, Status: string(p.Status), PublishAt: p.PublishAt.UTC(), PostID: p.PostID, Failure: string(p.Failure),
		CreatedAt: p.CreatedAt.UTC(), UpdatedAt: p.UpdatedAt.UTC(),
	}
	if d := p.Draft; d != nil {
		e.Draft = &exportedDraft{Text: d.Text, ReplyPolicy: string(d.ReplyPolicy), PaidPartnership: d.PaidPartnership, MadeWithAI: d.MadeWithAI}
		for _, m := range d.Media {
			e.Draft.Media = append(e.Draft.Media, exportedDraftMedia{MediaID: m.ID, AltText: m.AltText})
		}
	}
	return e
}
