// repo_legacy_banner.go removes what the removed profile banner left on users/{uid}: the bannerUrl and bannerThumbUrl
// fields. userDoc no longer decodes them, and a whole-document rewrite (UpdateProfile, ChangeHandle) already drops them,
// but a profile nobody edits keeps them until `opsctl purge-banners` runs this. Account deletion deletes users/{uid}
// whole, so right-to-delete needs nothing here. Remove this file once `opsctl purge-banners` has run in every environment.
//
// Both fields are index-exempt (firebase/firestore.indexes.json), so they cannot be queried: the scan reads every users
// document in id order, projected to the two fields (one read per document), and writes only to documents that hold one.
package identity

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// legacyBannerFields are the users/{uid} fields of the removed profile banner.
var legacyBannerFields = []string{"bannerUrl", "bannerThumbUrl"}

// LegacyBannerFieldsPage is what one ClearLegacyBannerFields call scanned and, unless it was a dry run, cleared. Last is the
// id of the last document scanned ("" for an empty page), the checkpoint of the next call; Scanned < the requested limit
// means the scan is complete. Gone counts documents deleted between the read and the write (nothing to clear).
type LegacyBannerFieldsPage struct {
	Scanned int
	Found   int
	Cleared int
	Gone    int
	Last    string
}

// ClearLegacyBannerFields scans up to limit users documents after the id after and deletes bannerUrl and bannerThumbUrl
// from each one that holds either. Each write is a field-level Update (never a Set), so it cannot recreate a deleted
// account and does not touch updatedAt, snapshotVersion or any other field; a document deleted meanwhile is skipped.
// Rerunning it is harmless: a cleared document no longer matches. dryRun counts and writes nothing.
func (r *FirestoreRepo) ClearLegacyBannerFields(ctx context.Context, after string, limit int, dryRun bool) (LegacyBannerFieldsPage, error) {
	q := r.client.Collection(usersCollection).Select(legacyBannerFields...).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.userRef(after))
	}
	snaps, err := q.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return LegacyBannerFieldsPage{}, fmt.Errorf("identity: scan users for legacy banner fields: %w", err)
	}
	page := LegacyBannerFieldsPage{Scanned: len(snaps)}
	if len(snaps) > 0 {
		page.Last = snaps[len(snaps)-1].Ref.ID
	}
	for _, s := range snaps {
		if !hasLegacyBanner(s.Data()) {
			continue
		}
		page.Found++
		if dryRun {
			continue
		}
		ups := make([]firestore.Update, 0, len(legacyBannerFields))
		for _, f := range legacyBannerFields {
			ups = append(ups, firestore.Update{Path: f, Value: firestore.Delete})
		}
		if _, err := s.Ref.Update(ctx, ups); err != nil {
			if status.Code(err) == codes.NotFound {
				page.Gone++
				continue
			}
			return page, fmt.Errorf("identity: clear legacy banner fields: %w", err)
		}
		page.Cleared++
	}
	return page, nil
}

// hasLegacyBanner reports whether a projected users document holds either legacy banner field (an empty string counts:
// the field is still stored).
func hasLegacyBanner(data map[string]any) bool {
	for _, f := range legacyBannerFields {
		if _, ok := data[f]; ok {
			return true
		}
	}
	return false
}
