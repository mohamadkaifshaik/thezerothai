package timeline

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// The community feed (ADR-0031 D6). Everything GetCommunityTimeline needs lives in this file: the shared per-community entry, the
// per-viewer keep rule, the community's removed_ids and the reply hint. The Home merge, the token codec, the settle watermark and the
// audience filter are reused as they are.

// Log fields of GetCommunityTimeline: counts and enums only, never ids.
const (
	opCommunity          = "community"
	fieldCommunityRemove = "removed"
	fieldViewerRole      = "viewer_role"
)

const (
	// communityEntryMax is how many of the newest posts a shared entry keeps (ADR-0031 D6).
	communityEntryMax = 30
	// communityEntryTTL is how long an entry answers a request without a refill. STALENESS BOUND: a post created on another instance
	// shows up on this one within communityEntryTTL (60 s, the CACHE_TTL of the other community caches); a hide arrives within the 60 s
	// bound of the community document (recentRemovals), which keep applies to every entry row.
	communityEntryTTL = 60 * time.Second
	// communityEntryMaxAge is the LRU's hard expiry. An entry older than communityEntryTTL is not served but refilled incrementally from
	// its newest row, so it has to outlive the TTL. STALENESS BOUND: a row that is no longer listed (a hide that recentRemovals has since
	// dropped, or a restore that put a row back below the entry's range) is corrected within communityEntryMaxAge (5 min), when the
	// entry expires and the next call cold-fills again.
	communityEntryMaxAge = 5 * time.Minute
)

// communityEntry is one shared entry (ADR-0031 D6): the newest <= communityEntryMax posts of a community, newest first, complete from
// the first row down to the last (everything newer than the last row that existed at loadedAt is in it). Immutable once stored: a refill
// builds a new entry, so concurrent requests filter the same slices without a lock.
type communityEntry struct {
	posts []*posts.Post
	// exhaustive: the community has no post below the last row (the fill returned fewer rows than it asked for).
	exhaustive bool
	loadedAt   time.Time
}

// communityFeedState is what GetCommunityTimeline needs beyond Deps. It is set once, before the server takes traffic (SetCommunities),
// because apiserver builds communities after the timeline.
type communityFeedState struct {
	reader  communities.Reader
	entries *cache.LRU[string, *communityEntry]
}

// SetCommunities wires communities.Reader into GetCommunityTimeline and into SetHomeTabs' COMMUNITY kind. feedEntries is
// CACHE_COMMUNITY_FEED_ENTRIES (<= 0 means 100). Call it once at startup, before ListenAndServe (it is not synchronised); a server
// without it keeps both answering as before then (Unimplemented behind the flag gates, and VALIDATION tabs for a COMMUNITY tab).
func (s *Server) SetCommunities(r communities.Reader, feedEntries int) {
	if r == nil {
		return
	}
	if feedEntries <= 0 {
		feedEntries = 100
	}
	s.community = &communityFeedState{reader: r, entries: cache.New[string, *communityEntry](feedEntries, communityEntryMaxAge)}
	if s.homeTabs != nil {
		s.homeTabs.Communities = r
	}
}

// ForgetCommunityFeed drops this instance's shared entry for a community. A hide, a restore or a moderation action that lands on this
// instance calls it so the next read refills at once (ADR-0031 D6, eviction); other instances learn within the bounds above. Safe on a
// server without communities.
func (s *Server) ForgetCommunityFeed(cid string) {
	if s.community != nil {
		s.community.entries.Delete(cid)
	}
}

