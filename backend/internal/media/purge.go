// purge.go is media's right-to-delete and right-to-access path (ADR-0011): the deletion step "media" and the export
// section "media". The Eraser removes every image a user owns, whatever its state: public objects, any private
// upload leftovers and the document, objects first so a crash leaves the document to find them again.
package media

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"slices"
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

// publicNames returns every public object name a document may own in its own shape (suffixed when it has a
// nameSuffix, W3-39): the recorded paths plus the
// deterministic names for the document's own content type (the extension is fixed at upload init, so the other
// extension can never exist). A finalize that copied the objects and then lost the race to record the paths (or was REJECTED
// after the copy) leaves public objects the document does not name (CLAUDE.md rule 10). Deduplicated, so a
// READY document is 2 names.
func publicNames(d *Doc) []string {
	var out []string
	seen := map[string]bool{}
	add := func(p string) {
		if p != "" && !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	add(d.PublicPath)
	add(d.ThumbPath)
	add(publicObject(d.ID, d.NameSuffix, extension(d.ContentType)))
	add(publicThumbObject(d.ID, d.NameSuffix, extension(d.ThumbType())))
	return out
}

// allPublicNames is publicNames plus, for a document with a nameSuffix, the pre-W3-39 pair too: a suffixed document
// finalized by an older revision (a rollback) published under the old names and may have lost the race to record
// them. Only the deleters use it (deletes are free); the retire step tags publicNames, so it stays at 2 Class A per
// image. A document without nameSuffix has the one (old) pair.
func allPublicNames(d *Doc) []string {
	out := publicNames(d)
	if d.NameSuffix == "" {
		return out
	}
	for _, p := range []string{publicObject(d.ID, "", extension(d.ContentType)), publicThumbObject(d.ID, "", extension(d.ThumbType()))} {
		if !slices.Contains(out, p) {
			out = append(out, p)
		}
	}
	return out
}

// deleteObjects removes every object a document may own; a missing object is success (free operations).
func deleteObjects(ctx context.Context, o Objects, d *Doc) error {
	for _, p := range allPublicNames(d) {
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

// PurgeUser deletes one page (<= opsPage) of uid's media: objects, then the documents in one batch. It deletes every
// document the owner has, whatever its state, retired AVATAR and BANNER documents included: until its TTL a retired
// document still names the image (ADR-0024 Amendment 1 A4), so an account deleted during the grace loses the objects
// at once. done is true when the page was short (the account is DELETING, so no new uploads arrive). Reads: one per
// document, minimum 1; deletes: one per document; GCS: free deletes, 2 public (deterministic names; 4 for a
// suffixed document, both shapes) + up to 2 private per document.
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
	// RetiredAt is set for a replaced or removed profile image whose public objects are scheduled for deletion
	// (ADR-0024 Amendment 1 A4); the document stays in the export until its TTL.
	RetiredAt *time.Time `json:"retiredAt,omitempty"`
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
			if d.RetiredAt != nil {
				r := d.RetiredAt.UTC()
				e.RetiredAt = &r
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
