// service_bookmarks_list.go is the business logic of ListBookmarks (ADR-0023 D2, D6, ticket W2-4). A page is the
// caller's own bookmark docs (a thin {createdAt} row each), the live posts they name in ONE cache-first GetMany, the
// ADR-0010 D6 Home-column drop rules, the viewer state of what is left, and the lazy prune of rows whose post is gone.
// Nothing of other users' content is stored here, and nothing is cached for the list itself.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line fields of ListBookmarks (counts only; never ids, uids or text).
const (
	fieldRowsDropped        = "rows_dropped"
	fieldRowsDroppedMissing = "rows_dropped_missing"
	fieldRowsDroppedHidden  = "rows_dropped_hidden"
	fieldRowsDroppedBlocked = "rows_dropped_blocked"
	fieldRowsDroppedMuted   = "rows_dropped_muted"
	fieldRowsPruned         = "rows_pruned"
	fieldRowsReturned       = "rows_returned"
)

// Drop causes of blockCause.
const (
	causeBlocked = "blocked"
	causeMuted   = "muted"
)

// bookmarkPruneTimeout bounds the best-effort prune batch so a slow write cannot eat the rest of the RPC deadline.
const bookmarkPruneTimeout = 3 * time.Second

// ListBookmarks implements Bookmarks.
func (m *Module) ListBookmarks(ctx context.Context, uid string, pageSize int32, pageToken string) (BookmarkPage, error) {
	return m.s.listBookmarks(ctx, uid, pageSize, pageToken)
}

// bookmarksBinding ties a ListBookmarks page token to its list and caller: a token issued to one user, or for another
// kind of list, opens nothing else (ADR-0023 D2).
func bookmarksBinding(uid string) string { return "bookmarks|" + uid }

var errBookmarkToken = errors.New("engagement: invalid bookmarks page token")

// decodeBookmarkToken opens token for uid, bound to bookmarks|<uid> with the cursor package's 24 h TTL. An empty token
// is the first page (nil position); a foreign, expired, tampered or malformed one is errBookmarkToken. Pure: 0 reads.
func (s *service) decodeBookmarkToken(uid, token string) (*posts.Position, error) {
	if token == "" {
		return nil, nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, bookmarksBinding(uid), token, s.now())
	if err != nil || cursor.IsFirstPage(cur) || !ids.ValidPostID(cur.DocID) {
		return nil, errBookmarkToken
	}
	return &posts.Position{CreatedAt: cur.CreatedAt, ID: cur.DocID}, nil
}

// dropTally counts the rows a page dropped, by cause (ADR-0023 D6).
type dropTally struct{ missing, hidden, blocked, muted int }

func (d dropTally) total() int { return d.missing + d.hidden + d.blocked + d.muted }

// blockCause applies the ADR-0010 D6 Home column to a live, visible post for viewer uid: causeBlocked when the author
// or the QUOTE/REPOST's embedded author is in the caller's blocked or blockedBy set, causeMuted when in the muted set,
// "" otherwise. The caller's own posts are kept, copies of others included (as timeline.embedAllowed does). When the
// caller's blockedBy overflowed it cannot prove a foreign author (the post's own, or the embedded copy's) does not
// block it, so a foreign row fails closed, with no extra read per row (as posts contextUsable and GetThread do; W2-14 L-1).
func blockCause(snap graph.Snapshot, uid string, p *posts.Post) string {
	if p.AuthorID == uid {
		return ""
	}
	if a := p.AuthorID; snap.Blocked[a] || snap.BlockedBy[a] || snap.BlockedByOverflow {
		return causeBlocked
	}
	if snap.Muted[p.AuthorID] {
		return causeMuted
	}
	e := p.EmbeddedAuthor()
	if e == "" || e == uid {
		return ""
	}
	switch {
	case snap.Blocked[e] || snap.BlockedBy[e]:
		return causeBlocked
	case snap.Muted[e]:
		return causeMuted
	}
	return ""
}

// privateToViewer reports whether p is not public and its author is not the caller or someone the caller follows: the same
// 0-read check posts Viewable applies (a non-public post needs an accepted follow). Bookmarks must never be a side door to
// followers-only posts once private accounts ship (W2-14 L-2). The row is counted under rows_dropped_hidden, not pruned.
func privateToViewer(snap graph.Snapshot, uid string, p *posts.Post) bool {
	return p.AuthorID != uid && p.Visibility != posts.VisibilityPublic && !snap.Following[p.AuthorID]
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
	var (
		tally    dropTally
		gone     []string
		snap     graph.Snapshot
		haveSnap bool
	)
	for _, r := range rows {
		p, ok := live[r.PostID]
		switch {
		case !ok:
			tally.missing++
			gone = append(gone, r.PostID)
			continue
		case !p.Visible():
			tally.hidden++ // taken down or its author suspended: kept, a restore brings it back
			continue
		}
		if p.AuthorID != uid && !haveSnap {
			if snap, err = s.d.Graph.Snapshot(ctx, uid); err != nil {
				return BookmarkPage{}, logger.RedactErr(fmt.Errorf("engagement: list bookmarks: graph: %w", err), uid)
			}
			haveSnap = true
		}
		switch blockCause(snap, uid, p) {
		case causeBlocked:
			tally.blocked++
			continue
		case causeMuted:
			tally.muted++
			continue
		}
		if privateToViewer(snap, uid, p) {
			tally.hidden++ // followers-only and the caller does not follow the author (kept: a follow brings it back)
			continue
		}
		page.Rows = append(page.Rows, BookmarkRow{Post: p, BookmarkedAt: r.BookmarkedAt})
	}
	if len(page.Rows) > 0 {
		page.Viewer = posts.HydrateViewer(ctx, s.d.Flags, &Module{s: s}, uid)
	}
	s.noteList(ctx, tally, len(page.Rows), s.prune(ctx, repo, uid, gone))
	return page, nil
}

// noteList writes the list call's fields on the one request line.
func (s *service) noteList(ctx context.Context, t dropTally, returned, pruned int) {
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldRowsReturned, returned)
	logger.SetRequestField(ctx, fieldRowsDropped, t.total())
	logger.SetRequestField(ctx, fieldRowsDroppedMissing, t.missing)
	logger.SetRequestField(ctx, fieldRowsDroppedHidden, t.hidden)
	logger.SetRequestField(ctx, fieldRowsDroppedBlocked, t.blocked)
	logger.SetRequestField(ctx, fieldRowsDroppedMuted, t.muted)
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
