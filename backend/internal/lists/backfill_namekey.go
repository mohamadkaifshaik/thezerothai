package lists

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// BackfillNameKeys is one page of the nameLower backfill (opsctl search backfill-name-keys --collection lists): the lists after
// document id `after` in id order, at most limit (clamped to 1..namekey.MaxBackfillPage). A list whose nameLower is missing or
// is not namekey.Fold(name) is Stale; with write it is rewritten by a field-level Update (never a Set, so a deleted list stays
// deleted) with a LastUpdateTime precondition, so a rename that landed after the read keeps its own key (Skipped). Private
// lists get the key too (a later switch to public needs no backfill). Idempotent: a second run finds nothing stale.
func (r *FirestoreRepo) BackfillNameKeys(ctx context.Context, after string, limit int, write bool) (namekey.BackfillPage, error) {
	if r == nil || r.client == nil {
		return namekey.BackfillPage{}, errors.New("lists: repo has no firestore client")
	}
	n := min(max(limit, 1), namekey.MaxBackfillPage)
	q := r.col().OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.ref(after))
	}
	docs, err := q.Limit(n).Documents(ctx).GetAll()
	if err != nil {
		return namekey.BackfillPage{}, fmt.Errorf("lists: backfill name keys: %w", err)
	}
	page := namekey.BackfillPage{Scanned: len(docs), Done: len(docs) < n}
	for _, s := range docs {
		page.Last = s.Ref.ID
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return page, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), s.Ref.ID)
		}
		if !namekey.Stale(d.NameLower, d.Name) {
			continue
		}
		page.Stale++
		if !write {
			continue
		}
		_, err := s.Ref.Update(ctx, []firestore.Update{{Path: namekey.Field, Value: namekey.Fold(d.Name)}}, firestore.LastUpdateTime(s.UpdateTime))
		switch {
		case err == nil:
			page.Written++
		case status.Code(err) == codes.FailedPrecondition || status.Code(err) == codes.NotFound:
			page.Skipped++ // renamed or deleted since the read: its own write is authoritative
		default:
			return page, logger.RedactErr(fmt.Errorf("lists: backfill name key: %w", err), s.Ref.ID)
		}
	}
	return page, nil
}
