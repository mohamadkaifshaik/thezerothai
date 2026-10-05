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
	opHome         = "home"
	opUser         = "user"
)

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
		return nil, fmt.Errorf("timeline: caller graph: %w", err)
	}
	authors := homeAuthors(uid, snap)

	res, err := s.homeSources(ctx, authors, tok, limit, start)
	if err != nil {
		return nil, err
	}
	// Defence in depth: authors were removed before querying, but a stale cached entry or a replayed own write
	// must never surface a blocked or muted author's post. The caller's own posts are always kept.
	keep := func(p *posts.Post) bool { return p.AuthorID == uid || allowedAuthor(snap, p.AuthorID) }
	page := Merge(res.sources, limit, keep)

	out := &timelinev1.GetHomeTimelineResponse{Posts: toViews(page.Items)}
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
				return fmt.Errorf("timeline: chunk query: %w", err)
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

func toViews(ps []*posts.Post) []*postsv1.PostView {
	out := make([]*postsv1.PostView, 0, len(ps))
	for _, p := range ps {
		out = append(out, &postsv1.PostView{Post: posts.ToProto(p)})
	}
	return out
}

// user implements GetUserTimeline (ADR-0010 D6, D11, D13-D16). Reads: target users + caller graph (+ target
// graph when the caller's blockedBy overflowed) + one query of Limit(page_size); 0 for a Posts-tab first page
// or an empty refresh served by a fresh author-recent entry.
func (s *Server) user(ctx context.Context, caller string, req *timelinev1.GetUserTimelineRequest) (*timelinev1.GetUserTimelineResponse, error) {
	start := s.now()
	target := req.GetUserId()
	if target == "" || !identity.ValidUserID(target) {
		return nil, apierr.Validation("user_id", ids.UIDMessage)
	}
	limit := limits.ClampPageSize(req.GetPageSize())
	f := userFeed(caller, target, req.GetIncludeReplies())
	tok, err := s.codec.parse(f, req.GetSinceToken(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	md := tok.mode()
	logger.SetRequestField(ctx, fieldOp, opUser)
	logger.SetRequestField(ctx, fieldMode, string(md))
	logger.SetRequestField(ctx, fieldPageSize, limit)

	if err := s.checkVisible(ctx, caller, target); err != nil {
		return nil, err
	}
	if tok.Reached {
		return &timelinev1.GetUserTimelineResponse{}, nil
	}

	res, err := s.userPage(ctx, target, req.GetIncludeReplies(), tok, limit, start)
	if err != nil {
		return nil, err
	}
	out := &timelinev1.GetUserTimelineResponse{Posts: toViews(res.page.Items)}
	it := s.tokens(f, md, tok, res.page, res.entries, start)
	out.SinceToken, out.NextPageToken, out.GapPageToken = it.since, it.next, it.gap
	logger.SetRequestField(ctx, fieldClamped, it.clamped)
	logger.SetRequestField(ctx, fieldCacheHit, res.cacheHit)
	logger.SetRequestField(ctx, fieldReturned, len(res.page.Items))
	logger.SetRequestField(ctx, fieldGap, out.GetGapPageToken() != "")
	return out, nil
}

// checkVisible answers NOT_FOUND, byte-identical to GetProfile's missing-user error, for a missing,
// non-ACTIVE or caller-blocking target (D6). A caller who blocks or mutes the target still sees the posts.
func (s *Server) checkVisible(ctx context.Context, caller, target string) error {
	profs, err := s.deps.Directory.GetProfiles(ctx, []string{target})
	if err != nil {
		return fmt.Errorf("timeline: target profile: %w", err)
	}
	if _, ok := profs[target]; !ok {
		return identity.ProfileNotFoundError()
	}
	if target == caller {
		return nil
	}
	snap, err := s.deps.Graph.Snapshot(ctx, caller)
	if err != nil {
		return fmt.Errorf("timeline: caller graph: %w", err)
	}
	if snap.BlockedBy[target] {
		return identity.ProfileNotFoundError()
	}
	if snap.BlockedByOverflow {
		ts, err := s.deps.Graph.Snapshot(ctx, target)
		if err != nil {
			return fmt.Errorf("timeline: target graph: %w", err)
		}
		if ts.Blocked[caller] {
			return identity.ProfileNotFoundError()
		}
	}
	return nil
}

type userResult struct {
	page     Page
	entries  []time.Time
	cacheHit bool
}

// userPage returns one page of target's posts: from the author-recent entry when it answers the window (Posts
// tab only), else one Limit(page_size) query (never page_size+1, D16: a full page always gets a next token).
func (s *Server) userPage(ctx context.Context, target string, includeReplies bool, tok request, limit int, start time.Time) (userResult, error) {
	var res userResult
	if !includeReplies {
		switch md := tok.mode(); {
		case md == modeCold && limit <= userFirstPageMax:
			rec, ok := s.deps.Posts.AuthorRecent(target)
			if ok && (!rec.Truncated || len(rec.Posts) >= limit) {
				res.cacheHit = true
				res.entries = []time.Time{rec.LoadedAt}
				res.page = Merge([]Source{{Posts: rec.Posts, Filled: rec.Truncated}}, limit, nil)
				return res, nil
			}
			// Miss: fill the entry with a Limit(20) query and serve the first page from it.
			ps, err := s.deps.Posts.ByAuthor(ctx, target, false, posts.Window{}, userFirstPageMax)
			if err != nil {
				return res, fmt.Errorf("timeline: user posts: %w", err)
			}
			truncated := len(ps) >= userFirstPageMax
			s.deps.Posts.StoreAuthorRecent(target, ps, truncated, start)
			res.page = Merge([]Source{{Posts: ps, Filled: truncated}}, limit, nil)
			return res, nil
		case md == modeRefresh:
			if rec, ok := s.deps.Posts.AuthorRecent(target); ok && covers(rec, tok.Since) {
				res.cacheHit = true
				res.entries = []time.Time{rec.LoadedAt}
				res.page = Merge([]Source{{Posts: inWindow(rec.Posts, nil, tok.Since)}}, limit, nil)
				return res, nil
			}
		}
	}
	ps, err := s.deps.Posts.ByAuthor(ctx, target, includeReplies, tok.window(), limit)
	if err != nil {
		return res, fmt.Errorf("timeline: user posts: %w", err)
	}
	res.page = Merge([]Source{{Posts: ps, Filled: len(ps) >= limit}}, limit, nil)
	return res, nil
}
