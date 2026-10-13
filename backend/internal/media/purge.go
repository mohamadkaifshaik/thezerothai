// purge.go is media's right-to-delete and right-to-access path (ADR-0011): the deletion step "media" and the export
// section "media". The Eraser removes every image a user owns, whatever its state: public objects, any private
// upload leftovers and the document, objects first so a crash leaves the document to find them again.
package media

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Checkpoint resumes Eraser.PurgeUser across calls. Deleted documents drop out of the next page, so the purge is
// self-resuming and the checkpoint only carries progress for logging.
type Checkpoint struct {
	Deleted int `json:"deleted"`
}

// Purger implements the deletion step and the export section.
type Purger struct {
	repo          Repo
	objects       Objects
	publicBaseURL string
}

// NewPurger builds the Eraser/Exporter. publicBaseURL is only used to render URLs in the export.
func NewPurger(repo Repo, objects Objects, publicBaseURL string) *Purger {
	return &Purger{repo: repo, objects: objects, publicBaseURL: publicBaseURL}
}

// deleteObjects removes every object a document may own; a missing object is success.
func deleteObjects(ctx context.Context, o Objects, d *Doc) error {
	for _, p := range []string{d.PublicPath, d.ThumbPath} {
		if p == "" {
			continue
		}
		if err := o.DeletePublic(ctx, p); err != nil {
			return err
		}
	}
	for _, p := range []string{d.UploadPath, d.ThumbUploadPath} {
		if p == "" {
			continue
		}
		if err := o.DeleteUpload(ctx, p); err != nil {
			return err
		}
	}
	return nil
}

// PurgeUser deletes one page (<= opsPage) of uid's media: objects, then the documents in one batch. done is true
// when the page was short (the account is DELETING, so no new uploads arrive). Reads: one per document, minimum 1;
// deletes: one per document; GCS: free deletes, 4 per document.
func (p *Purger) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	docs, err := p.repo.ListByOwner(ctx, uid, "", opsPage)
	if err != nil {
		return cp, false, logger.RedactErr(fmt.Errorf("media: purge: %w", err), uid)
	}
	if len(docs) == 0 {
		return cp, true, nil
	}
	ids := make([]string, 0, len(docs))
	for _, d := range docs {
		if err := deleteObjects(ctx, p.objects, d); err != nil {
			return cp, false, logger.RedactErr(fmt.Errorf("media: purge objects: %w", err), uid)
		}
		ids = append(ids, d.ID)
	}
	if err := p.repo.DeleteDocs(ctx, ids); err != nil {
		return cp, false, logger.RedactErr(fmt.Errorf("media: purge docs: %w", err), uid)
	}
	next := Checkpoint{Deleted: cp.Deleted + len(docs)}
	return next, len(docs) < opsPage, nil
}

// exportedMedia is one image in the account export: what the user uploaded, never internal paths or hashes.
type exportedMedia struct {
	ID          string    `json:"id"`
	Purpose     string    `json:"purpose"`
	Status      string    `json:"status"`
	ContentType string    `json:"contentType"`
	Width       int       `json:"width"`
	Height      int       `json:"height"`
	URL         string    `json:"url,omitempty"`
	ThumbURL    string    `json:"thumbUrl,omitempty"`
	PostID      string    `json:"postId,omitempty"`
	CreatedAt   time.Time `json:"createdAt"`
}

// Name is the export section name.
func (*Purger) Name() string { return "media" }

// WriteSection streams {"media":[...]} to w in pages of opsPage (memory stays bounded). Reads: one per document,
// minimum 1.
func (p *Purger) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	if _, err := io.WriteString(w, `{"media":[`); err != nil {
		return fmt.Errorf("media: write export: %w", err)
	}
	enc := json.NewEncoder(w)
	first, after := true, ""
	for {
		docs, err := p.repo.ListByOwner(ctx, uid, after, opsPage)
		if err != nil {
			return logger.RedactErr(fmt.Errorf("media: export: %w", err), uid)
		}
		for _, d := range docs {
			e := exportedMedia{
				ID: d.ID, Purpose: d.Purpose, Status: d.Status, ContentType: d.ContentType,
				Width: d.Width, Height: d.Height, PostID: d.PostID, CreatedAt: d.CreatedAt.UTC(),
			}
			if d.Published() {
				e.URL, e.ThumbURL = p.publicBaseURL+"/"+d.PublicPath, p.publicBaseURL+"/"+d.ThumbPath
			}
			if !first {
				if _, err := io.WriteString(w, ","); err != nil {
					return fmt.Errorf("media: write export: %w", err)
				}
			}
			first = false
			if err := enc.Encode(e); err != nil {
				return fmt.Errorf("media: write export: %w", err)
			}
		}
		if len(docs) < opsPage {
			break
		}
		after = docs[len(docs)-1].ID
	}
	if _, err := io.WriteString(w, "]}\n"); err != nil {
		return fmt.Errorf("media: write export: %w", err)
	}
	return nil
}