// communityTimeline implements GetCommunityTimeline after the gates.
func (s *Server) communityTimeline(ctx context.Context, uid string, req *timelinev1.GetCommunityTimelineRequest) (*timelinev1.GetCommunityTimelineResponse, error) {
	start := s.now()
	cid := req.GetCommunityId()
	if err := communities.ValidateCommunityID(cid); err != nil {
		return nil, err
	}
	limit := limits.ClampPageSize(req.GetPageSize())
	f := communityFeed(uid, cid)
	tok, err := s.codec.parse(f, req.GetSinceToken(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	md := tok.mode()
	logger.SetRequestField(ctx, fieldOp, opCommunity)
	logger.SetRequestField(ctx, fieldMode, string(md))
	logger.SetRequestField(ctx, fieldPageSize, limit)

	cs := s.community
	c, err := cs.reader.Get(ctx, cid)
	if err != nil {
		return nil, communityErr(err, uid, cid)
	}
	if c.Status == communities.StatusSuspended {
		return nil, communities.NotFoundError() // N3: the one NOT_FOUND, for everyone
	}
	removed, err := communityRemovals(ctx, c, tok)
	if err != nil {
		return nil, err
	}
	role, err := cs.reader.Role(ctx, cid, uid)
	if err != nil {
		return nil, communityErr(err, uid, cid)
	}
	out := &timelinev1.GetCommunityTimelineResponse{Community: communities.HeaderProto(c, role)}
	logger.SetRequestField(ctx, fieldViewerRole, out.Community.GetViewerRole().String())
	if tok.Reached {
		return out, nil // a closed gap: nothing older, the header still rides on every response
	}

	res, err := s.communityRead(ctx, cid, tok, limit, start)
	if err != nil {
		return nil, err
	}
	out.RemovedIds = removed
	logger.SetRequestField(ctx, fieldCommunityRemove, len(removed))
	logger.SetRequestField(ctx, fieldCacheHit, res.cacheHit)
	if res.empty() {
		// Nothing to filter or hydrate: no graph and no userLikes read (an empty refresh is the one query read).
		it := s.tokens(f, md, tok, Page{}, res.entries, start)
		out.SinceToken, out.NextPageToken, out.GapPageToken = it.since, it.next, it.gap
		logger.SetRequestField(ctx, fieldReturned, 0)
		logger.SetRequestField(ctx, fieldFiltered, 0)
		return out, nil
	}

	snap, err := s.deps.Graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("timeline: caller graph: %w", err), uid)
	}
	listed := removalIDs(c)
	mod := role == communities.RoleOwner || role == communities.RoleModerator
	// F14: the audience decision drops an author who blocks the viewer (its snapshot test is BlockedBy alone); a moderator keeps those rows, so
	// the decision gets a snapshot without that set. communityAuthorAllowed and embedAllowed below still run on the full snapshot.
	asnap := snap
	if mod {
		asnap.BlockedBy = nil
	}
	af := s.newAudienceFilter(ctx, uid, asnap)
	// Per viewer, after the shared entry. A hidden post has left the query, but a cached entry may still hold one: communityHidden is dropped
	// here as well, so a hidden post never shows in the feed. An id in the
	// current recentRemovals is dropped from every entry that still holds it.
	keep := func(p *posts.Post) bool {
		return p.Visible() && !listed[p.ID] && !p.CommunityHidden && communityAuthorAllowed(uid, snap, mod, p.AuthorID) && embedAllowed(snap, uid, p) && af.keep(p)
	}
	page := Merge(res.sources, limit, keep)
	if err := af.finish(); err != nil {
		return nil, err
	}
	out.Posts = s.toViews(ctx, uid, snap.Following, nil, page.Items, af.embed)
	applyCommunityReplyHint(out.Posts, page.Items, c, role)
	it := s.tokens(f, md, tok, page, res.entries, start)
	out.SinceToken, out.NextPageToken, out.GapPageToken = it.since, it.next, it.gap
	logger.SetRequestField(ctx, fieldClamped, it.clamped)
	logger.SetRequestField(ctx, fieldReturned, len(page.Items))
	logger.SetRequestField(ctx, fieldFiltered, page.Filtered)
	logger.SetRequestField(ctx, fieldGap, out.GetGapPageToken() != "")
	return out, nil
}

// communityErr maps a communities.Reader error: a missing community is the one NOT_FOUND, anything else is an internal error whose log
// line carries no id.
func communityErr(err error, uid, cid string) error {
	if errors.Is(err, communities.ErrNotFound) {
		return communities.NotFoundError()
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return err
	}
	return logger.RedactErr(fmt.Errorf("timeline: community: %w", err), uid, cid)
}

// communityResult is what the post reads of one call produced.
type communityResult struct {
	sources  []Source
	entries  []time.Time // loadedAt of the entry used (the settle watermark input); nil for older and gap pages
	cacheHit bool
}

func (r communityResult) empty() bool {
	for _, s := range r.sources {
		if len(s.Posts) > 0 {
			return false
		}
	}
	return true
}

