// purge_impressions.go is the right-to-delete path of users/{uid}/impressions (F1 post views). Deleting users/{uid} does
// not delete its subcollections, and the 48 h TTL is too late to count as erasure, so the `impressions` account-deletion
// step (ImpressionEraser, registered BeforeIdentity last) deletes the documents page by page. The counted views stay in
// the posts' shard counters: a count carries no viewer, so nothing personal is left behind. There is no export section:
// an impression is a short-lived dedupe record (post id and IST day, 48 h TTL), not content the user made.
//
// Not flag-gated: documents outlive the flag.
package engagement

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// impressionPage is the page of the erase step (ops path; a Firestore batch holds 500 writes).
const impressionPage = 500

// ImpressionPurger deletes one page of a user's impression docs.
type ImpressionPurger interface {
	// PurgeImpressionsPage deletes up to impressionPage of uid's impression docs (Q-I1) in one batch and reports how many.
	// Reads: one per document (minimum 1). Deleted documents leave the next page, so repeating the call is self-resuming.
	PurgeImpressionsPage(ctx context.Context, uid string) (deleted int, err error)
}

var _ ImpressionPurger = (*FirestoreRepo)(nil)

// PurgeImpressionsPage implements ImpressionPurger.
func (r *FirestoreRepo) PurgeImpressionsPage(ctx context.Context, uid string) (int, error) {
	col := r.client.Collection(usersCollection).Doc(uid).Collection(ImpressionsSubcollection)
	docs, err := col.Select().Limit(impressionPage).Documents(ctx).GetAll()
	if err != nil {
		return 0, fmt.Errorf("engagement: purge impressions %s: query: %w", logger.HashUID(uid), err)
	}
	if len(docs) == 0 {
		return 0, nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if err := b.Commit(ctx); err != nil {
		return 0, logger.RedactErr(fmt.Errorf("engagement: purge impressions %s: %w", logger.HashUID(uid), err), uid)
	}
	return len(docs), nil
}

// ImpressionCheckpoint resumes ImpressionEraser.PurgeUser; it only carries the running count (the purge is
// self-resuming). It is the step's own type: the step name is persisted in deletionJob.step.
type ImpressionCheckpoint struct {
	Deleted int
}

// ImpressionEraser is the `impressions` account-deletion step.
type ImpressionEraser struct {
	repo ImpressionPurger
}

// NewImpressionEraser builds the step on an ImpressionPurger (FirestoreRepo in production).
func NewImpressionEraser(repo ImpressionPurger) *ImpressionEraser {
	return &ImpressionEraser{repo: repo}
}

// PurgeUser deletes one page; done is true on a short page (including the empty page of an account with none).
func (e *ImpressionEraser) PurgeUser(ctx context.Context, uid string, cp ImpressionCheckpoint) (ImpressionCheckpoint, bool, error) {
	n, err := e.repo.PurgeImpressionsPage(ctx, uid)
	if err != nil {
		return cp, false, err
	}
	next := ImpressionCheckpoint{Deleted: cp.Deleted + n}
	if n > 0 {
		slog.InfoContext(ctx, "engagement_purge_impressions", "uid_hash", logger.HashUID(uid), "docs", n, "deleted_total", next.Deleted)
	}
	return next, n < impressionPage, nil
}
