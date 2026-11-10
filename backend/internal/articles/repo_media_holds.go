// repo_media_holds.go answers the media orphan sweep (media/orphan_sweep.go, through media.NewDraftHolds; the interface is CoverHolds in api.go): which of a
// user's images an unpublished article draft names as its cover. SaveArticle stores the id without touching the media
// document (the cover is claimed only when the article is published, inside the root post transaction), and drafts never
// expire, so the orphan sweep must count these images as held.
//
// Query: articles WHERE coverMediaId IN [<= 30 ids], projected to authorId, published and coverMediaId. Served by the
// automatic single-field index on coverMediaId (articles exempts only body, title, caption and pendingKey). No index
// change. The owner and draft filters run in memory, so another user's draft naming the id never counts.
package articles

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"
)

const (
	// coverHoldChunk is Firestore's limit of values in one IN filter.
	coverHoldChunk = 30
	// coverHoldLimit bounds one query; a full page means it cannot tell, and every id of the chunk is reported held.
	coverHoldLimit = 100
)

// mediaHolds implements CoverHolds (api.go).
type mediaHolds struct{ client *firestore.Client }

var _ CoverHolds = (*mediaHolds)(nil)

type coverHoldDoc struct {
	AuthorID     string `firestore:"authorId"`
	Published    bool   `firestore:"published"`
	CoverMediaID string `firestore:"coverMediaId"`
}

// DraftCoverHolds reports which of ids an unpublished article of uid (a draft, or one whose publication is pending) names
// as its cover. It reads fresh: one query per 30 ids (at least 1 read each).
func (h *mediaHolds) DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	out := make(map[string]bool, len(ids))
	for start := 0; start < len(ids); start += coverHoldChunk {
		chunk := ids[start:min(start+coverHoldChunk, len(ids))]
		snaps, err := h.client.Collection("articles").Where("coverMediaId", "in", chunk).
			Select("authorId", "published", "coverMediaId").Limit(coverHoldLimit).Documents(ctx).GetAll()
		if err != nil {
			return nil, fmt.Errorf("articles: cover holds: %w", err)
		}
		if len(snaps) == coverHoldLimit {
			for _, id := range chunk {
				out[id] = true
			}
			continue
		}
		for _, s := range snaps {
			var d coverHoldDoc
			if err := s.DataTo(&d); err != nil {
				return nil, fmt.Errorf("articles: cover holds: decode: %w", err)
			}
			if d.AuthorID == uid && !d.Published && d.CoverMediaID != "" {
				out[d.CoverMediaID] = true
			}
		}
	}
	return out, nil
}
