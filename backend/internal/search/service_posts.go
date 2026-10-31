package search

import (
	"context"
	"fmt"
	"slices"
	"time"
	"unicode/utf8"

	"golang.org/x/sync/singleflight"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/internal/timeline"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// tagEntrySize is the newest posts per tag held in the shared tag entry (ADR-0028 D3).
	tagEntrySize = 30
	// tagEntryTTL is the staleness bound of the tag entry: a new tagged post reaches Top, Latest page 1 and Media page 1
	// within this long on an instance, and a moderation takedown reaches a warm entry within it too (serve-time
	// !Visible() drops a post whose flag is already set on the cached object).
	tagEntryTTL = 60 * time.Second
	// defaultTagEntries is the entry capacity when PostsDeps.TagEntries is unset (CACHE_SEARCH_TAG_ENTRIES default).
	defaultTagEntries = 500
	// topWindow is how far back TOP looks (ADR-0028 D3), and topMaxPage its one page.
	topWindow  = 7 * 24 * time.Hour
	topMaxPage = 20
	// mediaScan is how many older tagged posts one MEDIA call scans.
	mediaScan = 30
	// LATEST query windows are fixed tiers independent of page_size (ADR-0028 note 2026-10-31 part 3, review L-1): page 1 is
	// the whole tag entry (tagEntrySize rows) for page_size <= tagEntrySize and latestWide beyond it; an older page is
	// latestOlderSmall for page_size <= latestOlderSmall and latestWide beyond it; a tail page reads the whole rest (latestWide).
	latestOlderSmall = 20
	latestWide       = 50
	// entryLoadTimeout bounds the shared entry load, which runs detached from the first caller's cancellation.
	entryLoadTimeout = 5 * time.Second
)

// Request-line fields (counts and kinds only; never the query, a tag, an id or a uid; ADR-0028 D10).
const (
	fieldQueryKind        = "query_kind"
	fieldQueryLen         = "query_len"
	fieldTab              = "tab"
	fieldResults          = "results"
	fieldDropped          = "dropped"
	fieldDroppedHidden    = "dropped_hidden"
	fieldDroppedBlocked   = "dropped_blocked"
	fieldDroppedMuted     = "dropped_muted"
	fieldDroppedProtected = "dropped_protected"
	fieldCacheHit         = "cache_hit"
)

// tagStore is the tag-entry cache seam (ADR-0028 D4: small interfaces so Memorystore can replace the instance LRU by ADR
// at Stage 2 with no caller change). Values are shared and immutable.
type tagStore interface {
	Get(tag string) ([]*posts.Post, bool)
	Set(tag string, ps []*posts.Post)
}

