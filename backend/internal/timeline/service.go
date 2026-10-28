package timeline

import (
	"context"
	"fmt"
	"sort"
	"time"

	"golang.org/x/sync/errgroup"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// chunkConcurrency bounds in-flight chunk queries (ADR-0004 decision 2).
const chunkConcurrency = 4

// userFirstPageMax is the largest page the Posts-tab author-recent entry serves (ADR-0010 D15).
const userFirstPageMax = posts.MaxRecent

// log fields (ADR-0010 D20). Counts, enums and booleans only: never ids, handles, text or tokens.
const (
	fieldOp        = "timeline_op"
	fieldMode      = "timeline_mode"
	fieldChunks    = "timeline_chunks"
	fieldFromCache = "authors_from_cache"
	fieldCacheHit  = "timeline_cache_hit"
	fieldReturned  = "items_returned"
	fieldFiltered  = "items_filtered"
	fieldGap       = "gap"
	fieldClamped   = "since_clamped"
	fieldPageSize  = "page_size"
	fieldTab       = "tab" // the effective profile tab (posts|replies|media|reposts), or tabUnknownLog (ADR-0024 D5)
	opHome         = "home"
	opUser         = "user"
)

// ProfileTabsFlagName is the wire name of FEATURE_PROFILE_TABS (ADR-0024 D9). GetUserTimeline with tab MEDIA or REPOSTS
// needs it on for the caller; Posts and Replies stay ungated. The name is repeated here, not imported from another
// module, because timeline may name only the posts, graph and identity seams. The flag must stay off in a project until
// the two W3-2 composite indexes are READY there and `opsctl backfill-has-media` has run (docs/runbooks/posts.md
// section 13): Firestore, unlike the emulator, refuses the tab queries without them.
const ProfileTabsFlagName = "profile_tabs"

// tabUnknownLog is the fieldTab value of a call whose tab number this build does not know. A constant, never the
// number: the field is a closed set of values so the log stays free of client-chosen data.
const tabUnknownLog = "unknown"

// home implements GetHomeTimeline (ADR-0004, ADR-0010 D13-D15). Reads: caller graph (cached 60 s) + one query
// per 30 uncovered authors, each at most k = ceil(2p/C') docs; worst 2 + C + 2p with the interceptor read.
func (s *Server) home(ctx context.Context, uid string, req *timelinev1.GetHomeTimelineRequest) (*timelinev1.GetHomeTimelineResponse, error) {
	start := s.now()
	limit := limits.ClampPageSize(req.GetPageSize())
	f := homeFeed(uid)
	tok, err := s.codec.parse(f, req.GetSinceToken(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	md := tok.mode()
	logger.SetRequestField(ctx, fieldOp, opHome)
	logger.SetRequestField(ctx, fieldMode, string(md))
	logger.SetRequestField(ctx, fieldPageSize, limit)
	if tok.Reached {
		return &timelinev1.GetHomeTimelineResponse{}, nil
	}

	snap, err := s.deps.Graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("timeline: caller graph: %w", err), uid)
	}
	authors := homeAuthors(uid, snap)
	// The graph is read first: the removal log answers for exactly the authors this feed shows.
	removed, err := s.removedIDs(ctx, tok, authors)
	if err != nil {
		return nil, err
	}

	res, err := s.homeSources(ctx, authors, tok, limit, start)
	if err != nil {
		return nil, err
	}
	// Defence in depth: authors were removed before querying, but a stale cached entry or a replayed own write
	// must never surface a blocked or muted author's post. The caller's own posts are always kept.
	// ADR-0025 D4: a REPOST of a protected author the caller does not follow is dropped, a QUOTE of one is stripped
	// (audienceFilter), per viewer and after the author-recent entries, so a shared cache never leaks.
	af := s.newAudienceFilter(ctx, uid, snap)
	keep := func(p *posts.Post) bool {
		return (p.AuthorID == uid || allowedAuthor(snap, p.AuthorID)) && embedAllowed(snap, uid, p) && af.keep(p)
	}
	page := Merge(res.sources, limit, keep)
	if err := af.finish(); err != nil {
		return nil, err
	}

	out := &timelinev1.GetHomeTimelineResponse{Posts: s.toViews(ctx, uid, snap.Following, page.Items, af.embed), RemovedIds: removed}
	it := s.tokens(f, md, tok, page, res.entries, start)
	out.SinceToken, out.NextPageToken, out.GapPageToken = it.since, it.next, it.gap
	logger.SetRequestField(ctx, fieldClamped, it.clamped)
	logger.SetRequestField(ctx, fieldChunks, res.chunks)
	logger.SetRequestField(ctx, fieldFromCache, res.fromHit)
	logger.SetRequestField(ctx, fieldReturned, len(page.Items))
	logger.SetRequestField(ctx, fieldFiltered, page.Filtered)
	logger.SetRequestField(ctx, fieldGap, out.GetGapPageToken() != "")
	return out, nil
}

type homeSourcesResult struct {
	sources []Source
	entries []time.Time
	fromHit int
	chunks  int
}

// homeSources reads what the window needs: covered authors from author-recent (0 reads), the rest in chunks of
// 30 with at most chunkConcurrency queries in flight.
func (s *Server) homeSources(ctx context.Context, authors []string, tok request, limit int, start time.Time) (homeSourcesResult, error) {
	var out homeSourcesResult
	after, before := tok.after(), tok.Upper

	var uncovered []string
	var pseudo Source
	for _, a := range authors {
		rec, ok := s.deps.Posts.AuthorRecent(a)
		if !ok || !covers(rec, after) {
			uncovered = append(uncovered, a)
			continue
		}
		out.fromHit++
		out.entries = append(out.entries, rec.LoadedAt)
		pseudo.Posts = append(pseudo.Posts, inWindow(rec.Posts, before, after)...)
	}
	if out.fromHit > 0 {
		out.sources = append(out.sources, pseudo)
	}

	chunks := chunk(uncovered, posts.MaxByAuthors)
	out.chunks = len(chunks)
	if len(chunks) == 0 {
		return out, nil
	}
	// k = max(1, ceil(2p/C')) where C' counts the chunks actually queried; the repo clamps a Limit to 50, so
	// "filled" is judged against the limit really used.
	k := (2*limit + len(chunks) - 1) / len(chunks)
	k = min(max(k, 1), posts.MaxLimit)

	results := make([][]*posts.Post, len(chunks))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(chunkConcurrency)
	w := tok.window()
	for i, c := range chunks {
		g.Go(func() error {
			ps, err := s.deps.Posts.ByAuthors(gctx, c, w, k)
			if err != nil {
				return logger.RedactErr(fmt.Errorf("timeline: chunk query: %w", err), c...)
			}
			results[i] = ps
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return out, err
	}
	for i, ps := range results {
		filled := len(ps) >= k
		out.sources = append(out.sources, Source{Posts: ps, Filled: filled})
		if tok.mode() == modeCold && !filled {
			s.storeChunk(chunks[i], ps, start)
		}
	}
	return out, nil
}

// storeChunk gives every author of a cold-open chunk that did not fill k an author-recent entry: the chunk
// returned everything, so an author with no posts gets an empty, non-truncated entry (free for 60 s).
func (s *Server) storeChunk(authors []string, ps []*posts.Post, loadedAt time.Time) {
	by := make(map[string][]*posts.Post, len(authors))
	for _, p := range ps {
		by[p.AuthorID] = append(by[p.AuthorID], p)
	}
	for _, a := range authors {
		mine := by[a]
		s.deps.Posts.StoreAuthorRecent(a, mine, len(mine) > posts.MaxRecent, loadedAt)
	}
}

// homeAuthors is the followees plus the caller, minus every author the caller blocks, mutes or is blocked by
// (even when a stale `following` still lists them), sorted for stable chunking.
func homeAuthors(uid string, snap graph.Snapshot) []string {
	out := make([]string, 0, len(snap.Following)+1)
	out = append(out, uid)
	for a := range snap.Following {
		if a != uid && allowedAuthor(snap, a) {
			out = append(out, a)
		}
	}
	sort.Strings(out[1:])
	return out
}

func allowedAuthor(snap graph.Snapshot, a string) bool {
	return !snap.Blocked[a] && !snap.Muted[a] && !snap.BlockedBy[a]
}

// covers reports whether a fresh entry answers the window without a query (ADR-0010 D15): it is complete
// (not truncated), or it holds an item at or below the window's lower bound, so everything above it is known.
func covers(rec posts.Recent, after *posts.Position) bool {
	if !rec.Truncated {
		return true
	}
	if after == nil || len(rec.Posts) == 0 {
		return false
	}
	return Compare(PositionOf(rec.Posts[len(rec.Posts)-1]), *after) >= 0
}

// inWindow keeps the entry's posts strictly below before and strictly above after.
func inWindow(ps []*posts.Post, before, after *posts.Position) []*posts.Post {
	out := make([]*posts.Post, 0, len(ps))
	for _, p := range ps {
		pos := PositionOf(p)
		if before != nil && Compare(pos, *before) <= 0 {
			continue
		}
		if after != nil && Compare(pos, *after) >= 0 {
			continue
		}
		out = append(out, p)
	}
	return out
}

func chunk(xs []string, n int) [][]string {
	var out [][]string
	for len(xs) > 0 {
		m := min(n, len(xs))
		out = append(out, xs[:m:m])
		xs = xs[m:]
	}
	return out
}

// issued is the token set of one response plus the since_clamped log flag.
type issued struct {
	since, next, gap string
	clamped          bool
}

// tokens fills the three response tokens (ADR-0010 D13/D14). Cold and refresh calls return a settle-watermark
// since_token; a refresh that could not reach its old since returns gap_page_token (Lower = the old since);
// scroll and gap pages return next_page_token (a gap page keeps its Lower) and no since_token.
func (s *Server) tokens(f feed, md mode, tok request, page Page, entries []time.Time, start time.Time) (it issued) {
	switch md {
	case modeCold, modeRefresh:
		w := Watermark(start, entries, s.settle)
		np, clamped := NextSince(tok.Since, page.Newest, w)
		it.clamped = clamped
		it.since = s.codec.encodeSince(f, np)
		if page.HasMore {
			if md == modeRefresh {
				it.gap = s.codec.encodePage(f, page.Last, tok.Since)
			} else {
				it.next = s.codec.encodePage(f, page.Last, nil)
			}
		}
	default:
		if page.HasMore {
			it.next = s.codec.encodePage(f, page.Last, tok.Lower)
		}
	}
	return it
}

// toViews renders a page with the viewer's state (following: the viewer's followed authors, for the wire-visibility hint): one cached userLikes read per request when FEATURE_ENGAGEMENT or
// FEATURE_BOOKMARKS is on for uid (0 when the page is empty; posts.HydrateViewer), else every flag false. Without
// engagement only the bookmarks are hydrated, so no like or repost flag leaks (ADR-0023 D5).
func (s *Server) toViews(ctx context.Context, uid string, following map[string]bool, ps []*posts.Post, embed map[string]postsv1.EmbedViewerState) []*postsv1.PostView {
	var vs posts.ViewerSet
	if len(ps) > 0 {
		vs = posts.HydrateViewer(ctx, s.deps.Flags, s.deps.Viewer, uid)
	}
	out := make([]*postsv1.PostView, 0, len(ps))
	for _, p := range ps {
		v := posts.ToView(p, vs, uid)
		if st, ok := embed[p.ID]; ok {
			posts.ApplyEmbedState(v, st) // the only place the PROTECTED strip happens (W3-29a)
			if st == postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED && p.Kind == posts.KindRepost && p.AuthorID == uid {
				v.RepostedByViewer = true // the owner's own kept REPOST: Undo repost acts on it (the userLikes list is capped and trimmed)
			}
		}
		posts.ApplyWireVisibility(v, s.aud.ProtectedAuthor(ctx, uid, p.AuthorID, following[p.AuthorID])) // FOLLOWERS while the author is protected (D2)
		out = append(out, v)
	}
	return out
}

// filterEmbeds applies embedAllowed (ADR-0018 D13) and the ADR-0025 D4 audience rules to a profile page: a REPOST of a
// protected author's post the caller may not see is dropped, a QUOTE of one is kept with a PROTECTED embed state. The
// caller's graph snapshot is the one checkVisible just read (cached), so the filter costs 0 reads. A page with no
// REPOST or QUOTE skips it. A caller viewing their own profile skips embedAllowed (their own copies are kept, D13) but
// not the audience rule: a copy of a post whose author protected since stays hidden from its copier. That case reads
// the caller's graph (+1 cold, cached 60 s) only when the page holds a copy of someone else's post.
func (s *Server) filterEmbeds(ctx context.Context, caller, target string, ps []*posts.Post) ([]*posts.Post, map[string]postsv1.EmbedViewerState, error) {
	need := false
	for _, p := range ps {
		if (p.Kind == posts.KindRepost || p.Kind == posts.KindQuote) && (caller != target || (s.aud.Enabled() && p.EmbeddedAuthor() != "" && p.EmbeddedAuthor() != caller)) {
			need = true
			break
		}
	}
	if !need {
		return ps, nil, nil
	}
	snap, err := s.deps.Graph.Snapshot(ctx, caller)
	if err != nil {
		return nil, nil, logger.RedactErr(fmt.Errorf("timeline: caller graph: %w", err), caller)
	}
	af := s.newAudienceFilter(ctx, caller, snap)
	if caller == target {
		af.surface = posts.SurfaceOwnProfile // the owner's own REPOSTs of a protected post stay as undoable PROTECTED rows (W3-36 L-2)
	}
	out := make([]*posts.Post, 0, len(ps))
	for _, p := range ps {
		if caller != target && !embedAllowed(snap, caller, p) {
			continue
		}
		if af.keep(p) {
			out = append(out, p)
		}
	}
	if err := af.finish(); err != nil {
		return nil, nil, err
	}
	return out, af.embed, nil
}

// embedAllowed is the ADR-0018 D13 feed filter: a REPOST or QUOTE is dropped when the author of the post it
// copies is blocked or muted by the viewer, or blocks the viewer, so no content of such a user leaks through a
// copy. The viewer's own copies and tombstones (no embedded author) are kept. When the viewer's blockedBy set
// overflowed it cannot prove an embedded author does not block them, so a foreign copy fails closed (the same
// choice posts makes for GetThread context; no extra graph read per row).
func embedAllowed(snap graph.Snapshot, uid string, p *posts.Post) bool {
	a := p.EmbeddedAuthor()
	if a == "" || a == uid || p.AuthorID == uid {
		return true
	}
	if snap.BlockedByOverflow {
		return false
	}
	return allowedAuthor(snap, a)
}

// user implements GetUserTimeline (ADR-0010 D6, D11, D13-D16; ADR-0024 D5). Reads: target users + caller graph (+ target
// graph when the caller's blockedBy overflowed) + one query of Limit(page_size); 0 for a Posts-tab first page
// or an empty refresh served by a fresh author-recent entry. The Media and Reposts tabs always run that one query
// (no author-recent entry) and need FEATURE_PROFILE_TABS: they are refused before any read when it is off.
func (s *Server) user(ctx context.Context, caller string, req *timelinev1.GetUserTimelineRequest) (*timelinev1.GetUserTimelineResponse, error) {
	start := s.now()
	tab, err := s.resolveTab(ctx, caller, req)
	if err != nil {
		return nil, err
	}
	target := req.GetUserId()
	if target == "" || !identity.ValidUserID(target) {
		return nil, apierr.Validation("user_id", ids.UIDMessage)
	}
	limit := limits.ClampPageSize(req.GetPageSize())
	f := userFeed(caller, target, tab)
	tok, err := s.codec.parse(f, req.GetSinceToken(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	md := tok.mode()
	logger.SetRequestField(ctx, fieldOp, opUser)
	logger.SetRequestField(ctx, fieldMode, string(md))
	logger.SetRequestField(ctx, fieldPageSize, limit)

	protected, following, err := s.checkVisible(ctx, caller, target)
	if err != nil {
		return nil, err
	}
	if protected {
		// ADR-0025 D4: decided before the author-recent cache or any page is read, whatever the tab or token. No posts,
		// no tokens, no removed_ids: the client shows the protected view and replaces its cached feed for this author.
		logger.SetRequestField(ctx, fieldAuthorProtected, true)
		return &timelinev1.GetUserTimelineResponse{AuthorProtected: true}, nil
	}
	if tok.Reached {
		return &timelinev1.GetUserTimelineResponse{}, nil
	}

	removed, err := s.removedIDs(ctx, tok, []string{target})
	if err != nil {
		return nil, err
	}

	res, err := s.userPage(ctx, target, tab, tok, limit, start)
	if err != nil {
		return nil, err
	}
	// The embed filter is a privacy rule, not a viewer feature: it applies whatever the caller's
	// FEATURE_ENGAGEMENT state is (the flags only gate viewer-flag hydration).
	items, embed, err := s.filterEmbeds(ctx, caller, target, res.page.Items)
	if err != nil {
		return nil, err
	}
	out := &timelinev1.GetUserTimelineResponse{Posts: s.toViews(ctx, caller, following, items, embed), RemovedIds: removed}
	it := s.tokens(f, md, tok, res.page, res.entries, start)
	out.SinceToken, out.NextPageToken, out.GapPageToken = it.since, it.next, it.gap
	logger.SetRequestField(ctx, fieldClamped, it.clamped)
	logger.SetRequestField(ctx, fieldCacheHit, res.cacheHit)
	logger.SetRequestField(ctx, fieldReturned, len(items))
	logger.SetRequestField(ctx, fieldFiltered, len(res.page.Items)-len(items))
	logger.SetRequestField(ctx, fieldGap, out.GetGapPageToken() != "")
	return out, nil
}

// resolveTab turns the request's tab and include_replies into the effective tab (ADR-0024 D5), logs it, and applies the
// tab's flag. It runs before any Firestore access and reads nothing:
//   - a tab number this build does not know is VALIDATION field=tab (the tab is part of the token binding, so a guess
//     could hand a client a feed that its tokens then reject);
//   - MEDIA and REPOSTS need profile_tabs on for the caller: FAILED_PRECONDITION + FEATURE_DISABLED with metadata
//     feature=profile_tabs (flags.Guard also logs feature_disabled and outcome=rejected:feature_disabled). POSTS,
//     REPLIES and UNSPECIFIED are ungated.
func (s *Server) resolveTab(ctx context.Context, caller string, req *timelinev1.GetUserTimelineRequest) (userTab, error) {
	tab, ok := effectiveTab(req.GetTab(), req.GetIncludeReplies())
	if !ok {
		logger.SetRequestField(ctx, fieldTab, tabUnknownLog)
		return "", apierr.Validation("tab", "tab is not supported")
	}
	logger.SetRequestField(ctx, fieldTab, string(tab))
	if !tab.gated() {
		return tab, nil
	}
	var enabled func(uid, name string) bool
	if s.deps.Flags != nil {
		enabled = s.deps.Flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, caller, ProfileTabsFlagName); err != nil {
		logger.SetRequestField(ctx, "feature", ProfileTabsFlagName)
		return "", flags.DisabledError().WithMeta("feature", ProfileTabsFlagName)
	}
	return tab, nil
}

// checkVisible answers NOT_FOUND, byte-identical to GetProfile's missing-user error, for a missing,
// non-ACTIVE or caller-blocking target (D6). A caller who blocks or mutes the target still sees the posts.
// After those rules it applies ADR-0025 D4: protected is true when the target is a protected account and the caller is
// neither that account nor a follower of it, so every tab answers author_protected. The decision uses the caller's
// graph snapshot checkVisible already read (it also returns the caller's following set for the wire-visibility hint, L-4) (3 cold reads: interceptor, target users, caller graph) and the detached
// protected-set loader, and runs before any page or author-recent entry is touched. A set error is UNAVAILABLE.
// Staleness bound: a follow, unfollow or toggle is seen within CACHE_TTL (60 s, the graph and set caches).
func (s *Server) checkVisible(ctx context.Context, caller, target string) (protected bool, following map[string]bool, err error) {
	profs, err := s.deps.Directory.GetProfiles(ctx, []string{target})
	if err != nil {
		return false, nil, logger.RedactErr(fmt.Errorf("timeline: target profile: %w", err), caller, target)
	}
	if _, ok := profs[target]; !ok {
		return false, nil, identity.ProfileNotFoundError()
	}
	if target == caller {
		return false, nil, nil
	}
	snap, err := s.deps.Graph.Snapshot(ctx, caller)
	if err != nil {
		return false, nil, logger.RedactErr(fmt.Errorf("timeline: caller graph: %w", err), caller, target)
	}
	if snap.BlockedBy[target] {
		return false, nil, identity.ProfileNotFoundError()
	}
	if snap.BlockedByOverflow {
		ts, err := s.deps.Graph.Snapshot(ctx, target)
		if err != nil {
			return false, nil, logger.RedactErr(fmt.Errorf("timeline: target graph: %w", err), caller, target)
		}
		if ts.Blocked[caller] {
			return false, nil, identity.ProfileNotFoundError()
		}
	}
	ok, err := s.aud.VisibleAuthor(ctx, caller, target, snap)
	if err != nil {
		return false, nil, err
	}
	return !ok, snap.Following, nil
}

type userResult struct {
	page     Page
	entries  []time.Time
	cacheHit bool
}

// userPage returns one page of target's posts: from the author-recent entry when it answers the window (Posts
// tab only), else one Limit(page_size) query (never page_size+1, D16: a full page always gets a next token). The
// Replies, Media and Reposts tabs always query; Media and Reposts have no instance cache (ADR-0024 D5).
func (s *Server) userPage(ctx context.Context, target string, tab userTab, tok request, limit int, start time.Time) (userResult, error) {
	var res userResult
	if tab == tabPosts {
		switch md := tok.mode(); {
		case md == modeCold && limit <= userFirstPageMax:
			rec, ok := s.deps.Posts.AuthorRecent(target)
			if ok && (!rec.Truncated || len(rec.Posts) >= limit) {
				res.cacheHit = true
				res.entries = []time.Time{rec.LoadedAt}
				res.page = Merge([]Source{{Posts: rec.Posts, Filled: rec.Truncated}}, limit, moderationVisible)
				return res, nil
			}
			// Miss: fill the entry with a Limit(20) query and serve the first page from it.
			ps, err := s.deps.Posts.ByAuthor(ctx, target, false, posts.Window{}, userFirstPageMax)
			if err != nil {
				return res, logger.RedactErr(fmt.Errorf("timeline: user posts: %w", err), target)
			}
			truncated := len(ps) >= userFirstPageMax
			s.deps.Posts.StoreAuthorRecent(target, ps, truncated, start)
			res.page = Merge([]Source{{Posts: ps, Filled: truncated}}, limit, moderationVisible)
			return res, nil
		case md == modeRefresh:
			if rec, ok := s.deps.Posts.AuthorRecent(target); ok && covers(rec, tok.Since) {
				res.cacheHit = true
				res.entries = []time.Time{rec.LoadedAt}
				res.page = Merge([]Source{{Posts: inWindow(rec.Posts, nil, tok.Since)}}, limit, moderationVisible)
				return res, nil
			}
		}
	}
	ps, err := s.tabQuery(ctx, target, tab, tok.window(), limit)
	if err != nil {
		return res, logger.RedactErr(fmt.Errorf("timeline: user %s: %w", tab, err), target)
	}
	res.page = Merge([]Source{{Posts: ps, Filled: len(ps) >= limit}}, limit, moderationVisible)
	return res, nil
}

// tabQuery is the one Limit(limit) query of a tab inside the window: the Posts tab's root posts, the Replies tab's
// all posts, the Media tab's hasMedia posts (ByAuthorMedia) or the Reposts tab's REPOST items (ByAuthorKind). Each
// reads one row per post returned (1 when empty). None filters visibility, blocks or mutes: the timeline does.
func (s *Server) tabQuery(ctx context.Context, target string, tab userTab, w posts.Window, limit int) ([]*posts.Post, error) {
	switch tab {
	case tabMedia:
		return s.deps.Posts.ByAuthorMedia(ctx, target, w, limit)
	case tabReposts:
		return s.deps.Posts.ByAuthorKind(ctx, target, posts.KindRepost, w, limit)
	default:
		return s.deps.Posts.ByAuthor(ctx, target, tab == tabReplies, w, limit)
	}
}

// moderationVisible keeps the posts a moderator has not hidden (ADR-0016 D3: takedown and suspension are a moderation field on
// the doc, so this filter costs no read). It deliberately does not read the stored `visibility` (always PUBLIC, ADR-0025
// D2): who may see an author is decided per viewer by posts.Audience (audienceFilter, checkVisible), never by the doc.
func moderationVisible(p *posts.Post) bool { return p.Visible() }
