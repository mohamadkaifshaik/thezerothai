package communities

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line fields of the two list RPCs: counts only, never an id.
const (
	fieldRowsDropped   = "rows_dropped"
	fieldDroppedBy     = "rows_dropped_by"
	causeInactive      = "inactive"
	causeBlocked       = "blocked"
	causeBlockedBy     = "blocked_by"
	cursorBindingLabel = "community_members"
)

// sharedDirectory is the Stage 0 Directory: one Firestore query behind one instance entry for DirectoryTTL. Concurrent cold callers
// share one refill (singleflight), so a burst on a cold instance costs one refill, not one per request. The refill runs detached from
// the first caller's cancellation (a follower must not inherit a canceled context) but keeps its values.
type sharedDirectory struct {
	repo Repo
	now  func() time.Time

	mu   sync.Mutex
	list []Community
	at   time.Time
	ok   bool
	sf   singleflight.Group
}

var _ Directory = (*sharedDirectory)(nil)

func (d *sharedDirectory) warm() ([]Community, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !d.ok || d.now().Sub(d.at) >= DirectoryTTL {
		return nil, false
	}
	return cloneAll(d.list), true
}

func cloneAll(in []Community) []Community {
	out := make([]Community, len(in))
	for i, c := range in {
		out[i] = clone(c)
	}
	return out
}

// Top implements Directory. Staleness bound: DirectoryTTL.
func (d *sharedDirectory) Top(ctx context.Context) ([]Community, bool, error) {
	if l, ok := d.warm(); ok {
		return l, true, nil
	}
	v, err, _ := d.sf.Do("top", func() (any, error) {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		rows, err := d.repo.ListByMemberCount(rctx, DirectoryMax)
		if err != nil {
			return nil, err
		}
		active := make([]Community, 0, len(rows))
		for _, c := range rows {
			if c.Status == StatusActive { // a SUSPENDED or ARCHIVED community is not listed (a short list is fine)
				active = append(active, c)
			}
		}
		d.mu.Lock()
		d.list, d.at, d.ok = active, d.now(), true
		d.mu.Unlock()
		return active, nil
	})
	if err != nil {
		return nil, false, err
	}
	list, _ := v.([]Community)
	return cloneAll(list), false, nil
}

// membershipsCached is the caller's communityMemberships for the directory's viewer_role only, cached 60 s per uid (staleness bound:
// a join or leave on another instance, a ban or an eraser run shows within 60 s; this instance's own Join, Leave and Create drop the
// entry at once). Join's joined cap and ListMyCommunities never use it: they read fresh.
func (s *service) membershipsCached(ctx context.Context, uid string) (Memberships, error) {
	if m, ok := s.cache.getMemberships(uid); ok {
		return m, nil
	}
	m, err := s.d.Repo.Memberships(ctx, uid)
	if err != nil {
		return Memberships{}, err
	}
	s.cache.putMemberships(uid, m)
	return m, nil
}

// ListCommunities implements Service. Not paged at Stage 0: a non-empty page_token is VALIDATION "page_token" before
// any lookup. The list is the shared Directory entry (ACTIVE only, no block filtering: D7); viewer_role comes from the community doc
// (OWNER, MODERATOR) and the caller's memberships (MEMBER, BANNED), cached 60 s.
func (s *service) ListCommunities(ctx context.Context, uid, pageToken string) ([]View, error) {
	begin(ctx, "directory")
	if pageToken != "" {
		return nil, mapErr(ctx, "directory", uid, "", apierr.Validation("page_token", "page_token must be empty: this list is not paged"))
	}
	ranked, warm, err := s.listing.Top(ctx)
	if err != nil {
		return nil, mapErr(ctx, "directory", uid, "", err)
	}
	logger.SetRequestField(ctx, fieldCacheHit, warm)
	ms, err := s.membershipsCached(ctx, uid)
	if err != nil {
		return nil, mapErr(ctx, "directory", uid, "", err)
	}
	joined, banned := setOf(ms.Joined), setOf(ms.Banned)
	out := make([]View, 0, len(ranked))
	for _, c := range ranked {
		role := c.RoleOf(uid)
		switch {
		case role != RoleNone:
		case banned[c.ID]:
			role = RoleBanned
		case joined[c.ID]:
			role = RoleMember
		}
		out = append(out, View{Community: c, Role: role})
	}
	return out, nil
}