// PostsDeps are what SearchPosts needs beyond the flag checker (ADR-0028 D11). Posts, Graph and CursorKey are required:
// without them an enabled caller gets Unimplemented.
type PostsDeps struct {
	// Posts is the only way to read posts (ByHashtag).
	Posts posts.Reader
	// Graph supplies the caller's social context (cached 60 s).
	Graph graph.Reader
	// Viewer supplies liked/reposted/bookmarked flags through posts.HydrateViewer. Nil: every flag false, no read.
	Viewer posts.ViewerFlags
	// Audience is THE visibility predicate (posts.NewSnapshotAudience(protectedAuthors), ADR-0025). Nil is "nobody is
	// protected"; apiserver refuses to start without it.
	Audience *posts.Audience
	// CursorKey seals page tokens (config.CursorHMACKey).
	CursorKey []byte
	// TagEntries is the tag-entry capacity (CACHE_SEARCH_TAG_ENTRIES).
	TagEntries int
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// Option configures New.
type Option func(*service)

// WithPosts enables SearchPosts (W4-7, W4-8). Incomplete deps leave it disabled (Unimplemented for an enabled caller).
func WithPosts(d PostsDeps) Option {
	return func(s *service) {
		if d.Posts == nil || d.Graph == nil || len(d.CursorKey) == 0 {
			return
		}
		if d.Audience == nil {
			d.Audience = posts.NewSnapshotAudience(nil)
		}
		if d.Now == nil {
			d.Now = time.Now
		}
		n := d.TagEntries
		if n <= 0 {
			n = defaultTagEntries
		}
		s.pr = &postsRuntime{d: d, fc: s.flags, entries: cache.New[string, []*posts.Post](n, tagEntryTTL)}
	}
}

type postsRuntime struct {
	d       PostsDeps
	fc      posts.FlagChecker
	entries tagStore
	sf      singleflight.Group
}

type tabKind int

const (
	tabTop tabKind = iota
	tabLatest
	tabMedia
)

func (t tabKind) String() string {
	switch t {
	case tabLatest:
		return "LATEST"
	case tabMedia:
		return "MEDIA"
	}
	return "TOP"
}

// tabOf maps the wire tab. UNSPECIFIED and a value this build does not know are TOP (an additive enum value from a newer
// client must not fail the call).
func tabOf(t searchv1.SearchTab) tabKind {
	switch t {
	case searchv1.SearchTab_SEARCH_TAB_LATEST:
		return tabLatest
	case searchv1.SearchTab_SEARCH_TAB_MEDIA:
		return tabMedia
	}
	return tabTop
}

// binding ties a page token to its caller, tag and tab (ADR-0028 D5). Tags never contain '|'.
func binding(uid, tag string, t tabKind) string {
	return "search|" + uid + "|" + tag + "|" + t.String()
}

// tailBinding is the binding of a LATEST tail token: the page that issued it came from a window that was not full, so the
// end of the tag was reached and every later page depends only on visible rows (ADR-0028 note 2026-10-31 part 3). The
// decoder tries binding(LATEST), then tailBinding, so both tokens stay opaque and need no new codec.
func tailBinding(uid, tag string) string {
	return "search|" + uid + "|" + tag + "|LATEST_TAIL"
}

func tokenError() error {
	return apierr.Validation("page_token", "invalid or expired page token")
}

// dropTally counts the rows a call dropped by cause (the request line).
type dropTally struct{ hidden, blocked, muted, protected int }

func (d dropTally) total() int { return d.hidden + d.blocked + d.muted + d.protected }

// fetched is the unfiltered rows a call works on, newest first. more is whether the window was full (the query returned as
// many rows as it asked for, or the entry held tagEntrySize), so older posts may exist below the last row.
type fetched struct {
	rows []*posts.Post
	more bool
	hit  bool
}

// search implements SearchPosts (ADR-0028 D3, D5; plan W4-7, W4-8).
//
// Worst-case Firestore reads, interceptor included (writes 0): TOP, LATEST page 1 and MEDIA page 1 at page_size <= 30
// cold 33 (interceptor 1, caller graph 1, userLikes 1, the tag entry 30), warm 0 to 3; LATEST page 1 at page_size 31 to 50:
// 53 (query 50). LATEST windows are fixed tiers, never the page size itself (ADR-0028 note 2026-10-31 part 3, review L-1):
// an older page is 23 at page_size <= 20 (query 20) and 53 at 21 to 50 (query 50); a tail page (the token of a window that
// was not full, the end of the tag) reads 3 + the rows left, at most 32 after a page-1 entry and 52 after a 50-row window.
// The client sends 20, so its cost is 33 / 23 / <= 32. MEDIA older scan 33 (scan 30).
// An unsupported query, a grammar rejection and a bad token read nothing beyond the interceptor. The graph and userLikes
// reads are 60 s instance caches; userLikes is read only when a row is returned and engagement or bookmarks is on.
//
// LATEST filters the WHOLE window (moderation, blocks, mutes, Audience), then cuts to page_size, so the number of rows and
// whether a token follows depend only on the visible rows and on whether the window was full. The token position is the last
// returned row when the page was cut, else the window's last queried row; a window that was not full issues a LATEST_TAIL
// token (only when it was cut), and a tail page reads the whole rest of the tag.
//
// Staleness: the tag entry is shared across viewers and at most tagEntryTTL old; every per-viewer filter runs after it.
func (r *postsRuntime) search(ctx context.Context, uid, rawQuery string, tab searchv1.SearchTab, pageSize int32, token string) (*searchv1.SearchPostsResponse, error) {
	if pageSize < 0 {
		return nil, apierr.Validation("page_size", "page_size must not be negative")
	}
	q, err := parseQuery(rawQuery)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldQueryLen, utf8.RuneCountInString(q.body))
	tag, ok := q.hashtag()
	if !ok {
		logger.SetRequestField(ctx, fieldQueryKind, queryKindUnsupported)
		return &searchv1.SearchPostsResponse{UnsupportedQuery: true}, nil
	}
	logger.SetRequestField(ctx, fieldQueryKind, queryKindHashtag)
	t := tabOf(tab)
	logger.SetRequestField(ctx, fieldTab, t.String())
	limit := limits.ClampPageSize(pageSize)

	var cur *cursor.Cursor
	tail := false // the token is a LATEST_TAIL token
	if token != "" {
		if t == tabTop { // TOP issues no token, so none can be valid for it
			return nil, tokenError()
		}
		c, err := cursor.DecodeAt(r.d.CursorKey, binding(uid, tag, t), token, r.d.Now())
		if err != nil && t == tabLatest { // the tail token of a LATEST chain
			if c, err = cursor.DecodeAt(r.d.CursorKey, tailBinding(uid, tag), token, r.d.Now()); err == nil {
				tail = true
			}
		}
		if err != nil || cursor.IsFirstPage(c) {
			return nil, tokenError()
		}
		cur = &c
	}

	f, err := r.fetch(ctx, uid, tag, t, limit, cur, tail)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldCacheHit, f.hit)

	cands := f.rows
	switch t {
	case tabTop:
		cands = within(cands, r.d.Now().Add(-topWindow))
	case tabMedia:
		cands = withOwnMedia(cands)
	}
	kept, embed, tally, snap, err := r.filter(ctx, uid, cands)
	if err != nil {
		return nil, err
	}

	more := f.more
	tailToken := false // the token issued below, if any, is a LATEST_TAIL token
	var resume *posts.Post
	if len(f.rows) > 0 {
		resume = f.rows[len(f.rows)-1] // the last QUERIED row, kept or not, so a dropped post never stalls the token
	}
	switch t {
	case tabTop:
		rankTop(kept)
		if n := min(limit, topMaxPage); len(kept) > n {
			kept = kept[:n]
		}
		more = false
	case tabMedia:
		if len(kept) > limit { // resume right after the last row returned, so nothing between is skipped
			kept = kept[:limit]
			resume, more = kept[limit-1], true
		}
	case tabLatest:
		// L-1: the whole window was filtered above, so the cut, the token and its position depend only on the visible rows
		// and on whether the window was full. Cut at the page size and resume after the last row RETURNED (the next page
		// queries the rows after it again, hidden ones included); with no cut, after the window's last queried row. A window
		// that was not full holds the end of the tag: only a cut page then issues a token, and it is a tail token.
		cut := len(kept) > limit
		if cut {
			kept = kept[:limit]
			resume = kept[limit-1]
		}
		tailToken = !f.more
		more = f.more || cut
	}
	resp := &searchv1.SearchPostsResponse{Posts: r.views(ctx, uid, kept, embed, snap), NormalizedTag: tag}
	if more && resume != nil {
		b := binding(uid, tag, t)
		if tailToken {
			b = tailBinding(uid, tag)
		}
		resp.NextPageToken = cursor.EncodeAt(r.d.CursorKey, b, cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}, r.d.Now())
	}
	logger.SetRequestField(ctx, fieldResults, len(resp.Posts))
	logger.SetRequestField(ctx, fieldDropped, tally.total())
	logger.SetRequestField(ctx, fieldDroppedHidden, tally.hidden)
	logger.SetRequestField(ctx, fieldDroppedBlocked, tally.blocked)
	logger.SetRequestField(ctx, fieldDroppedMuted, tally.muted)
	logger.SetRequestField(ctx, fieldDroppedProtected, tally.protected)
	return resp, nil
}

