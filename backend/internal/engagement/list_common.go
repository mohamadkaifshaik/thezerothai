// list_common.go holds what the two owner-only post lists of this module share: ListBookmarks (ADR-0023 D2, D6) and
// ListLikedPosts (ADR-0024 D6). Both read the caller's own ids, load the live posts in ONE cache-first GetMany and apply
// the same ADR-0010 D6 Home-column drop rules, so the page token binding and opening, the per-row drop decision and the
// one request-line writer live here once. What differs stays in the callers: where the ids come from, the cursor
// payload, and whether a missing post's row is pruned (bookmarks) or left alone (likes, whose array the like path owns).
package engagement

import (
	"context"
	"errors"
	"fmt"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line fields of the owner-only lists (counts only; never ids, uids or text). fs_reads / fs_writes / fs_deletes
// are added by mw.Logging.
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

// errListToken is the one reason a page token of either list fails to open; the callers map it to VALIDATION
// page_token without saying why (a foreign, expired, tampered and malformed token look the same).
var errListToken = errors.New("engagement: invalid list page token")

// listBinding ties a page token to its list kind and caller: a token issued to one user, or for another kind of list,
// opens nothing else.
func listBinding(kind, uid string) string { return kind + "|" + uid }

// openListToken opens a non-empty page token against binding with the cursor package's 24 h TTL. A foreign, expired,
// tampered or malformed token, and the zero cursor, are errListToken. Pure: 0 reads. The caller validates the payload
// (the doc id for bookmarks, the versioned anchors for likes).
func (s *service) openListToken(binding, token string) (cursor.Cursor, error) {
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return cursor.Cursor{}, errListToken
	}
	return cur, nil
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

// dropResult is what dropRows decided about one page of ids.
type dropResult struct {
	// Kept are the indexes into the ids slice of the rows that stay, in the same order.
	Kept  []int
	Tally dropTally
	// Missing are the ids GetMany did not return. ListBookmarks prunes them; ListLikedPosts leaves them (the like
	// path owns the array).
	Missing []string
}

// dropRows applies the drop rules of ADR-0023 D2 / ADR-0024 D6 to ids (the page's ids in order) and live (the GetMany
// answer): missing, then !Visible (taken down or its author suspended: kept in storage, a restore brings it back), then
// blockCause, then privateToViewer. The caller's graph snapshot is read lazily, only when a live post of someone else is
// met (1 read, cached 60 s), so a page of the caller's own posts costs none. It returns the graph error unredacted;
// callers wrap and redact it.
func (s *service) dropRows(ctx context.Context, uid string, ids []string, live map[string]*posts.Post) (dropResult, error) {
	var (
		res      dropResult
		snap     graph.Snapshot
		haveSnap bool
	)
	for i, id := range ids {
		p, ok := live[id]
		switch {
		case !ok:
			res.Tally.missing++
			res.Missing = append(res.Missing, id)
			continue
		case !p.Visible():
			res.Tally.hidden++
			continue
		}
		if p.AuthorID != uid && !haveSnap {
			var err error
			if snap, err = s.d.Graph.Snapshot(ctx, uid); err != nil {
				return dropResult{}, fmt.Errorf("graph: %w", err)
			}
			haveSnap = true
		}
		switch blockCause(snap, uid, p) {
		case causeBlocked:
			res.Tally.blocked++
			continue
		case causeMuted:
			res.Tally.muted++
			continue
		}
		if privateToViewer(snap, uid, p) {
			res.Tally.hidden++ // followers-only and the caller does not follow the author (kept: a follow brings it back)
			continue
		}
		res.Kept = append(res.Kept, i)
	}
	return res, nil
}

// noteRows writes the drop and return counts of a list call on the one request line.
func noteRows(ctx context.Context, t dropTally, returned int) {
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldRowsReturned, returned)
	logger.SetRequestField(ctx, fieldRowsDropped, t.total())
	logger.SetRequestField(ctx, fieldRowsDroppedMissing, t.missing)
	logger.SetRequestField(ctx, fieldRowsDroppedHidden, t.hidden)
	logger.SetRequestField(ctx, fieldRowsDroppedBlocked, t.blocked)
	logger.SetRequestField(ctx, fieldRowsDroppedMuted, t.muted)
}