func setOf(in []string) map[string]bool {
	m := make(map[string]bool, len(in))
	for _, v := range in {
		m[v] = true
	}
	return m
}

func membersBinding(uid, cid string, f MemberFilter) string {
	return cursorBindingLabel + "|" + uid + "|" + cid + "|" + f.String()
}

func errPageToken() *apierr.Error { return apierr.Validation("page_token", "invalid page_token") }

// ListCommunityMembers implements Service. Order, cheapest first: the community id and the sealed page token
// (a tampered, expired, foreign or wrong-filter token stops here), the community (cache first; missing and SUSPENDED
// are the one NOT_FOUND), the BANNED gate (the community document alone decides, so a member asking for BANNED stops after the community
// read), the page query, the live profiles (Directory drops accounts that are not ACTIVE) and the caller's graph.
//
// D7 drops for a caller who is not the owner or a moderator: a member the caller blocks or who blocks the caller; a muted member is
// shown. The owner and moderators see every member either way (F14), so they can ban. A token is issued whenever the query returned a
// full page (the last row queried, not the last row kept), so a page may be short while the token is set.
func (s *service) ListCommunityMembers(ctx context.Context, uid string, in MembersInput) (MembersPage, error) {
	begin(ctx, "members")
	cid := in.CommunityID
	if err := ValidateCommunityID(cid); err != nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, err)
	}
	size := limits.ClampPageSize(in.PageSize)
	binding := membersBinding(uid, cid, in.Filter)
	var after *cursor.Cursor
	if in.PageToken != "" {
		cur, err := cursor.Decode(s.d.CursorKey, binding, in.PageToken)
		if err != nil || !ids.ValidUID(cur.DocID) {
			return MembersPage{}, mapErr(ctx, "members", uid, cid, errPageToken())
		}
		after = &cur
	}
	c, err := s.loadCommunity(ctx, cid)
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, err)
	}
	if c.Status == StatusSuspended {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, ErrNotFound)
	}
	isMod := c.RoleOf(uid) != RoleNone // OWNER or MODERATOR, from the community document
	if (in.Filter == FilterBanned || in.Filter == FilterModerators) && !isMod {
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_moderator")
		return MembersPage{}, Forbidden(ReasonNotModerator)
	}
	var rows []MemberRow
	more := false
	if in.Filter == FilterModerators {
		rows, more, err = s.moderatorRows(ctx, c, size, after)
	} else {
		rows, err = s.d.Repo.ListMembers(ctx, MembersQuery{CommunityID: cid, Banned: in.Filter == FilterBanned, Limit: size, After: after})
		more = len(rows) == size
	}
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, err)
	}
	if len(rows) == 0 {
		return MembersPage{}, nil
	}
	uids := make([]string, len(rows))
	for i, r := range rows {
		uids[i] = r.UID
	}
	profiles, err := s.d.Directory.GetProfiles(ctx, uids)
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, fmt.Errorf("load members: %w", err))
	}
	if s.d.Graph == nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, errors.New("graph reader is not wired"))
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", uid, cid, fmt.Errorf("load graph: %w", err))
	}
	page := MembersPage{Items: make([]MemberItem, 0, len(rows))}
	var inactive, blocked, blockedBy int
	for _, r := range rows {
		p, ok := profiles[r.UID]
		switch {
		case !ok || p.Status != identity.AccountStatusActive:
			inactive++
			continue
		case !isMod && snap.Blocked[r.UID]:
			blocked++
			continue
		case !isMod && snap.BlockedBy[r.UID]:
			blockedBy++
			continue
		}
		role := RoleBanned
		if in.Filter != FilterBanned {
			if role = c.RoleOf(r.UID); role == RoleNone {
				role = RoleMember
			}
		}
		page.Items = append(page.Items, MemberItem{Profile: p, Since: r.At, Relationship: graph.RelationshipFor(snap, r.UID), Role: role})
	}
	logger.SetRequestField(ctx, fieldRowsDropped, inactive+blocked+blockedBy)
	logger.SetRequestField(ctx, fieldDroppedBy, map[string]int{causeInactive: inactive, causeBlocked: blocked, causeBlockedBy: blockedBy})
	if more {
		last := rows[len(rows)-1]
		page.NextPageToken = cursor.Encode(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: last.At, DocID: last.UID})
	}
	return page, nil
}