// fetch runs the one query (or entry read) the tab and token call for.
func (r *postsRuntime) fetch(ctx context.Context, uid, tag string, t tabKind, limit int, cur *cursor.Cursor, tail bool) (fetched, error) {
	query := func(before *cursor.Cursor, n int) ([]*posts.Post, error) {
		var w posts.Window
		if before != nil {
			w.Before = &posts.Position{CreatedAt: before.CreatedAt, ID: before.DocID}
		}
		rows, err := r.d.Posts.ByHashtag(ctx, tag, w, n)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("search: tag query: %w", err), uid)
		}
		return rows, nil
	}
	switch {
	case t == tabMedia && cur != nil: // a scan of mediaScan older posts
		rows, err := query(cur, mediaScan)
		return fetched{rows: rows, more: len(rows) == mediaScan}, err
	case t == tabLatest && cur != nil:
		w := latestWindow(limit, tail)
		rows, err := query(cur, w)
		return fetched{rows: rows, more: len(rows) == w}, err
	case t == tabLatest && limit > tagEntrySize: // larger than the entry: one fixed wide window, skipping it
		rows, err := query(nil, latestWide)
		return fetched{rows: rows, more: len(rows) == latestWide}, err
	}
	entry, hit, err := r.entry(ctx, uid, tag)
	if err != nil {
		return fetched{}, err
	}
	// LATEST page 1 is the whole entry too (L-1): it is filtered first and cut at the page size afterwards.
	return fetched{rows: entry, more: len(entry) == tagEntrySize, hit: hit}, nil
}

