package graph

import (
	"context"
	"fmt"
	"strings"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ListFollowers (ADR-0008 T10): who follows targetUID, newest first. Firestore: reads 2 (caller graph +
// target profile, both cache-first) + <= page_size edges + <= page_size profiles (one GetAll) = 102 worst at
// page_size 50, 42 cold at 20; writes 0.
func (s *service) ListFollowers(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	return s.listFollowEdges(ctx, callerUID, targetUID, pageSize, pageToken, true)
}

// ListFollowing (ADR-0008 T10): whom targetUID follows, newest first. Same budget as ListFollowers.
func (s *service) ListFollowing(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string) (Page, error) {
	return s.listFollowEdges(ctx, callerUID, targetUID, pageSize, pageToken, false)
}

func (s *service) listFollowEdges(ctx context.Context, callerUID, targetUID string, pageSize int32, pageToken string, followers bool) (_ Page, err error) {
	op := "list_following"
	if followers {
		op = "list_followers"
	}
	defer begin(ctx, op)(&err)
	if err := s.checkFlag(callerUID); err != nil {
		return Page{}, err
	}
	if targetUserIDIssue(targetUID) {
		return Page{}, apierr.Validation("user_id", "user_id must be 1-128 characters of [A-Za-z0-9_-] and not of the form __x__")
	}
	after, err := s.decodeEdgeCursor(callerUID, pageToken, targetUID, followers)
	if err != nil {
		return Page{}, err
	}

	// Target visibility: a target that is missing, not ACTIVE, or has blocked the caller is NOT_FOUND, the
	// same error GetProfile returns (ADR-0008 D9). Checked before the edge query so a hidden target costs
	// no edge reads. IsBlockedBy is cache-first and applies the D2 overflow fallback.
	blockedBy, err := s.IsBlockedBy(ctx, callerUID, targetUID)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list edges: %w", err), callerUID, targetUID)
	}
	if blockedBy {
		return Page{}, notFoundErr()
	}
	targets, err := s.directory.GetProfiles(ctx, []string{targetUID})
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list edges: target: %w", err), callerUID, targetUID)
	}
	if _, ok := targets[targetUID]; !ok {
		return Page{}, notFoundErr()
	}
	snap, err := s.Snapshot(ctx, callerUID)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list edges: %w", err), callerUID, targetUID)
	}

	size := limits.ClampPageSize(pageSize)
	edges, err := s.repo.ListEdges(ctx, EdgeQuery{UID: targetUID, Followers: followers, Limit: size, After: after})
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list edges: %w", err), callerUID, targetUID)
	}
	// ADR-0008 "List paging": Limit(page_size), not +1 - a token is issued whenever the query returned a
	// full page (one empty final call when the total is an exact multiple of the page size).
	hasMore := len(edges) == size
	if len(edges) == 0 {
		return Page{}, nil
	}

	ids := make([]string, len(edges))
	for i, e := range edges {
		ids[i] = e.otherUID(followers)
	}
	profiles, err := s.directory.GetProfiles(ctx, ids)
	if err != nil {
		return Page{}, logger.RedactErr(fmt.Errorf("graph: list edges: hydrate: %w", err), append([]string{callerUID, targetUID}, ids...)...)
	}

	page := Page{}
	for i, e := range edges {
		uid := ids[i]
		p, ok := profiles[uid]
		// Rows for deleted/inactive users, and for anyone in a block relationship with the caller in
		// either direction, are dropped: the page may come back short and the client follows
		// next_page_token (ADR-0008 T10).
		if !ok || snap.isBlockedBy(uid) || snap.isBlocked(uid) {
			continue
		}
		page.Items = append(page.Items, ListItem{User: p, Since: e.CreatedAt, Relationship: relationshipFor(snap, uid)})
	}
	if hasMore {
		last := edges[len(edges)-1]
		page.NextPageToken = cursor.Encode(s.cursorKey, edgeCursorBinding(callerUID, targetUID, followers), cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.DocID})
	}
	return page, nil
}

// edgeCursorBinding ties a page token to (caller, list kind, target) via the AEAD additional data (security
// review M1): a token issued to one caller, or for another user's list, fails to open for anyone else.
func edgeCursorBinding(callerUID, targetUID string, followers bool) string {
	kind := "following"
	if followers {
		kind = "followers"
	}
	return callerUID + "|" + kind + "|" + targetUID
}

// decodeEdgeCursor verifies the token and that its doc id belongs to this list (a followers token replayed
// against following, or another user's list, is rejected rather than silently skipping rows).
func (s *service) decodeEdgeCursor(callerUID, token, targetUID string, followers bool) (*cursor.Cursor, error) {
	cur, err := cursor.Decode(s.cursorKey, edgeCursorBinding(callerUID, targetUID, followers), token)
	if err != nil {
		return nil, apierr.Validation("page_token", "invalid page_token")
	}
	if cursor.IsFirstPage(cur) {
		return nil, nil
	}
	ok := strings.HasPrefix(cur.DocID, targetUID+"_")
	if followers {
		ok = strings.HasSuffix(cur.DocID, "_"+targetUID)
	}
	if !ok {
		return nil, apierr.Validation("page_token", "invalid page_token")
	}
	return &cur, nil
}
