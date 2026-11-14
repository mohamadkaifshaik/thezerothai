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
	// tagEntrySize is the newest posts per tag held in the shared tag entry.
	tagEntrySize = 30
	// tagEntryTTL is the staleness bound of the tag entry: a new tagged post reaches Top, Latest page 1 and Media page 1
	// within this long on an instance, and a moderation takedown reaches a warm entry within it too (serve-time
	// !Visible() drops a post whose flag is already set on the cached object).
	tagEntryTTL = 60 * time.Second
	// defaultTagEntries is the entry capacity when PostsDeps.TagEntries is unset (CACHE_SEARCH_TAG_ENTRIES default).
	defaultTagEntries = 500
	// topWindow is how far back TOP looks, and topMaxPage its one page.
	topWindow  = 7 * 24 * time.Hour
	topMaxPage = 20
	// mediaScan is how many older tagged posts one MEDIA call scans.
	mediaScan = 30
	// LATEST query windows are fixed tiers independent of page_size (part 3, review L-1): page 1 is
	// the whole tag entry (tagEntrySize rows) for page_size <= tagEntrySize and latestWide beyond it; an older page is
	// latestOlderSmall for page_size <= latestOlderSmall and latestWide beyond it; a tail page reads the whole rest (latestWide).
	latestOlderSmall = 20
	latestWide       = 50
	// followingWindows is the most query windows one from_following call (F22) scans on LATEST and MEDIA: the documented
	// recall limit. TOP filters its one entry.
	followingWindows = 3
	// entryLoadTimeout bounds the shared entry load, which runs detached from the first caller's cancellation.
	entryLoadTimeout = 5 * time.Second
)

// Request-line fields (counts and kinds only; never the query, a tag, an id or a uid).
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
	fieldDroppedInactive  = "dropped_inactive"
	fieldDroppedNotFollow = "dropped_not_following"
	fieldFromFollowing    = "from_following"
	fieldWindows          = "windows"
	fieldCacheHit         = "cache_hit"
)

// tagStore is the tag-entry cache seam (small interfaces so Memorystore can replace the instance LRU at Stage 2 with no caller change).
// Values are shared and immutable.
type tagStore interface {
	Get(tag string) ([]*posts.Post, bool)
	Set(tag string, ps []*posts.Post)
}

