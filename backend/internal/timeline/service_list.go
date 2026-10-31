package timeline

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Log fields of GetListTimeline (ADR-0030 D12): counts and enums only, never ids.
const (
	opList            = "list"
	fieldListMembers  = "list_members"
	fieldListFiltered = "list_authors_dropped"
)

// listFlags adapts the timeline's posts.FlagChecker (Enabled only) to lists.FlagChecker. lists.Guard calls Enabled alone;
// GloballyOff is the kill-switch question for background jobs, which GetListTimeline is not.
type listFlags struct{ posts.FlagChecker }

func (listFlags) GloballyOff(string) bool { return false }

// GetListTimeline returns a list's feed (ADR-0030 D5): chronological root posts by the list's members, newest first. It is
// Home's pull-merge over the members instead of the followees (homeSources, Merge, removedIDs, the audience filter, the
// codec; no new merge, cursor or cache), with tokens bound to the caller and the list.
//
// Order: FEATURE_LISTS and FEATURE_POSTS (0 reads), list_id shape and tokens (0 reads), then lists.Reader.Members, which
// applies the D3 visibility rules and answers the one NOT_FOUND (the fixed reads), then the pull.
//
// Budget, reads including the account-status interceptor's caller `users` read; C = ceil(members / 30) <= 5 at
// LIST_MAX_MEMBERS 150, k as Home. Non-owner, cold: 6 + C + 2*page (interceptor, list, caller graph, owner profile, owner
// graph, userLikes) = 51 at page 20, 111 at page 50; the owner 4 + C + 2*page. An empty since refresh by the owner, cold:
// 3 + C. A since_token older than the instance's removal-log cache adds at most 107 (ADR-0016 window query): 218 worst.
// Authors covered by a fresh author-recent entry (shared with Home) cost 0. Planning: refresh 4 + new posts, cold open or
// older page 30. Writes 0. The removal-log refresh is detached, as for Home.
func (s *Server) GetListTimeline(ctx context.Context, req *connect.Request[timelinev1.GetListTimelineRequest]) (*connect.Response[timelinev1.GetListTimelineResponse], error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok {
		uid = ""
	}
	// The lists gate first, before any read (and before the posts gate).
	var fc lists.FlagChecker // nil = off for everyone
	if s.deps.Flags != nil {
		fc = listFlags{s.deps.Flags}
	}
	if err := lists.Guard(ctx, fc, uid); err != nil {
		return nil, err
	}
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	if uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, 0, "unauthenticated")
	}
	if s.deps.Lists == nil {
		// A process that does not wire lists keeps the route's pre-W5-8 answer.
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("timeline.v1.TimelineService.GetListTimeline is not implemented"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := s.listTimeline(ctx, uid, req.Msg)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(resp), nil
}

// listTimeline implements GetListTimeline after the gates.
func (s *Server) listTimeline(ctx context.Context, uid string, req *timelinev1.GetListTimelineRequest) (*timelinev1.GetListTimelineResponse, error) {
	start := s.now()
	listID := req.GetListId()
	if err := lists.ValidateListID(listID); err != nil {
		return nil, err
	}
	limit := limits.ClampPageSize(req.GetPageSize())
	f := listFeed(uid, listID)
	tok, err := s.codec.parse(f, req.GetSinceToken(), req.GetPageToken())
	if err != nil {
		return nil, err
	}
	md := tok.mode()
	logger.SetRequestField(ctx, fieldOp, opList)
	logger.SetRequestField(ctx, fieldMode, string(md))
	logger.SetRequestField(ctx, fieldPageSize, limit)

	// D3 and the owner-level drop live in lists.Reader; it reads the list, the owner's profile and graph, and the caller's
	// graph (cache-first). A list that stopped being readable between pages is the same NOT_FOUND as GetList.
	m, err := s.deps.Lists.Members(ctx, uid, listID)
	if err != nil {
		if errors.Is(err, lists.ErrNotFound) {
			return nil, lists.NotFoundError()
		}
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return nil, err
		}
		return nil, logger.RedactErr(fmt.Errorf("timeline: list members: %w", err), uid, listID)
	}
	logger.SetRequestField(ctx, fieldListMembers, len(m.MemberIDs))
	out := &timelinev1.GetListTimelineResponse{List: lists.MembersInfo(m)}
	if tok.Reached {
		return out, nil // a closed gap: nothing older, but the header still rides on every response
	}

	// The caller's graph: the Reader read it for its own checks and the graph module caches it 60 s, so this is a hit.
	snap, err := s.deps.Graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("timeline: caller graph: %w", err), uid)
	}
	authors := listAuthors(uid, m.MemberIDs, snap)
	logger.SetRequestField(ctx, fieldListFiltered, len(m.MemberIDs)-len(authors))

	removed, err := s.removedIDs(ctx, tok, authors)
	if err != nil {
		return nil, err
	}
	res, err := s.homeSources(ctx, authors, tok, limit, start)
	if err != nil {
		return nil, err
	}
	// Per viewer, after the shared author-recent entries: the author rule again (defence in depth against a stale entry),
	// Home's embed rule and the ADR-0025 audience decision, which here can drop a protected member's rows.
	af := s.newAudienceFilter(ctx, uid, snap)
	keep := func(p *posts.Post) bool {
		return listAuthorAllowed(uid, snap, p.AuthorID) && embedAllowed(snap, uid, p) && af.keep(p)
	}
	page := Merge(res.sources, limit, keep)
	if err := af.finish(); err != nil {
		return nil, err
	}

	out.Posts, out.RemovedIds = s.toViews(ctx, uid, snap.Following, page.Items, af.embed), removed
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

// listAuthorAllowed is the per-viewer author rule of a list (ADR-0030 D4): the caller's own posts are kept; a member the
// caller blocks, mutes or is blocked by is dropped; and a caller whose blockedBy overflowed cannot prove a member does not
// block them, so only members they follow stay (fail closed, the W4 rule). Home needs no overflow rule because its authors
// are all followees.
func listAuthorAllowed(uid string, snap graph.Snapshot, a string) bool {
	if a == uid {
		return true
	}
	if snap.BlockedByOverflow && !snap.Following[a] {
		return false
	}
	return allowedAuthor(snap, a)
}

// listAuthors is the members the caller may read, sorted for stable chunking. The caller is in it only when a member.
func listAuthors(uid string, members []string, snap graph.Snapshot) []string {
	out := make([]string, 0, len(members))
	for _, a := range members {
		if listAuthorAllowed(uid, snap, a) {
			out = append(out, a)
		}
	}
	sort.Strings(out)
	return out
}
