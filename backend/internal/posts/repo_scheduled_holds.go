// repo_scheduled_holds.go answers the media orphan sweep (media/orphan_sweep.go, through an apiserver adapter): which of a
// user's images a PENDING scheduled post still names. A schedule validates its images but never reserves them, so the
// images stay unattached until the publish sweep attaches them, up to SCHEDULED_HORIZON later (and an edit can move
// publish_at again); the orphan sweep must count them as held.
//
// Query: users/{uid}/scheduled WHERE status == PENDING ORDER BY __name__ ASC, projected to draft.media. Served by the
// automatic single-field index on status (the same one CountPending uses); `draft` is index-exempt, which a projection
// does not need. No index change.
package posts

import (
	"context"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// scheduledHoldPage and scheduledHoldPages bound the scan at 500 PENDING items, ten times the largest
	// SCHEDULED_MAX_PENDING (50, a soft cap). Beyond that every id is reported held.
	scheduledHoldPage  = 100
	scheduledHoldPages = 5
)

// scheduledHoldDoc is the projection the scan reads.
type scheduledHoldDoc struct {
	Draft *struct {
		Media []mediaDoc `firestore:"media"`
	} `firestore:"draft"`
}

// PendingScheduledMediaHolds reports which of ids a PENDING scheduled post of uid names in its draft. It reads fresh (no
// cache): at most scheduledHoldPages queries of scheduledHoldPage documents, one read when uid has none. When uid has
// more PENDING items than that, it cannot tell and reports every id held.
func (r *FirestoreRepo) PendingScheduledMediaHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	out := make(map[string]bool, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	col, err := r.scheduledCol(uid)
	if err != nil {
		return nil, err
	}
	want := make(map[string]bool, len(ids))
	for _, id := range ids {
		want[id] = true
	}
	var after string
	for range scheduledHoldPages {
		q := col.Where("status", "==", string(ScheduledPending)).OrderBy(firestore.DocumentID, firestore.Asc).Select("draft.media").Limit(scheduledHoldPage)
		if after != "" {
			q = q.StartAfter(after)
		}
		snaps, err := q.Documents(ctx).GetAll()
		if err != nil {
			return nil, fmt.Errorf("posts: scheduled media holds %s: %w", logger.HashUID(uid), err)
		}
		for _, s := range snaps {
			var d scheduledHoldDoc
			if err := s.DataTo(&d); err != nil {
				return nil, fmt.Errorf("posts: scheduled media holds %s: decode: %w", logger.HashUID(uid), err)
			}
			if d.Draft == nil {
				continue
			}
			for _, m := range d.Draft.Media {
				if want[m.MediaID] {
					out[m.MediaID] = true
				}
			}
		}
		if len(snaps) < scheduledHoldPage {
			return out, nil
		}
		after = snaps[len(snaps)-1].Ref.ID
	}
	for id := range want {
		out[id] = true
	}
	return out, nil
}
