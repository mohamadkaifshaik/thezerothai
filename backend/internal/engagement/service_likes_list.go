// service_likes_list.go is the business logic of ListLikedPosts (ADR-0024 D6, ticket W3-10). The source is the caller's
// own userLikes.recent (the last MaxRecentLikes liked post ids, newest last), read through the instance cache; a page is
// a slice of it from the newest end, the live posts it names in ONE cache-first GetMany, the ADR-0010 D6 Home-column
// drop rules (list_common.go, shared with ListBookmarks) and the viewer state of what is left. Nothing is pruned: the
// like path owns the array, so a row whose post is gone is dropped from the page and nothing else (short pages are
// expected). Nothing of other users' content is stored here.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var _ LikesList = (*Module)(nil)

// ListLikedPosts implements LikesList.
func (m *Module) ListLikedPosts(ctx context.Context, uid string, pageSize int32, pageToken string) (LikesPage, error) {
	return m.s.listLikedPosts(ctx, uid, pageSize, pageToken)
}

// likesBinding ties a ListLikedPosts page token to its list and caller (ADR-0024 D6).
func likesBinding(uid string) string { return listBinding("likes", uid) }

// likesTokenVersion prefixes the payload of a likes page token, so the shape can change without a flag day: a token of
// another version fails to open and the client reloads the first page.
const likesTokenVersion = "v1"

// likesAnchor is the cursor of ListLikedPosts (ADR-0024 D6): where the next page starts, remembered three ways so that
// an unlike, a re-like or a trim between two pages neither skips nor repeats a row.
type likesAnchor struct {
	// Next is the first id not yet scanned (the entry just older than Last).
	Next string
	// Last is the last id the previous page scanned, kept or dropped.
	Last string
	// NextIndex is Next's position counted from the newest end (0 = newest) when the token was issued: the last
	// fallback, used only when both anchors are gone.
	NextIndex int
}

// encodeLikesToken seals a for uid into an opaque token. The payload rides in cursor.Cursor.DocID ("v1:next:last:index");
// CreatedAt is the issue time and is not read back.
func (s *service) encodeLikesToken(uid string, a likesAnchor) string {
	payload := strings.Join([]string{likesTokenVersion, a.Next, a.Last, strconv.Itoa(a.NextIndex)}, ":")
	return cursor.EncodeAt(s.d.CursorKey, likesBinding(uid), cursor.Cursor{CreatedAt: s.now(), DocID: payload}, s.now())
}

// decodeLikesToken opens token for uid, bound to likes|<uid> with the 24 h TTL. An empty token is the first page (nil).
// A foreign, expired, tampered or malformed one, and one whose payload does not parse, is errListToken. Pure: 0 reads.
func (s *service) decodeLikesToken(uid, token string) (*likesAnchor, error) {
	if token == "" {
		return nil, nil
	}
	cur, err := s.openListToken(likesBinding(uid), token)
	if err != nil {
		return nil, err
	}
	parts := strings.Split(cur.DocID, ":")
	if len(parts) != 4 || parts[0] != likesTokenVersion || !ids.ValidPostID(parts[1]) || !ids.ValidPostID(parts[2]) {
		return nil, errListToken
	}
	idx, err := strconv.Atoi(parts[3])
	if err != nil || idx < 0 {
		return nil, errListToken
	}
	return &likesAnchor{Next: parts[1], Last: parts[2], NextIndex: idx}, nil
}