// communityRead reads the rows the window needs. Cold opens and since refreshes go through the shared entry (a warm entry costs 0
// reads, a refill 1 + new posts); older pages and gap pages run ByCommunity directly. Every path reads at most `limit` post rows
// (at least 1 for an empty query), so the worst call is limit + 5 with the interceptor, the community, the member doc, the graph and
// userLikes (ADR-0031 D6).
func (s *Server) communityRead(ctx context.Context, cid string, tok request, limit int, start time.Time) (communityResult, error) {
	var res communityResult
	// Older and gap pages run the query directly. So does a refresh on an instance with no entry: it costs 1 + new posts, where filling the
	// entry would read a whole page (ADR-0031 D6: an empty refresh is 1 read).
	if md := tok.mode(); md == modeOlder || md == modeGap || (md == modeRefresh && !s.community.hasEntry(cid)) {
		ps, err := s.deps.Posts.ByCommunity(ctx, cid, tok.window(), limit)
		if err != nil {
			return res, logger.RedactErr(fmt.Errorf("timeline: community posts: %w", err), cid)
		}
		res.sources = []Source{{Posts: ps, Filled: len(ps) >= limit}}
		return res, nil
	}
	rows, exhaustive, loadedAt, hit, err := s.communityEntryRows(ctx, cid, limit, start)
	if err != nil {
		return res, err
	}
	res.cacheHit = hit
	res.entries = []time.Time{loadedAt}
	since := tok.Since // nil for a cold open
	win := inWindow(rows, nil, since)
	// The rows are complete from the newest down to the last one, so the window is answered when that last row is at or below the
	// since position, or when nothing exists below it.
	covered := exhaustive || len(rows) == 0 || (since != nil && Compare(PositionOf(rows[len(rows)-1]), *since) >= 0)
	if covered || len(win) >= limit {
		res.sources = []Source{{Posts: win, Filled: !covered}}
		return res, nil
	}
	// Short of a page: read the rows below the entry, at most limit - len(win) of them.
	k := limit - len(win)
	oldest := PositionOf(rows[len(rows)-1])
	older, err := s.deps.Posts.ByCommunity(ctx, cid, posts.Window{Before: &oldest, After: since}, k)
	if err != nil {
		return res, logger.RedactErr(fmt.Errorf("timeline: community posts: %w", err), cid)
	}
	res.sources = []Source{{Posts: win}, {Posts: older, Filled: len(older) >= k}}
	return res, nil
}

// communityEntryRows returns the shared entry's rows (newest first, complete down to the last row), refilling it when it is missing or
// older than communityEntryTTL. The fill is charged to the request that triggers it and reads at most `limit` rows:
//   - no entry: ByCommunity(none, limit);
//   - an expired entry: ByCommunity(After = the entry's settle watermark, limit). Fewer than limit rows come back: they are merged with
//     the old rows. A full page: the rows in between are unknown, so they replace the entry;
//   - the stored entry keeps the newest communityEntryMax rows; this call is served from everything it read.
func (s *Server) communityEntryRows(ctx context.Context, cid string, limit int, start time.Time) (rows []*posts.Post, exhaustive bool, loadedAt time.Time, hit bool, err error) {
	cs := s.community
	e, ok := cs.entries.Get(cid)
	switch {
	case ok && start.Sub(e.loadedAt) < communityEntryTTL:
		return e.posts, e.exhaustive, e.loadedAt, true, nil
	case ok:
		w := Watermark(start, []time.Time{e.loadedAt}, s.settle) // ADR-0010 D13: a post that committed late is not missed
		fresh, err := s.deps.Posts.ByCommunity(ctx, cid, posts.Window{After: &w}, limit)
		if err != nil {
			return nil, false, time.Time{}, false, logger.RedactErr(fmt.Errorf("timeline: community refill: %w", err), cid)
		}
		if len(fresh) >= limit {
			rows, exhaustive = fresh, false
		} else {
			rows, exhaustive = mergeNewestFirst(fresh, e.posts), e.exhaustive
		}
	default:
		rows, err = s.deps.Posts.ByCommunity(ctx, cid, posts.Window{}, limit)
		if err != nil {
			return nil, false, time.Time{}, false, logger.RedactErr(fmt.Errorf("timeline: community fill: %w", err), cid)
		}
		exhaustive = len(rows) < limit
	}
	stored, storedExhaustive := rows, exhaustive
	if len(stored) > communityEntryMax {
		stored, storedExhaustive = stored[:communityEntryMax], false
	}
	cs.entries.Set(cid, &communityEntry{posts: append([]*posts.Post(nil), stored...), exhaustive: storedExhaustive, loadedAt: start})
	return rows, exhaustive, start, false, nil
}