// latestWindow is the size of an older LATEST window: a fixed tier, never the page size itself (L-1). A tail page reads the
// whole rest of the tag, which holds fewer than latestWide rows unless a late commit landed in the settle gap.
func latestWindow(limit int, tail bool) int {
	if tail || limit > latestOlderSmall {
		return latestWide
	}
	return latestOlderSmall
}

// entry returns the newest tagEntrySize posts of tag, unfiltered: from the instance cache (0 reads) or one ByHashtag
// (len(result) reads, minimum 1). Concurrent misses share one load; it runs detached from the first caller's
// cancellation and is charged to that caller's counter. An empty result is cached too.
func (r *postsRuntime) entry(ctx context.Context, uid, tag string) (entry []*posts.Post, hit bool, err error) {
	if ps, ok := r.entries.Get(tag); ok {
		return ps, true, nil
	}
	v, err, _ := r.sf.Do(tag, func() (any, error) {
		if ps, ok := r.entries.Get(tag); ok { // the previous leader filled it between our Get and Do
			return ps, nil
		}
		lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), entryLoadTimeout)
		defer cancel()
		ps, err := r.d.Posts.ByHashtag(lctx, tag, posts.Window{}, tagEntrySize)
		if err != nil {
			return nil, err
		}
		r.entries.Set(tag, ps)
		return ps, nil
	})
	if err != nil {
		return nil, false, logger.RedactErr(fmt.Errorf("search: tag entry: %w", err), uid)
	}
	return v.([]*posts.Post), false, nil
}

// within keeps the rows created at or after cutoff, in order.
func within(rows []*posts.Post, cutoff time.Time) []*posts.Post {
	out := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if !p.CreatedAt.Before(cutoff) {
			out = append(out, p)
		}
	}
	return out
}

// withOwnMedia keeps the rows that carry their own images (len(media) > 0), not hasMedia (which needs the one-off
// backfill) and not a QUOTE's embedded media (ADR-0028 D3).
func withOwnMedia(rows []*posts.Post) []*posts.Post {
	out := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if len(p.Media) > 0 {
			out = append(out, p)
		}
	}
	return out
}

// topScore is the TOP ranking (ADR-0028 D3): likes + 2 x reposts + 2 x quotes + replies, as cached (at most 60 s stale).
func topScore(p *posts.Post) int64 {
	return p.LikeCount + 2*p.RepostCount + 2*p.QuoteCount + p.ReplyCount
}

// rankTop sorts rows in place by score, best first, ties newest first (timeline.Compare, the one post order). rows is a
// fresh slice (never the shared entry).
func rankTop(rows []*posts.Post) {
	slices.SortStableFunc(rows, func(a, b *posts.Post) int {
		if sa, sb := topScore(a), topScore(b); sa != sb {
			if sa > sb {
				return -1
			}
			return 1
		}
		return timeline.Compare(timeline.PositionOf(a), timeline.PositionOf(b))
	})
}

