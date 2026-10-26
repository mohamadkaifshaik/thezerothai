// purge_bookmarks.go is the right-to-delete and right-to-access path of users/{uid}/bookmarks (ADR-0023 D6, D8, ticket
// W2-5). Deleting users/{uid} does not delete its subcollections, so the `bookmarks` account-deletion step
// (BookmarkEraser, registered BeforeIdentity after `scheduled`) removes the documents and clears the
// userLikes.bookmarks set, and the `bookmarks` export section lists post id and bookmark time per row.
//
// Neither is flag-gated: documents outlive the flag. A bookmarked post that is deleted, taken down or purged is not
// fanned out to its bookmarkers (D6); the owner's list hides it and prunes it lazily (W2-4).
package engagement

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// bookmarkPage is the page of the erase step and of the export (ops path, a Firestore batch holds 500 writes).
const bookmarkPage = 500

// BookmarkPurger deletes one page of a user's bookmarks.
type BookmarkPurger interface {
	// PurgeBookmarksPage deletes up to bookmarkPage (500) of uid's bookmark documents in one atomic batch and reports
	// how many. Reads: one per document (minimum 1); deletes: one per document. Deleted documents leave the next
	// page, so repeating the call is self-resuming.
	PurgeBookmarksPage(ctx context.Context, uid string) (deleted int, err error)
	// ClearBookmarkSet removes the `bookmarks` field of userLikes/{uid} with a field-level Update (never a whole-doc
	// write, and it never recreates a document the engagement step already deleted). 0 reads; 1 write, or none when
	// the document is gone.
	ClearBookmarkSet(ctx context.Context, uid string) error
}

// BookmarkExportSource pages through a user's bookmarks for the export.
type BookmarkExportSource interface {
	// ExportBookmarksPage returns uid's bookmarks strictly after `after` (nil = from the newest), newest first, at
	// most limit. Reads: len(result), minimum 1.
	ExportBookmarksPage(ctx context.Context, uid string, after *posts.Position, limit int) ([]ExportedBookmark, error)
}

var (
	_ BookmarkPurger       = (*FirestoreRepo)(nil)
	_ BookmarkExportSource = (*FirestoreRepo)(nil)
)

// ExportedBookmark is one row of the `bookmarks` export section. It never carries the bookmarked post's content,
// which belongs to another user.
type ExportedBookmark struct {
	PostID       string    `json:"postId"`
	BookmarkedAt time.Time `json:"bookmarkedAt"`
}

// PurgeBookmarksPage implements BookmarkPurger.
func (r *FirestoreRepo) PurgeBookmarksPage(ctx context.Context, uid string) (int, error) {
	col := r.client.Collection(usersCollection).Doc(uid).Collection(bookmarksCollection)
	docs, err := col.Select().Limit(bookmarkPage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return 0, fmt.Errorf("engagement: purge bookmarks %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, fmt.Errorf("engagement: purge bookmarks %s: %w", logger.HashUID(uid), err)
	}
	return len(docs), nil
}

// ClearBookmarkSet implements BookmarkPurger.
func (r *FirestoreRepo) ClearBookmarkSet(ctx context.Context, uid string) error {
	_, err := r.userLikesRef(uid).Update(ctx, []firestore.Update{{Path: "bookmarks", Value: firestore.Delete}})
	switch status.Code(err) {
	case codes.OK:
		budget.FromContext(ctx).AddWrites(1)
		return nil
	case codes.NotFound:
		return nil // the engagement step deleted userLikes already: nothing to clear, nothing recreated
	default:
		return fmt.Errorf("engagement: clear bookmark set %s: %w", logger.HashUID(uid), err)
	}
}

// ExportBookmarksPage implements BookmarkExportSource.
func (r *FirestoreRepo) ExportBookmarksPage(ctx context.Context, uid string, after *posts.Position, limit int) ([]ExportedBookmark, error) {
	col := r.client.Collection(usersCollection).Doc(uid).Collection(bookmarksCollection)
	q := col.OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, col.Doc(after.ID))
	}
	docs, err := q.Limit(min(max(limit, 1), bookmarkPage)).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, fmt.Errorf("engagement: export bookmarks %s: query: %w", logger.HashUID(uid), err)
	}
	out := make([]ExportedBookmark, 0, len(docs))
	for _, s := range docs {
		var d bookmarkDoc
		if err := s.DataTo(&d); err != nil {
			return nil, fmt.Errorf("engagement: export decode bookmark %s: %w", s.Ref.ID, err)
		}
		out = append(out, ExportedBookmark{PostID: s.Ref.ID, BookmarkedAt: d.CreatedAt.UTC()})
	}
	return out, nil
}

