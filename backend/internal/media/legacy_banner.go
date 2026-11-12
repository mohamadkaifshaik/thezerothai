// legacy_banner.go erases what the removed profile banner left in the media module: media documents of the stored
// purpose "BANNER" (any status: PENDING, READY, READY_UNSCREENED, REJECTED, retired, orphan-marked or claimed) and every
// object such a document may own (the public full image and thumbnail in both name shapes, and the private upload
// leftovers). It is driven by `opsctl purge-banners` only; nothing in the API calls it.
//
// Until that command has run in a project, the account eraser (Purger.PurgeUser) still erases a legacy banner: it
// deletes every document an owner has whatever its purpose, so right-to-delete needs no banner branch. Remove this file
// (and the opsctl command) once `opsctl purge-banners` has run in every environment.
//
// Cost per page (limit n): one equality query on purpose (the automatic single-field index; media/purpose has no index
// exemption) ordered by document id, n reads; up to 6 free GCS deletes per document; one batch of n deletes. A dry run
// reads the same and writes nothing.
package media

import (
	"context"
	"fmt"
)

// LegacyBannerPurpose is the stored purpose of the removed profile banner (MEDIA_PURPOSE_BANNER = 3, now reserved).
const LegacyBannerPurpose = "BANNER"

// LegacyBannerPage is what one PurgeLegacyBanners call found and, unless it was a dry run, erased. Last is the id of the
// last document of the page ("" when the page was empty): the checkpoint a dry run pages with. Found < the requested
// limit means the scan is complete.
type LegacyBannerPage struct {
	Found   int
	Deleted int
	Last    string
}

// legacyBannerRepo is the slice of *FirestoreRepo the purge needs (a seam for the unit tests).
type legacyBannerRepo interface {
	ListLegacyBanners(ctx context.Context, after string, limit int) ([]*Doc, error)
	DeleteDocs(ctx context.Context, ids []string) error
}

// LegacyBannerPurger erases legacy banner documents and their objects, one page per call.
type LegacyBannerPurger struct {
	repo    legacyBannerRepo
	objects Objects
}

// NewLegacyBannerPurger wires the purge over the media repo and the two buckets.
func NewLegacyBannerPurger(repo *FirestoreRepo, objects Objects) *LegacyBannerPurger {
	return &LegacyBannerPurger{repo: repo, objects: objects}
}

// ListLegacyBanners returns up to limit media documents of purpose BANNER after the document id after, in id order.
func (r *FirestoreRepo) ListLegacyBanners(ctx context.Context, after string, limit int) ([]*Doc, error) {
	return r.listWhere(ctx, "purpose", LegacyBannerPurpose, after, limit, "list legacy banners")
}

// PurgeLegacyBanners handles one page of up to limit legacy banner documents after the id after. It deletes every object
// each document may own first (a missing object is success) and then the documents in one batch, so a crash in between
// leaves documents that the next run finds again: the call is idempotent and a rerun finishes the job. dryRun lists the
// page and deletes nothing. A document of another purpose is never touched (the query filters on the purpose, and the
// purpose is checked again here).
func (p *LegacyBannerPurger) PurgeLegacyBanners(ctx context.Context, after string, limit int, dryRun bool) (LegacyBannerPage, error) {
	docs, err := p.repo.ListLegacyBanners(ctx, after, limit)
	if err != nil {
		return LegacyBannerPage{}, err
	}
	page := LegacyBannerPage{Found: len(docs)}
	if len(docs) == 0 {
		return page, nil
	}
	page.Last = docs[len(docs)-1].ID
	if dryRun {
		return page, nil
	}
	ids := make([]string, 0, len(docs))
	for _, d := range docs {
		if d.Purpose != LegacyBannerPurpose {
			continue
		}
		if err := deleteObjects(ctx, p.objects, d); err != nil {
			return page, fmt.Errorf("media: purge legacy banner %s objects: %w", d.ID, err)
		}
		ids = append(ids, d.ID)
	}
	if err := p.repo.DeleteDocs(ctx, ids); err != nil {
		return page, fmt.Errorf("media: purge legacy banner documents: %w", err)
	}
	page.Deleted = len(ids)
	return page, nil
}