// likesResume is the resume rule of ADR-0024 D6: the position, counted from the newest end of recent (0 = newest), where
// the next page starts. recent is newest last, as stored. A position at or past len(recent) means the list has ended.
//
//  1. Next, when it is still in recent and sits OLDER than Last (or Last is gone): resume at it.
//  2. Else Last, when it is still in recent: resume at the entry just older than it.
//  3. Else the recorded offset from the newest end.
//
// Why: a trim only removes the oldest entries, so the anchors never move relative to each other; an unlike of Next is
// rule 2 landing exactly where Next stood; a re-like of Next moves it above Last (newer), which rule 1 refuses, so it is
// not shown twice. Two changes at the boundary in one window can skip or repeat the rows changed there, no more.
func likesResume(recent []string, a likesAnchor) int {
	n := len(recent)
	pos := func(id string) int { // position from the newest end, -1 when absent
		for i := n - 1; i >= 0; i-- {
			if recent[i] == id {
				return n - 1 - i
			}
		}
		return -1
	}
	pn, pl := pos(a.Next), pos(a.Last)
	switch {
	case pn >= 0 && (pl < 0 || pn > pl):
		return pn
	case pl >= 0:
		return pl + 1
	default:
		return a.NextIndex
	}
}

// listLikedPosts implements LikesList.ListLikedPosts. Reads, in this order and each only when needed: userLikes through
// the instance cache (1 cold; an empty array stops here), GetMany (the misses of the instance post cache), the caller's
// graph snapshot (1, cached 60 s, skipped when every live row is the caller's own); the viewer state comes from the
// same userLikes state (0 reads). Writes 0.
//
// Staleness: the id list is the instance-cached userLikes (60 s TTL; this instance's own likes and unlikes update it in
// place), so a like made on another instance can take up to 60 s to appear. The posts are as fresh as the post cache.
//
// The next token is issued exactly when older entries remain (the array is in hand, so no look-ahead read is needed),
// and is sealed from the last SCANNED id, kept or dropped.
func (s *service) listLikedPosts(ctx context.Context, uid string, pageSize int32, token string) (_ LikesPage, err error) {
	logger.SetRequestField(ctx, fieldOp, "list_liked_posts")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if len(s.d.CursorKey) == 0 || s.d.Graph == nil {
		return LikesPage{}, logger.RedactErr(errors.New("engagement: likes list is not wired (no CursorKey or Graph)"), uid)
	}
	anchor, err := s.decodeLikesToken(uid, token)
	if err != nil {
		return LikesPage{}, apierr.Validation("page_token", "page_token is invalid or expired")
	}
	st, err := s.state(ctx, uid)
	if err != nil {
		return LikesPage{}, logger.RedactErr(fmt.Errorf("engagement: list liked posts: %w", err), uid)
	}
	recent := st.recent // immutable (copy on write): safe to read without a lock
	n := len(recent)
	start := 0
	if anchor != nil {
		start = likesResume(recent, *anchor)
	}
	if start >= n {
		noteRows(ctx, dropTally{}, 0)
		return LikesPage{}, nil
	}
	end := min(start+limits.ClampPageSize(pageSize), n)
	postIDs := make([]string, 0, end-start) // newest liked first
	for p := start; p < end; p++ {
		postIDs = append(postIDs, recent[n-1-p])
	}
	var page LikesPage
	if end < n {
		page.NextPageToken = s.encodeLikesToken(uid, likesAnchor{Next: recent[n-1-end], Last: postIDs[len(postIDs)-1], NextIndex: end})
	}
	live, err := s.d.Reader.GetMany(ctx, postIDs)
	if err != nil {
		return LikesPage{}, logger.RedactErr(fmt.Errorf("engagement: list liked posts: load posts: %w", err), append([]string{uid}, postIDs...)...)
	}
	res, err := s.dropRows(ctx, uid, postIDs, live)
	if err != nil {
		return LikesPage{}, dropErr("list liked posts", uid, err)
	}
	for k, i := range res.Kept {
		page.Posts = append(page.Posts, live[postIDs[i]])
		page.Hints = append(page.Hints, res.Hints[k])
	}
	if len(page.Posts) > 0 {
		page.Viewer = posts.HydrateViewer(ctx, s.d.Flags, &Module{s: s}, uid)
	}
	noteRows(ctx, res.Tally, len(page.Posts))
	return page, nil
}
