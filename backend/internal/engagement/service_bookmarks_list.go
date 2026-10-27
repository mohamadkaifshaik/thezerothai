// service_bookmarks_list.go is the business logic of ListBookmarks (ADR-0023 D2, D6, ticket W2-4). A page is the
// caller's own bookmark docs (a thin {createdAt} row each), the live posts they name in ONE cache-first GetMany, the
// ADR-0010 D6 Home-column drop rules (list_common.go, shared with ListLikedPosts), the viewer state of what is left, and
// the lazy prune of rows whose post is gone. Nothing of other users' content is stored here, and nothing is cached for
// the list itself.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// bookmarkPruneTimeout bounds the best-effort prune batch so a slow write cannot eat the rest of the RPC deadline.
const bookmarkPruneTimeout = 3 * time.Second

// ListBookmarks implements Bookmarks.
func (m *Module) ListBookmarks(ctx context.Context, uid string, pageSize int32, pageToken string) (BookmarkPage, error) {
	return m.s.listBookmarks(ctx, uid, pageSize, pageToken)
}

// bookmarksBinding ties a ListBookmarks page token to its list and caller: a token issued to one user, or for another
// kind of list, opens nothing else (ADR-0023 D2).
func bookmarksBinding(uid string) string { return listBinding("bookmarks", uid) }

// decodeBookmarkToken opens token for uid, bound to bookmarks|<uid> with the cursor package's 24 h TTL. An empty token
// is the first page (nil position); a foreign, expired, tampered or malformed one is errListToken. Pure: 0 reads.
func (s *service) decodeBookmarkToken(uid, token string) (*posts.Position, error) {
	if token == "" {
		return nil, nil
	}
	cur, err := s.openListToken(bookmarksBinding(uid), token)
	if err != nil || !ids.ValidPostID(cur.DocID) {
		return nil, errListToken
	}
	return &posts.Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}, nil
}

// listBookmarks implements Bookmarks.ListBookmarks. Reads, in this order and each only when needed: the page query
// (1 + len; an empty list stops here), GetMany (the misses of the instance post cache), the caller's graph snapshot
// (1, cached 60 s, skipped when every live row is the caller's own), userLikes through posts.HydrateViewer (1, cached
// 60 s, skipped when no row is left). The next token is sealed from the last QUERIED row, kept or dropped, and issued
// whenever the query was full (a short page is the last one), so a page never pays for a look-ahead read.
func (s *service) listBookmarks(ctx context.Context, uid string, pageSize int32, token string) (_ BookmarkPage, err error) {
	logger.SetRequestField(ctx, fieldOp, "list_bookmarks")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	repo, err := s.bookmarkRepoOrErr(uid)
	if err != nil {
		return BookmarkPage{}, err
	}
	if len(s.d.CursorKey) == 0 || s.d.Graph == nil {
		return BookmarkPage{}, logger.RedactErr(errors.New("engagement: bookmark list is not wired (no CursorKey or Graph)"), uid)
	}
	after, err := s.decodeBookmarkToken(uid, token)
	if err != nil {
		return BookmarkPage{}, apierr.Validation("page_token", "page_token is invalid or expired")
	}
	limit := limits.ClampPageSize(pageSize)
	rows, err := repo.ListPage(ctx, uid, after, limit)
	if err != nil {
		return BookmarkPage{}, logger.RedactErr(fmt.Errorf("engagement: list bookmarks: %w", err), uid, afterID(after))
	}
	var page BookmarkPage
	if len(rows) >= limit {
		last := rows[len(rows)-1]
		page.NextPageToken = cursor.EncodeAt(s.d.CursorKey, bookmarksBinding(uid), cursor.Cursor{CreatedAt: last.BookmarkedAt, DocID: last.PostID}, s.now())
	}
	if len(rows) == 0 {
		s.noteList(ctx, dropTally{}, 0, 0)
		return page, nil
	}
	postIDs := make([]string, len(rows))
	for i, r := range rows {
		postIDs[i] = r.PostID
	}
	live, err := s.d.Reader.GetMany(ctx, postIDs)
	if err != nil {
		return BookmarkPage{}, logger.RedactErr(fmt.Errorf("engagement: list bookmarks: load posts: %w", err), append([]string{uid}, postIDs...)...)
	}
	res, err := s.dropRows(ctx, uid, postIDs, live)
	if err != nil {
		return BookmarkPage{}, logger.RedactErr(fmt.Errorf("engagement: list bookmarks: %w", err), uid)
	}
	for _, i := range res.Kept {
		page.Rows = append(page.Rows, BookmarkRow{Post: live[postIDs[i]], BookmarkedAt: rows[i].BookmarkedAt})
	}
	if len(page.Rows) > 0 {
		page.Viewer = posts.HydrateViewer(ctx, s.d.Flags, &Module{s: s}, uid)
	}
	s.noteList(ctx, res.Tally, len(page.Rows), s.prune(ctx, repo, uid, res.Missing))
	return page, nil
}

// noteList writes the bookmark list call's fields on the one request line: the shared drop counts plus rows_pruned.
func (s *service) noteList(ctx context.Context, t dropTally, returned, pruned int) {
	noteRows(ctx, t, returned)
	logger.SetRequestField(ctx, fieldRowsPruned, pruned)
}

// prune is the lazy clean-up of ADR-0023 D2: the bookmark docs of posts that no longer exist (confirmed missing by
// GetMany; hidden and blocked rows stay) are deleted with their userLikes.bookmarks entries in one best-effort batch
// (1 write + 1 delete per row, 0 reads), so each row is paid for once. It is skipped under DEGRADED_MODE=readonly (the
// list is NO_SIDE_EFFECTS and must stay write-free) and a failure is a WARN with counts only: the page is still
// served and the next open tries again. It returns the number of rows pruned.
func (s *service) prune(ctx context.Context, repo BookmarkRepo, uid string, gone []string) int {
	if len(gone) == 0 {
		return 0
	}
	if s.d.ReadOnly {
		slog.DebugContext(ctx, "engagement_bookmark_prune_skipped_readonly", "count", len(gone))
		return 0
	}
	pctx, cancel := context.WithTimeout(ctx, bookmarkPruneTimeout)
	defer cancel()
	if err := repo.Prune(pctx, uid, gone); err != nil {
		slog.WarnContext(ctx, "engagement_bookmark_prune_failed", "count", len(gone), "uid_hash", logger.HashUID(uid),
			"error", logger.RedactErr(err, append([]string{uid}, gone...)...).Error())
		return 0
	}
	s.cache.updateBookmarks(uid, func(b []string) []string { return withoutIDs(b, gone) })
	return len(gone)
}
