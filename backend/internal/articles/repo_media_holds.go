// repo_media_holds.go answers the media orphan sweep (media/orphan_sweep.go, through media.NewDraftHolds; the interface is CoverHolds in api.go): which of a
// user's images an unpublished article draft names as its cover. SaveArticle stores the id without touching the media
// document (the cover is claimed only when the article is published, inside the root post transaction), and drafts never
// expire, so the orphan sweep must count these images as held.
//
// Two queries per chunk of <= 30 ids, both served by automatic single-field indexes (articles exempts only body, title,
// caption and pendingKey; no index or override change). Cover: articles WHERE coverMediaId IN [ids]. Inline images:
// articles WHERE imageMediaIds ARRAY_CONTAINS_ANY [ids] (a Firestore query takes one in / array-contains-any, so they cannot
// share a query). Both project authorId, published and the hold field. The owner and draft filters run in memory, so
// another user's draft naming the id never counts.
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
	AuthorID      string   `firestore:"authorId"`
	Published     bool     `firestore:"published"`
	CoverMediaID  string   `firestore:"coverMediaId"`
	ImageMediaIDs []string `firestore:"imageMediaIds"`
}

// DraftCoverHolds reports which of ids an unpublished article of uid (a draft, or one whose publication is pending) names
// as its cover or as an inline image. It reads fresh: two queries per 30 ids (at least 2 reads each).
func (h *mediaHolds) DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	out := make(map[string]bool, len(ids))
	for start := 0; start < len(ids); start += coverHoldChunk {
		chunk := ids[start:min(start+coverHoldChunk, len(ids))]
		if err := h.coverHolds(ctx, uid, chunk, out); err != nil {
			return nil, err
		}
		if err := h.imageHolds(ctx, uid, chunk, out); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// coverHolds marks the chunk's ids that an unpublished draft of uid names as its cover.
func (h *mediaHolds) coverHolds(ctx context.Context, uid string, chunk []string, out map[string]bool) error {
	snaps, err := h.client.Collection("articles").Where("coverMediaId", "in", chunk).
		Select("authorId", "published", "coverMediaId").Limit(coverHoldLimit).Documents(ctx).GetAll()
	if err != nil {
		return fmt.Errorf("articles: cover holds: %w", err)
	}
	if len(snaps) == coverHoldLimit {
		for _, id := range chunk {
			out[id] = true
		}
		return nil
	}
	for _, s := range snaps {
		var d coverHoldDoc
		if err := s.DataTo(&d); err != nil {
			return fmt.Errorf("articles: cover holds: decode: %w", err)
		}
		if d.AuthorID == uid && !d.Published && d.CoverMediaID != "" {
			out[d.CoverMediaID] = true
		}
	}
	return nil
}

// imageHolds marks the chunk's ids that an unpublished draft of uid names as an inline image block.
func (h *mediaHolds) imageHolds(ctx context.Context, uid string, chunk []string, out map[string]bool) error {
	snaps, err := h.client.Collection("articles").Where("imageMediaIds", "array-contains-any", chunk).
		Select("authorId", "published", "imageMediaIds").Limit(coverHoldLimit).Documents(ctx).GetAll()
	if err != nil {
		return fmt.Errorf("articles: image holds: %w", err)
	}
	if len(snaps) == coverHoldLimit {
		for _, id := range chunk {
			out[id] = true
		}
		return nil
	}
	for _, s := range snaps {
		var d coverHoldDoc
		if err := s.DataTo(&d); err != nil {
			return fmt.Errorf("articles: image holds: decode: %w", err)
		}
		if d.AuthorID != uid || d.Published {
			continue
		}
		for _, id := range d.ImageMediaIDs {
			out[id] = true
		}
	}
	return nil
}
