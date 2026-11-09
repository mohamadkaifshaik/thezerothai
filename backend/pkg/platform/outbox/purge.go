package outbox

import (
	"context"
	"fmt"
)

// purgePage is how many of a user's items one PurgeUser call deletes (one batch).
const purgePage = 500

// Checkpoint is PurgeUser's resumable state (the account-deletion step persists it as JSON).
type Checkpoint struct {
	Deleted int `json:"deleted"`
}

// PurgeUser is the right-to-delete step: it deletes up to one page of uid's items per call and reports done when fewer
// than a page were left. Dropping a user's pending items is safe because the same account deletion removes everything
// those follow-ups would have cleaned up (the user's posts, media and engagement).
func (o *Outbox) PurgeUser(ctx context.Context, uid string, cp Checkpoint) (Checkpoint, bool, error) {
	n, err := o.b.purgeUID(ctx, uid, purgePage)
	if err != nil {
		return cp, false, fmt.Errorf("outbox: purge: %w", err)
	}
	cp.Deleted += n
	return cp, n < purgePage, nil
}
