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

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
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
	// fieldRowsDroppedProtected counts rows posts.Audience dropped: the author, or the original a REPOST copies, is a
	// protected account the caller does not follow (ADR-0025 D4). Never pruned: a follow, or an unprotect, brings them back.
	fieldRowsDroppedProtected = "rows_dropped_protected"
	fieldRowsPruned           = "rows_pruned"
	fieldRowsReturned         = "rows_returned"
	// fieldRowsWithheld counts rows kept as owner placeholders (W3-36 L-2); they are also in rows_returned.
	fieldRowsWithheld = "rows_withheld"
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
type dropTally struct{ missing, hidden, blocked, muted, protected, withheld int }

func (d dropTally) total() int { return d.missing + d.hidden + d.blocked + d.muted + d.protected }

// RowAudience is the part of posts.Audience the lists use (satisfied by *posts.Audience): the one visibility predicate
// (ADR-0025 D3, D4). Decide on the list surface drops a row whose author, or whose REPOSTed original's author, is
// protected and not followed, and marks a QUOTE of one PROTECTED; ProtectedAuthor feeds the computed wire visibility.
type RowAudience interface {
	Decide(ctx context.Context, viewer string, snap graph.Snapshot, p *posts.Post, surface posts.Surface) (posts.Decision, error)
	ProtectedAuthor(ctx context.Context, viewer, author string, following bool) bool
}

// RowHint is what the handler needs to render a kept row besides the post: the embed state and whether the author is
// protected. The zero value changes nothing (posts.ApplyEmbedState / ApplyWireVisibility are the only appliers).
type RowHint struct {
	Embed     postsv1.EmbedViewerState
	Protected bool
	// Withheld: the caller may no longer see the row's protected author; the row is a stripped placeholder (ADR-0025 note
	// W3-36 L-2). Set only by dropRows for the owner lists.
	Withheld bool
}

// Apply sets the hint on v through the two shared appliers; PROTECTED strips the copy (posts.ApplyEmbedState).
func (h RowHint) Apply(v *postsv1.PostView) {
	if h.Withheld {
		posts.ApplyWithheld(v) // after this the view carries no protected content and no wire visibility
		return
	}
	posts.ApplyEmbedState(v, h.Embed)
	posts.ApplyWireVisibility(v, h.Protected)
}

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

// dropResult is what dropRows decided about one page of ids.
type dropResult struct {
	// Kept are the indexes into the ids slice of the rows that stay, in the same order.
	Kept []int
	// Hints are the render hints of the kept rows, same length and order as Kept.
	Hints []RowHint
	Tally dropTally
	// Missing are the ids GetMany did not return. ListBookmarks prunes them; ListLikedPosts leaves them (the like
	// path owns the array).
	Missing []string
}

// dropRows applies the drop rules of ADR-0023 D2 / ADR-0024 D6 to ids (the page's ids in order) and live (the GetMany
// answer): missing, then !Visible (taken down or its author suspended: kept in storage, a restore brings it back), then
// blockCause, then Audience.Decide on the list surface (protected authors, ADR-0025 D4; it replaced the stored-visibility
// privateToViewer, which never fired because stored visibility is always PUBLIC). The caller's graph snapshot is read lazily, only when a live post of someone else is
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
		// A snapshot is needed for someone else's post, and for the caller's own QUOTE or REPOST of someone else's post
		// (the follow state decides whether the copy is protected).
		if ea := p.EmbeddedAuthor(); !haveSnap && (p.AuthorID != uid || (s.d.Audience != nil && ea != "" && ea != uid)) {
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
		var hint RowHint
		if s.d.Audience != nil {
			d, err := s.d.Audience.Decide(ctx, uid, snap, p, posts.SurfaceOwnList)
			if err != nil {
				return dropResult{}, err
			}
			if d.Verdict == posts.Withheld {
				// Kept as a placeholder the owner can undo (W3-36 L-2); never pruned, a follow or an unprotect brings the full row back.
				res.Tally.withheld++
				res.Kept = append(res.Kept, i)
				res.Hints = append(res.Hints, RowHint{Withheld: true})
				continue
			}
			if d.Verdict != posts.Show {
				res.Tally.protected++ // kept in storage: a follow, or an unprotect, brings it back
				continue
			}
			hint = RowHint{Embed: d.Embed, Protected: s.d.Audience.ProtectedAuthor(ctx, uid, p.AuthorID, snap.Following[p.AuthorID])}
		}
		res.Kept = append(res.Kept, i)
		res.Hints = append(res.Hints, hint)
	}
	return res, nil
}

// dropErr maps a dropRows error: an apierr (UNAVAILABLE when the protected set is unknown, fail closed, ADR-0025 D3)
// passes through to the handler; anything else is wrapped and redacted as an internal error.
func dropErr(op, uid string, err error) error {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return err
	}
	return logger.RedactErr(fmt.Errorf("engagement: %s: %w", op, err), uid)
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
	logger.SetRequestField(ctx, fieldRowsDroppedProtected, t.protected)
	logger.SetRequestField(ctx, fieldRowsWithheld, t.withheld)
}
