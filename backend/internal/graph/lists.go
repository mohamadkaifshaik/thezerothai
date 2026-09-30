package graph

import (
	"context"
	"fmt"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// GetRelationships (ADR-0008 T9/D4): the caller's relationship to 1-50 users, computed from the caller's
// cached Snapshot only — never from the targets' graphs, so a user who blocked the caller looks exactly like
// a stranger. Duplicates collapse (first occurrence wins) and request order is preserved.
// Firestore: reads 1 (0 on a cache hit), writes 0.
func (s *service) GetRelationships(ctx context.Context, callerUID string, targetUIDs []string) ([]Relationship, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return nil, err
	}
	if field, reason := relationshipIDsIssue(targetUIDs); field != "" {
		return nil, apierr.Validation(field, reason)
	}
	snap, err := s.Snapshot(ctx, callerUID)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("graph: get relationships: %w", err), callerUID)
	}
	seen := make(map[string]struct{}, len(targetUIDs))
	out := make([]Relationship, 0, len(targetUIDs))
	for _, uid := range targetUIDs {
		if _, dup := seen[uid]; dup {
			continue
		}
		seen[uid] = struct{}{}
		if uid == callerUID {
			out = append(out, Relationship{UserID: uid, FollowState: FollowStateNone})
			continue
		}
		out = append(out, relationshipFor(snap, uid))
	}
	return out, nil
}

// ListBlockedUsers (ADR-0008 T9): the caller's own blocked[] array, newest first, hydrated through
// identity.Directory. Firestore: reads 1 + <= page_size (50 max) via one batched GetAll, writes 0.
func (s *service) ListBlockedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	return s.listOwnArray(ctx, callerUID, "blocked", pageSize, pageToken, func(l Lists) []string { return l.Blocked })
}

// ListMutedUsers (ADR-0008 T9): as ListBlockedUsers, over muted[]. Reads 1 + <= page_size, writes 0.
func (s *service) ListMutedUsers(ctx context.Context, callerUID string, pageSize int32, pageToken string) (Page, error) {
	return s.listOwnArray(ctx, callerUID, "muted", pageSize, pageToken, func(l Lists) []string { return l.Muted })
}

func (s *service) listOwnArray(ctx context.Context, callerUID, kind string, pageSize int32, pageToken string, pick func(Lists) []string) (Page, error) {
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	cur, err := cursor.Decode(s.cursorKey, ownArrayBinding(callerUID, kind), pageToken)
	if err != nil {
		return Page{}, apierr.Validation("page_token", "invalid page_token")
	}

	// A fresh read (not the 60s cache): the array's order is not part of Snapshot, and a user editing their
	// own list expects to see it. The read also refreshes the cached Snapshot for free.
	lists, err := s.repo.GetLists(ctx, callerUID)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list own array: %w", err), callerUID)
	}
	s.cache.Set(callerUID, lists.Snapshot)
	arr := pick(lists)

	uids, hasMore, lastIdx := pageNewestFirst(arr, cur, limits.ClampPageSize(pageSize))
	page := Page{}
	// ADR-0008 D9 (own lists): users in caller.blockedBy are hidden, otherwise showing them here while
	// GetProfile says NOT_FOUND would reveal that they blocked the caller. Filtered before hydration so
	// they cost no reads. The entry stays in the array and reappears when that user unblocks.
	visible := uids[:0:0]
	for _, uid := range uids {
		if !lists.Snapshot.isBlockedBy(uid) {
			visible = append(visible, uid)
		}
	}
	if len(visible) == 0 {
		if hasMore {
			page.NextPageToken = s.ownArrayToken(callerUID, kind, arr, lastIdx)
		}
		return page, nil
	}
	profiles, err := s.directory.GetProfiles(ctx, visible)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list own array: hydrate: %w", err), append([]string{callerUID}, visible...)...)
	}
	for _, uid := range visible {
		p, ok := profiles[uid]
		if !ok {
			// Deleted or inactive: dropped from the page. Stale entries left behind (muted[] of a purged
			// user) are harmless; see ADR-0008 D10 / T11 notes.
			continue
		}
		page.Items = append(page.Items, ListItem{User: p, Relationship: relationshipFor(lists.Snapshot, uid)})
	}
	if hasMore {
		page.NextPageToken = s.ownArrayToken(callerUID, kind, arr, lastIdx)
	}
	return page, nil
}

// ownArrayBinding ties an own-list page token to the caller and the list (T16b D-5, security review M1): a
// blocked-list token can't be replayed against the muted list, or presented by another user.
func ownArrayBinding(callerUID, kind string) string { return callerUID + "|own-" + kind }

func (s *service) ownArrayToken(callerUID, kind string, arr []string, lastIdx int) string {
	return cursor.Encode(s.cursorKey, ownArrayBinding(callerUID, kind), cursor.Cursor{CreatedAt: time.UnixMicro(int64(lastIdx)).UTC(), DocID: arr[lastIdx]})
}

// pageNewestFirst walks arr (insertion order, oldest first) from the newest end. The cursor records the
// last-returned uid and its array index (in CreatedAt's micros, since these arrays have no timestamps):
// resume just below that uid's current index, or — if it was removed meanwhile — just below the recorded
// index (ADR-0008 T9). Returns the uids for this page, whether older entries remain, and the index of the
// last uid returned.
func pageNewestFirst(arr []string, cur cursor.Cursor, limit int) (uids []string, hasMore bool, lastIdx int) {
	start := len(arr) - 1
	if !cursor.IsFirstPage(cur) {
		idx := -1
		for i, v := range arr {
			if v == cur.DocID {
				idx = i
				break
			}
		}
		if idx < 0 {
			idx = int(cur.CreatedAt.UnixMicro())
			if idx > len(arr) {
				idx = len(arr)
			}
		}
		start = idx - 1
	}
	i := start
	for ; i >= 0 && len(uids) < limit; i-- {
		uids = append(uids, arr[i])
		lastIdx = i
	}
	return uids, i >= 0, lastIdx
}
