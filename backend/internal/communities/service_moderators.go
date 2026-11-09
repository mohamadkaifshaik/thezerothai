package communities

import (
	"context"
	"fmt"
	"slices"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// moderatorOrder is the MODERATORS page order (F24): the owner first, then the moderators by uid. Roles live on the
// community document (ownerId, moderatorIds, at most COMMUNITY_MAX_MODERATORS), never on the member docs (D2), so the
// page needs no query and no index. The uid order (not the appointment order) keeps a page token meaningful when the
// moderator set changes between pages.
func moderatorOrder(c Community) []string {
	mods := make([]string, 0, len(c.ModeratorIDs))
	for _, id := range c.ModeratorIDs {
		if id != "" && id != c.OwnerID && !slices.Contains(mods, id) {
			mods = append(mods, id)
		}
	}
	slices.Sort(mods)
	if c.OwnerID == "" {
		return mods
	}
	return append([]string{c.OwnerID}, mods...)
}

// resumeAfter is the part of order that follows the page token's uid: after its position when it is still listed,
// otherwise (demoted, or the owner changed) the moderators with a greater uid. A nil token is the whole order.
func resumeAfter(order []string, ownerID string, after *cursor.Cursor) []string {
	if after == nil {
		return order
	}
	if i := slices.Index(order, after.DocID); i >= 0 {
		return order[i+1:]
	}
	out := make([]string, 0, len(order))
	for _, id := range order {
		if id != ownerID && id > after.DocID {
			out = append(out, id)
		}
	}
	return out
}

// moderatorRows is one MODERATORS page: the users of moderatorOrder after the token, kept when their member doc is
// JOINED (one batch read of at most 1 + COMMUNITY_MAX_MODERATORS docs), at most size of them, with since = joinedAt.
// more reports that kept rows remain past this page.
func (s *service) moderatorRows(ctx context.Context, c Community, size int, after *cursor.Cursor) (rows []MemberRow, more bool, err error) {
	cands := resumeAfter(moderatorOrder(c), c.OwnerID, after)
	if len(cands) == 0 {
		return nil, false, nil
	}
	docs, err := s.d.Repo.MembersByUID(ctx, c.ID, cands)
	if err != nil {
		return nil, false, fmt.Errorf("load moderator members: %w", err)
	}
	for _, id := range cands {
		m, ok := docs[id]
		if !ok || m.State != MemberJoined {
			continue
		}
		if len(rows) == size {
			return rows, true, nil
		}
		rows = append(rows, MemberRow{UID: id, At: m.At})
	}
	return rows, false, nil
}