// BookmarkCheckpoint resumes BookmarkEraser.PurgeUser across calls. The zero value starts from the beginning. Deleted
// documents drop out of the next page, so the purge is self-resuming and the checkpoint only carries the running count
// for logging. It is the step's own type: the step name is persisted in deletionJob.step and is never folded into
// engagement's Checkpoint.
type BookmarkCheckpoint struct {
	Deleted int
}

// BookmarkEraser is the `bookmarks` account-deletion step (ADR-0023 D6): it deletes every users/{uid}/bookmarks
// document, one page of at most 500 per call, then clears userLikes.bookmarks. An account at the cap (1,000) takes 3
// invocations at most (500 + 500 + the empty page), 1,000 reads + 1,000 deletes in all.
type BookmarkEraser struct {
	repo BookmarkPurger
}

// NewBookmarkEraser builds the step on a BookmarkPurger (FirestoreRepo in production).
func NewBookmarkEraser(repo BookmarkPurger) *BookmarkEraser { return &BookmarkEraser{repo: repo} }

// PurgeUser deletes one page. done is true when the page was short, which includes the empty page of an account that
// never bookmarked anything or whose documents a previous run already deleted (idempotent re-run: 1 read, and a
// no-op Update when userLikes is gone). Reads: one per document (minimum 1); deletes: one per document; writes: 0, or
// 1 for the userLikes field clear on the last page.
func (e *BookmarkEraser) PurgeUser(ctx context.Context, uid string, cp BookmarkCheckpoint) (BookmarkCheckpoint, bool, error) {
	n, err := e.repo.PurgeBookmarksPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := BookmarkCheckpoint{Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "engagement_purge_bookmarks", "uid_hash", logger.HashUID(uid), "docs", n, "deleted_total", next.Deleted)
	}
	if n < bookmarkPage {
		if err := e.repo.ClearBookmarkSet(ctx, uid); err != nil {
			return cp, false, err
		}
		return next, true, nil
	}
	return next, false, nil
}

// BookmarkExporter writes the `bookmarks` export section.
type BookmarkExporter struct {
	src BookmarkExportSource
}

// NewBookmarkExporter builds the section on a BookmarkExportSource (FirestoreRepo in production).
func NewBookmarkExporter(src BookmarkExportSource) *BookmarkExporter {
	return &BookmarkExporter{src: src}
}

// ExportUser streams {"bookmarks":[{"postId","bookmarkedAt"}]} to w, newest first, in pages of 500 (memory stays
// bounded). Reads: one per bookmark, minimum 1; at most about 70 KB at the cap.
func (x *BookmarkExporter) ExportUser(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"bookmarks":[`); err != nil {
		return fmt.Errorf("engagement: write bookmarks export: %w", err)
	}
	enc := json.NewEncoder(w)
	first := true
	var after *posts.Position
	for {
		page, err := x.src.ExportBookmarksPage(ctx, uid, after, bookmarkPage)
		if err != nil {
			return err
		}
		for _, b := range page {
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("engagement: write bookmarks export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(b); err != nil {
				return fmt.Errorf("engagement: write bookmarks export: %w", err)
			}
		}
		if len(page) < bookmarkPage {
			break
		}
		last := page[len(page)-1]
		after = &posts.Position{CreatedAt: last.BookmarkedAt, ID: last.PostID}
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("engagement: write bookmarks export: %w", err)
	}
	return nil
}
