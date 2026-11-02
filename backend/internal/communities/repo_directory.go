package communities

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ListByMemberCount implements Repo: `communities ORDER BY memberCount DESC, __name__ DESC LIMIT n` on the automatic single-field
// index (ADR-0031 D3, shape (ii), proven on dev). Charged 1 read per document, 1 for an empty result. Status is not filtered here
// (the equality plus the order would need a composite index): the caller drops non-ACTIVE rows in memory.
func (r *FirestoreRepo) ListByMemberCount(ctx context.Context, limit int) ([]Community, error) {
	if r == nil || r.client == nil {
		return nil, errors.New("communities: repo has no firestore client")
	}
	limit = min(max(limit, 1), DirectoryMax)
	snaps, err := r.col().OrderBy("memberCount", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(int64(max(len(snaps), 1)))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("communities: list directory: %w", err))
	}
	out := make([]Community, 0, len(snaps))
	for _, s := range snaps {
		var d communityDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("communities: decode community: %w", err))
		}
		out = append(out, d.community(s.Ref.ID))
	}
	return out, nil
}

// ListMembers implements Repo: one page of communities/{cid}/communityMembers ordered by joinedAt (JOINED) or bannedAt (BANNED), newest
// first, `__name__ DESC` as the tie-break (ADR-0031 D3, shape (ii)). The presence of the ordered field is the filter, so no equality
// and no composite index. Charged 1 read per document, 1 for an empty page.
func (r *FirestoreRepo) ListMembers(ctx context.Context, q MembersQuery) ([]MemberRow, error) {
	if r == nil || r.client == nil {
		return nil, errors.New("communities: repo has no firestore client")
	}
	field := "joinedAt"
	if q.Banned {
		field = "bannedAt"
	}
	query := r.ref(q.CommunityID).Collection(membersSubcollection).OrderBy(field, firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(min(max(q.Limit, 1), 50))
	if q.After != nil {
		query = query.StartAfter(q.After.CreatedAt, q.After.DocID)
	}
	snaps, err := query.Documents(ctx).GetAll()
	budget.FromContext(ctx).AddReads(int64(max(len(snaps), 1)))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("communities: list members: %w", err), q.CommunityID)
	}
	out := make([]MemberRow, 0, len(snaps))
	for _, s := range snaps {
		var d memberDoc
		if err := s.DataTo(&d); err != nil {
			return nil, logger.RedactErr(fmt.Errorf("communities: decode member: %w", err), q.CommunityID)
		}
		at := d.JoinedAt
		if q.Banned {
			at = d.BannedAt
		}
		if at == nil {
			return nil, errors.New("communities: member document without its ordered field")
		}
		out = append(out, MemberRow{UID: s.Ref.ID, At: *at})
	}
	return out, nil
}
