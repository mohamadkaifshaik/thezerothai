package communities

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// SearchByName implements Repo: `status == "ACTIVE" AND nameLower >= lo AND nameLower < hi ORDER BY nameLower, __name__`, the
// composite index communities (status ASC, nameLower ASC) (chore(firestore) gate). A SUSPENDED or ARCHIVED community is never
// read; a community without nameLower (written before the field) is not matched until the backfill.
func (r *FirestoreRepo) SearchByName(ctx context.Context, prefix string, after *NameAnchor, limit int) ([]Community, error) {
	if r == nil || r.client == nil {
		return nil, errors.New("communities: repo has no firestore client")
	}
	if prefix == "" {
		return nil, errors.New("communities: search by name needs a prefix")
	}
	lo, hi := namekey.Bounds(prefix)
	q := r.col().Where("status", "==", string(StatusActive)).Where(namekey.Field, ">=", lo).Where(namekey.Field, "<", hi).
		OrderBy(namekey.Field, firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != nil {
		q = q.StartAfter(after.NameLower, r.ref(after.CommunityID))
	}
	snaps, err := q.Limit(min(max(limit, 1), SearchPageMax)).Documents(ctx).GetAll()
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("communities: search by name: %w", err))
	}
	out := make([]Community, 0, len(snaps))
	for _, s := range snaps {
		var d communityDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("communities: decode community: %w", err), s.Ref.ID)
		}
		out = append(out, d.community(s.Ref.ID))
	}
	return out, nil
}