// PostsDeps are what SearchPosts needs beyond the flag checker. Posts, Graph, Authors and CursorKey are required:
// without them an enabled caller gets Unimplemented.
type PostsDeps struct {
	// Posts is the only way to read posts (ByHashtag).
	Posts posts.Reader
	// Graph supplies the caller's social context (cached 60 s).
	Graph graph.Reader
	// Viewer supplies liked/reposted/bookmarked flags through posts.HydrateViewer. Nil: every flag false, no read.
	Viewer posts.ViewerFlags
	// Audience is THE visibility predicate (posts.NewSnapshotAudience(protectedAuthors)). Nil is "nobody is
	// protected"; apiserver refuses to start without it.
	Audience *posts.Audience
	// Authors is the author-status check (identity.Directory): GetProfiles omits missing, SUSPENDED and DELETING accounts,
	// the rule GetPost, GetThread's context and GetUserTimeline apply. Required: nil leaves SearchPosts Unimplemented.
	Authors AuthorDirectory
	// CursorKey seals page tokens (config.CursorHMACKey).
	CursorKey []byte
	// TagEntries is the tag-entry capacity (CACHE_SEARCH_TAG_ENTRIES).
	TagEntries int
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// Option configures New.
type Option func(*service)

// WithPosts enables SearchPosts. Incomplete deps leave it disabled (Unimplemented for an enabled caller).
func WithPosts(d PostsDeps) Option {
	return func(s *service) {
		if d.Posts == nil || d.Graph == nil || d.Authors == nil || len(d.CursorKey) == 0 {
			return // fail closed: without the author-status check no row could be proven visible
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

// binding ties a page token to its caller, tag and tab. Tags never contain '|'.
func binding(uid, tag string, t tabKind) string {
	return "search|" + uid + "|" + tag + "|" + t.String()
}

// tailBinding is the binding of a LATEST tail token: the page that issued it came from a window that was not full, so the
// end of the tag was reached and every later page depends only on visible rows (part 3). The
// decoder tries binding(LATEST), then tailBinding, so both tokens stay opaque and need no new codec.
func tailBinding(uid, tag string) string {
	return "search|" + uid + "|" + tag + "|LATEST_TAIL"
}

func tokenError() error {
	return apierr.Validation("page_token", "invalid or expired page token")
}

// followingSuffix marks the binding of a from_following chain (F22), so its tokens never open an unfiltered call and the
// reverse: a token from the other mode is VALIDATION "page_token".
const followingSuffix = "|FOLLOWING"

// dropTally counts the rows a call dropped by cause (the request line).
type dropTally struct{ hidden, blocked, muted, protected, inactive, notFollowing int }

func (d dropTally) total() int {
	return d.hidden + d.blocked + d.muted + d.protected + d.inactive + d.notFollowing
}

func (d *dropTally) add(o dropTally) {
	d.hidden += o.hidden
	d.blocked += o.blocked
	d.muted += o.muted
	d.protected += o.protected
	d.inactive += o.inactive
	d.notFollowing += o.notFollowing
}

// fetched is the unfiltered rows a call works on, newest first. more is whether the window was full (the query returned as
// many rows as it asked for, or the entry held tagEntrySize), so older posts may exist below the last row.
type fetched struct {
	rows []*posts.Post
	more bool
	hit  bool
}

// search implements SearchPosts.
//
// LATEST page 1 and TOP and MEDIA page 1 at page_size <= 30 are served from the tag entry (30 posts); LATEST page 1 at
// page_size 31 to 50 queries 50. LATEST windows are fixed tiers, never the page size itself (part 3, review L-1): an
// older page queries 20 at page_size <= 20 and 50 at 21 to 50; a tail page (the token of a window that was not full, the
// end of the tag) reads the rest of the tag. The older MEDIA scan reads 30.
// An unsupported query, a grammar rejection and a bad token read nothing. The graph and userLikes
// reads are 60 s instance caches; userLikes is read only when a row is returned and engagement or bookmarks is on. The
// author-status check is one cache-first identity.Directory.GetProfiles per call with rows (F-03; a window of more than
// 50 distinct uids, authors plus embedded authors, is split into batches of 50).
//
// LATEST filters the WHOLE window (moderation, blocks, mutes, author status, Audience), then cuts to page_size, so the number of rows and
// whether a token follows depend only on the visible rows and on whether the window was full. The token position is the last
// returned row when the page was cut, else the window's last queried row; a window that was not full issues a LATEST_TAIL
// token (only when it was cut), and a tail page reads the whole rest of the tag.
//
// Staleness: the tag entry is shared across viewers and at most tagEntryTTL old; every per-viewer filter runs after it.
//
// following (F22, from_following) keeps only rows whose author the caller follows (never the caller's own) and binds the
// tokens to that mode; LATEST and MEDIA then go through searchFollowing.
func (r *postsRuntime) search(ctx context.Context, uid, rawQuery string, tab searchv1.SearchTab, pageSize int32, token string, following bool) (*searchv1.SearchPostsResponse, error) {
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
	logger.SetRequestField(ctx, fieldFromFollowing, following)
	bind, tailBind := binding(uid, tag, t), tailBinding(uid, tag)
	if following {
		bind, tailBind = bind+followingSuffix, tailBind+followingSuffix
	}

	var cur *cursor.Cursor
	tail := false // the token is a LATEST_TAIL token
	if token != "" {
		if t == tabTop { // TOP issues no token, so none can be valid for it
			return nil, tokenError()
		}
		c, err := cursor.DecodeAt(r.d.CursorKey, bind, token, r.d.Now())
		if err != nil && t == tabLatest && !following { // the tail token of a LATEST chain (a following chain issues none)
			if c, err = cursor.DecodeAt(r.d.CursorKey, tailBind, token, r.d.Now()); err == nil {
				tail = true
			}
		}
		if err != nil || cursor.IsFirstPage(c) {
			return nil, tokenError()
		}
		cur = &c
	}
	if following && t != tabTop {
		return r.searchFollowing(ctx, uid, tag, t, limit, cur, bind)
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
	fl, err := r.filter(ctx, uid, cands, following)
	if err != nil {
		return nil, err
	}
	kept, tally := fl.kept, fl.tally

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
	resp := &searchv1.SearchPostsResponse{Posts: r.views(ctx, uid, kept, fl), NormalizedTag: tag}
	if more && resume != nil {
		b := bind
		if tailToken {
			b = tailBind
		}
		resp.NextPageToken = cursor.EncodeAt(r.d.CursorKey, b, cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}, r.d.Now())
	}
	logTally(ctx, len(resp.Posts), tally)
	return resp, nil
}

// searchFollowing is LATEST and MEDIA with from_following (F22): the tab's query windows, filtered as search filters them
// plus the following rule, read one after another from the token's position until page_size rows are kept, the tag ends, or
// followingWindows windows were read (the recall limit). The kept rows are cut at page_size; the token resumes after the last
// returned row when the page was cut, else after the last QUERIED row of the last window, so a dropped row never stalls the
// chain and a page may be short or empty while a token is set. No tail token: every window is a fixed tier (fetch with tail
// false), and a window that was not full ends the chain unless the page was cut.
func (r *postsRuntime) searchFollowing(ctx context.Context, uid, tag string, t tabKind, limit int, cur *cursor.Cursor, bind string) (*searchv1.SearchPostsResponse, error) {
	var agg filtered
	var resume *posts.Post
	more, windows := false, 0
	for windows < followingWindows {
		f, err := r.fetch(ctx, uid, tag, t, limit, cur, false)
		if err != nil {
			return nil, err
		}
		if windows == 0 {
			logger.SetRequestField(ctx, fieldCacheHit, f.hit)
		}
		windows++
		cands := f.rows
		if t == tabMedia {
			cands = withOwnMedia(cands)
		}
		fl, err := r.filter(ctx, uid, cands, true)
		if err != nil {
			return nil, err
		}
		agg.merge(fl)
		more = f.more
		if len(f.rows) > 0 {
			resume = f.rows[len(f.rows)-1]
		}
		if len(agg.kept) >= limit || !more || resume == nil {
			break
		}
		cur = &cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}
	}
	logger.SetRequestField(ctx, fieldWindows, windows)
	kept := agg.kept
	if len(kept) > limit {
		kept = kept[:limit]
		resume, more = kept[limit-1], true
	}
	resp := &searchv1.SearchPostsResponse{Posts: r.views(ctx, uid, kept, agg), NormalizedTag: tag}
	if more && resume != nil {
		resp.NextPageToken = cursor.EncodeAt(r.d.CursorKey, bind, cursor.Cursor{CreatedAt: resume.CreatedAt, DocID: resume.ID}, r.d.Now())
	}
	logTally(ctx, len(resp.Posts), agg.tally)
	return resp, nil
}

// logTally writes the request-line counts of one call (counts only).
func logTally(ctx context.Context, results int, tally dropTally) {
	logger.SetRequestField(ctx, fieldResults, results)
	logger.SetRequestField(ctx, fieldDropped, tally.total())
	logger.SetRequestField(ctx, fieldDroppedHidden, tally.hidden)
	logger.SetRequestField(ctx, fieldDroppedBlocked, tally.blocked)
	logger.SetRequestField(ctx, fieldDroppedMuted, tally.muted)
	logger.SetRequestField(ctx, fieldDroppedProtected, tally.protected)
	logger.SetRequestField(ctx, fieldDroppedInactive, tally.inactive)
	logger.SetRequestField(ctx, fieldDroppedNotFollow, tally.notFollowing)
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

// entry returns the newest tagEntrySize posts of tag, unfiltered: from the instance cache or one ByHashtag.
// Concurrent misses share one load; it runs detached from the first caller's cancellation. An empty result is cached too.
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
// backfill) and not a QUOTE's embedded media.
func withOwnMedia(rows []*posts.Post) []*posts.Post {
	out := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if len(p.Media) > 0 {
			out = append(out, p)
		}
	}
	return out
}

// topScore is the TOP ranking: likes + 2 x reposts + 2 x quotes + replies, as cached (at most 60 s stale).
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

// filtered is what filter decided for one call's rows.
type filtered struct {
	// kept is a fresh slice (never the shared entry), so callers may reorder and cut it.
	kept []*posts.Post
	// embed is the PROTECTED embed state of the kept QUOTEs that carry one.
	embed map[string]postsv1.EmbedViewerState
	// gone is the kept QUOTEs whose quoted post's author is not ACTIVE: rendered with the embed tombstoned.
	gone  map[string]bool
	tally dropTally
	snap  graph.Snapshot
	// snapped is whether snap was read (filter reads it only for a non-empty window).
	snapped bool
}

// merge appends o's kept rows and decisions to f (searchFollowing's windows); the latest snapshot read wins.
func (f *filtered) merge(o filtered) {
	f.kept = append(f.kept, o.kept...)
	for id, st := range o.embed {
		if f.embed == nil {
			f.embed = map[string]postsv1.EmbedViewerState{}
		}
		f.embed[id] = st
	}
	for id := range o.gone {
		if f.gone == nil {
			f.gone = map[string]bool{}
		}
		f.gone[id] = true
	}
	f.tally.add(o.tally)
	if o.snapped {
		f.snap, f.snapped = o.snap, true
	}
}

// filter applies the per-viewer rules after the shared entry, in this order per
// row: moderation (!Visible), the blockedBy-overflow fail-closed rule, the author's and a QUOTE's embedded author's
// block / blocked-by / mute state, the author status (F-03), then posts.Audience.Decide on the list surface (protected
// authors; a QUOTE of one is kept with embed PROTECTED). The caller's own posts are kept. The graph snapshot is read once
// (cached 60 s) and only when rows exist. A protected set that cannot be trusted is UNAVAILABLE and a failed author-status
// read is an error (never a partial or unchecked page).
//
// Author status is the rule GetPost, GetThread's context and GetUserTimeline apply: an author identity.Directory.GetProfiles
// does not return (missing, SUSPENDED or DELETING) drops the row. A copy of a post whose author is not ACTIVE is shown as
// suspend-user's copy clean-up and the account purge leave it: a REPOST is dropped, a QUOTE keeps its own text with the embed
// tombstoned (gone; views renders it).
//
// following (F22) adds one free rule right after moderation: a row whose author is the caller or is not in the caller's
// following set (the 60 s snapshot, at most 5,000 accounts) is dropped (notFollowing), so the author-status batch never sees it.
func (r *postsRuntime) filter(ctx context.Context, uid string, rows []*posts.Post, following bool) (filtered, error) {
	var f filtered
	if len(rows) == 0 {
		return f, nil
	}
	snap, err := r.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return filtered{}, logger.RedactErr(fmt.Errorf("search: caller graph: %w", err), uid)
	}
	f.snap, f.snapped = snap, true
	// The free rules first, so the author-status batch holds only the authors of rows that could still be shown.
	cands := make([]*posts.Post, 0, len(rows))
	for _, p := range rows {
		if !p.Visible() {
			f.tally.hidden++
			continue
		}
		if following && (p.AuthorID == uid || !snap.Following[p.AuthorID]) {
			f.tally.notFollowing++
			continue
		}
		switch blockCause(snap, uid, p) {
		case causeBlocked:
			f.tally.blocked++
			continue
		case causeMuted:
			f.tally.muted++
			continue
		}
		cands = append(cands, p)
	}
	// One cache-first Directory read for the authors and embedded authors of the candidates (posts.ResolveActiveAuthors: the
	// caller is never asked, batches of 50, so a window of more than 50 distinct uids makes two; a failure is an error).
	active, err := posts.ResolveActiveAuthors(ctx, r.d.Authors, uid, cands)
	if err != nil {
		return filtered{}, fmt.Errorf("search: %w", err) // already redacted
	}
	f.kept = make([]*posts.Post, 0, len(cands))
	for _, p := range cands {
		verdict := active.Verdict(p)
		if verdict == posts.AuthorDrop { // the author, or the author a REPOST copies, is not ACTIVE
			f.tally.inactive++
			continue
		}
		embedGone := verdict == posts.AuthorTombstone
		d, err := r.d.Audience.Decide(ctx, uid, snap, p, posts.SurfaceList)
		if err != nil {
			return filtered{}, err // an apierr (UNAVAILABLE) passes through
		}
		if d.Verdict != posts.Show {
			f.tally.protected++
			continue
		}
		switch {
		case embedGone:
			if f.gone == nil {
				f.gone = map[string]bool{}
			}
			f.gone[p.ID] = true // the tombstone carries no author, so no embed state applies
		case d.Embed != postsv1.EmbedViewerState_EMBED_VIEWER_STATE_UNSPECIFIED:
			if f.embed == nil {
				f.embed = map[string]postsv1.EmbedViewerState{}
			}
			f.embed[p.ID] = d.Embed
		}
		f.kept = append(f.kept, p)
	}
	return f, nil
}

// Drop causes of blockCause.
const (
	causeBlocked = "blocked"
	causeMuted   = "muted"
)

// blockCause is the Home-feed rule for a visible post: causeBlocked when the author or a QUOTE's embedded
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
// row is returned; posts.HydrateViewer), the tombstone of a QUOTE whose quoted author is not ACTIVE, the PROTECTED embed
// strip and the computed wire visibility. kept is f.kept after the tab's ranking and cut.
func (r *postsRuntime) views(ctx context.Context, uid string, kept []*posts.Post, f filtered) []*postsv1.PostView {
	var vs posts.ViewerSet
	if len(kept) > 0 {
		vs = posts.HydrateViewer(ctx, r.fc, r.d.Viewer, uid)
	}
	out := make([]*postsv1.PostView, 0, len(kept))
	for _, p := range kept {
		src := p
		if f.gone[p.ID] {
			src = posts.TombstonedQuote(p)
		}
		v := posts.ToView(src, vs, uid)
		if st, ok := f.embed[p.ID]; ok {
			posts.ApplyEmbedState(v, st) // the only place the PROTECTED strip happens
		}
		posts.ApplyWireVisibility(v, r.d.Audience.ProtectedAuthor(ctx, uid, p.AuthorID, f.snap.Following[p.AuthorID]))
		out = append(out, v)
	}
	return out
}