// filter applies the per-viewer rules after the shared entry (ADR-0028 D3, ADR-0010 D6, ADR-0025 D4), in this order per
// row: moderation (!Visible), the blockedBy-overflow fail-closed rule, the author's and a QUOTE's embedded author's
// block / blocked-by / mute state, then posts.Audience.Decide on the list surface (protected authors; a QUOTE of one is
// kept with embed PROTECTED). The caller's own posts are kept. The graph snapshot is read once (cached 60 s) and only
// when rows exist. A protected set that cannot be trusted is UNAVAILABLE (never a partial page). Reads: 0 beyond the
// snapshot. The returned slice is fresh, so callers may reorder it.
func (r *postsRuntime) filter(ctx context.Context, uid string, rows []*posts.Post) ([]*posts.Post, map[string]postsv1.EmbedViewerState, dropTally, graph.Snapshot, error) {
	var tally dropTally
	if len(rows) == 0 {
		return nil, nil, tally, graph.Snapshot{}, nil
	}
	snap, err := r.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, nil, tally, snap, logger.RedactErr(fmt.Errorf("search: caller graph: %w", err), uid)
	}
	kept := make([]*posts.Post, 0, len(rows))
	var embed map[string]postsv1.EmbedViewerState
	for _, p := range rows {
		if !p.Visible() {
			tally.hidden++
			continue
		}
		switch blockCause(snap, uid, p) {
		case causeBlocked:
			tally.blocked++
			continue
		case causeMuted:
			tally.muted++
			continue
		}
		d, err := r.d.Audience.Decide(ctx, uid, snap, p, posts.SurfaceList)
		if err != nil {
			return nil, nil, tally, snap, err // an apierr (UNAVAILABLE) passes through
		}
		if d.Verdict != posts.Show {
			tally.protected++
			continue
		}
		if d.Embed != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED {
			if embed == nil {
				embed = map[string]postsv1.EmbedViewerState{}
			}
			embed[p.ID] = d.Embed
		}
		kept = append(kept, p)
	}
	return kept, embed, tally, snap, nil
}

// Drop causes of blockCause.
const (
	causeBlocked = "blocked"
	causeMuted   = "muted"
)

// blockCause is the ADR-0010 D6 Home column for a visible post: causeBlocked when the author or a QUOTE's embedded
// author is blocked by the caller or blocks the caller, causeMuted when muted, "" otherwise. The caller's own posts are
// kept, copies of others included. When the caller's blockedBy set overflowed it cannot prove a foreign author does not
// block it, so only the caller's posts and followed authors' posts stay and a foreign embed is dropped (no extra read;
// as timeline.embedAllowed and the owner lists do). It mirrors engagement's blockCause and timeline's embedAllowed:
// those are unexported in modules that may not import each other's internals.
func blockCause(snap graph.Snapshot, uid string, p *posts.Post) string {
	if p.AuthorID == uid {
		return ""
	}
	ea := p.EmbeddedAuthor()
	if snap.BlockedByOverflow {
		if !snap.Following[p.AuthorID] || (ea != "" && ea != uid) {
			return causeBlocked
		}
	}
	if snap.Blocked[p.AuthorID] || snap.BlockedBy[p.AuthorID] {
		return causeBlocked
	}
	if snap.Muted[p.AuthorID] {
		return causeMuted
	}
	if ea == "" || ea == uid {
		return ""
	}
	switch {
	case snap.Blocked[ea] || snap.BlockedBy[ea]:
		return causeBlocked
	case snap.Muted[ea]:
		return causeMuted
	}
	return ""
}

// views renders the kept rows with the viewer's flags (one cached userLikes read when engagement or bookmarks is on and a
// row is returned; posts.HydrateViewer), the PROTECTED embed strip and the computed wire visibility.
func (r *postsRuntime) views(ctx context.Context, uid string, kept []*posts.Post, embed map[string]postsv1.EmbedViewerState, snap graph.Snapshot) []*postsv1.PostView {
	var vs posts.ViewerSet
	if len(kept) > 0 {
		vs = posts.HydrateViewer(ctx, r.fc, r.d.Viewer, uid)
	}
	out := make([]*postsv1.PostView, 0, len(kept))
	for _, p := range kept {
		v := posts.ToView(p, vs, uid)
		if st, ok := embed[p.ID]; ok {
			posts.ApplyEmbedState(v, st) // the only place the PROTECTED strip happens
		}
		posts.ApplyWireVisibility(v, r.d.Audience.ProtectedAuthor(ctx, uid, p.AuthorID, snap.Following[p.AuthorID]))
		out = append(out, v)
	}
	return out
}
