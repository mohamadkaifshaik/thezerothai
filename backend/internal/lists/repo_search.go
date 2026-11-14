package lists

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// SearchByName implements Repo: `isPrivate == false AND nameLower >= lo AND nameLower < hi ORDER BY nameLower, __name__`, the
// composite index lists (isPrivate ASC, nameLower ASC) (chore(firestore) gate). A private list is never read. Hidden lists,
// owner status and blocks are the service's (resolveList). A list without nameLower (written before the field) is not matched.
func (r *FirestoreRepo) SearchByName(ctx context.Context, prefix string, after *NameAnchor, limit int) ([]List, error) {
	if err := r.readable(); err != nil {
		return nil, err
	}
	if prefix == "" {
		return nil, errors.New("lists: search by name needs a prefix")
	}
	lo, hi := namekey.Bounds(prefix)
	q := r.col().Where("isPrivate", "==", false).Where(namekey.Field, ">=", lo).Where(namekey.Field, "<", hi).
		OrderBy(namekey.Field, firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.NameLower, r.ref(after.ListID))
	}
	docs, err := q.Limit(min(max(limit, 1), SearchPageMax)).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("lists: search by name: %w", err)
	}
	out := make([]List, 0, len(docs))
	for _, s := range docs {
		var d listDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("lists: decode list: %w", err), s.Ref.ID)
		}
		out = append(out, d.list(s.Ref.ID))
	}
	return out, nil
}