// mergeNewestFirst is the union of two newest-first lists by post id, newest first.
func mergeNewestFirst(fresh, old []*posts.Post) []*posts.Post {
	seen := make(map[string]bool, len(fresh)+len(old))
	out := make([]*posts.Post, 0, len(fresh)+len(old))
	for _, list := range [][]*posts.Post{fresh, old} {
		for _, p := range list {
			if !seen[p.ID] {
				seen[p.ID] = true
				out = append(out, p)
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return Compare(PositionOf(out[i]), PositionOf(out[j])) < 0 })
	return out
}

// removalIDs is every post id in the community's current recentRemovals (all modes).
func removalIDs(c communities.Community) map[string]bool {
	m := make(map[string]bool, len(c.RecentRemovals))
	for _, r := range c.RecentRemovals {
		m[r.PostID] = true
	}
	return m
}

// communityRemovals is the community's removed_ids for a since refresh (ADR-0031 A3, D6): the recentRemovals entries newer than the
// token's cutoff (its issue time minus posts.RemovalLag, as Home), newest first, at most 50. 0 reads: the document is already held. A
// removal the capped array has dropped since the cutoff (removalsTruncatedAt newer than it) cannot be listed, so the token is rejected
// exactly like an expired one, before any post is read; the client cold-opens.
func communityRemovals(ctx context.Context, c communities.Community, tok request) ([]string, error) {
	if tok.Since == nil {
		return nil, nil
	}
	cutoff := tok.SinceIssued.Add(-removalLag)
	if !c.RemovalsTruncatedAt.IsZero() && c.RemovalsTruncatedAt.After(cutoff) {
		logger.SetRequestField(ctx, fieldRemovedReset, true)
		return nil, apierr.Validation(fieldSince, "since_token is invalid or expired")
	}
	var rs []communities.Removal
	for _, r := range c.RecentRemovals {
		if r.At.After(cutoff) {
			rs = append(rs, r)
		}
	}
	sort.SliceStable(rs, func(i, j int) bool { return rs[i].At.After(rs[j].At) })
	if len(rs) > 50 {
		rs = rs[:50]
	}
	out := make([]string, len(rs))
	for i, r := range rs {
		out[i] = r.PostID
	}
	return out, nil
}

// communityAuthorAllowed is the per-viewer author rule of a community feed (ADR-0031 D6, D7): the viewer's own posts are kept; an author
// the viewer blocks or mutes is dropped (a moderator's own blocks and mutes still apply); an author who blocks the viewer is dropped
// except for the community's OWNER and MODERATORS, who must see raiders (F14); and a viewer whose blockedBy overflowed cannot prove an
// author does not block them, so only authors they follow stay (fail closed, the W4 rule) unless they moderate.
func communityAuthorAllowed(uid string, snap graph.Snapshot, mod bool, a string) bool {
	if a == uid {
		return true
	}
	if snap.Blocked[a] || snap.Muted[a] {
		return false
	}
	if mod {
		return true
	}
	if snap.BlockedBy[a] {
		return false
	}
	return !snap.BlockedByOverflow || snap.Following[a]
}

// applyCommunityReplyHint sets viewer_reply_permission on community rows from the role already read, in both directions (ADR-0031 A7, 0 reads;
// the literal wording of A7, so it does not depend on what posts.ToView puts there for a community post): ALLOWED for the OWNER, MODERATORS and
// MEMBERS of an ACTIVE community, NOT_ALLOWED for everyone else (not a member, banned, or the community is ARCHIVED). A community post cannot
// carry a reply policy other than EVERYONE (CreatePost refuses it), so no stricter ADR-0021 hint is overwritten. Known edge: a moderator whose
// F14-kept row is by an author who blocks them sees ALLOWED while CreatePost answers NOT_FOUND; NOT_ALLOWED would be a block oracle.
func applyCommunityReplyHint(views []*postsv1.PostView, items []*posts.Post, c communities.Community, role communities.Role) {
	can := c.Status == communities.StatusActive &&
		(role == communities.RoleOwner || role == communities.RoleModerator || role == communities.RoleMember)
	want := postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED
	if can {
		want = postsv1.ReplyPermission_REPLY_PERMISSION_ALLOWED
	}
	for i, v := range views {
		if items[i].ConversationCommunityID != "" || items[i].CommunityID != "" {
			v.ViewerReplyPermission = want
		}
	}
}

// hasEntry reports whether this instance holds a live (not LRU-expired) entry for the community.
func (c *communityFeedState) hasEntry(cid string) bool {
	_, ok := c.entries.Get(cid)
	return ok
}
