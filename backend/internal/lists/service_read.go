package lists

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/pageresume"
)

var _ Reader = (*service)(nil)

// Request-line fields of the read side (ADR-0030 D12): counts and enums only.
const (
	fieldCacheHit = "cache_hit"
	// Rows dropped from a member page, by cause: members who block the list's owner, members the viewer blocks, mutes or is
	// blocked by (or, with the viewer's blockedBy overflowed, does not follow), and members that are not ACTIVE.
	fieldDroppedOwner    = "rows_dropped_owner"
	fieldDroppedViewer   = "rows_dropped_viewer"
	fieldDroppedInactive = "rows_dropped_inactive"

	tokenVersion = "v1"
)

// errPageToken is the one answer for a page token that does not open or whose payload does not parse (0 reads).
func errPageToken() error { return apierr.Validation("page_token", "page_token is invalid or expired") }

// access is what the D3 visibility check proved for one (viewer, list): the list as stored, its owner's live profile, and the
// social contexts of the viewer and of the owner (both the viewer's own graph when the viewer is the owner). The snapshots are
// loaded only when the caller asked for them or the viewer is not the owner.
type access struct {
	list       List
	isOwner    bool
	owner      identity.Profile
	viewerSnap graph.Snapshot
	ownerSnap  graph.Snapshot
}

// loadList reads the list through the instance cache (60 s staleness bound, ADR-0030 D11); a miss is one point read. The cache
// holds private and hidden lists too (Create and the member writes put them), so a hit says nothing about who may see the
// list: resolve decides. ErrNotFound for a malformed id and for a missing doc.
func (s *service) loadList(ctx context.Context, id string) (List, error) {
	if !ids.ValidPostID(id) {
		return List{}, ErrNotFound
	}
	if l, ok := s.cache.get(id); ok {
		logger.SetRequestField(ctx, fieldCacheHit, true)
		return l, nil
	}
	logger.SetRequestField(ctx, fieldCacheHit, false)
	l, err := s.d.Repo.Get(ctx, id)
	if err != nil {
		return List{}, err
	}
	s.cache.put(l)
	return l, nil
}

// hiddenFromOthers is the cheap half of D3 for a non-owner: a private or hidden list is not theirs. 0 reads.
func hiddenFromOthers(l List) bool { return l.IsPrivate || l.Hidden }

// resolve applies ADR-0030 D3 once for every read path. Order, cheapest first, each refusal the same ErrNotFound: the list
// (cache or 1 read); the owner as viewer is visible and stops here (plus their own graph when wantSnaps); for anyone else, a
// private or hidden list (0 more reads), then the viewer's blockedBy naming the owner (viewer graph), then an owner who is
// missing or not ACTIVE (profile), then an owner whose blockedBy overflowed or who blocks the viewer (owner graph; the second
// closes the gap when the viewer's own blockedBy overflowed, at no extra read).
func (s *service) resolve(ctx context.Context, viewer, listID string, wantSnaps bool) (access, error) {
	l, err := s.loadList(ctx, listID)
	if err != nil {
		return access{}, err
	}
	a := access{list: l, isOwner: l.OwnerID == viewer}
	if a.isOwner {
		if a.owner, err = s.profile(ctx, viewer); err != nil {
			return access{}, err
		}
		if wantSnaps {
			snap, err := s.social(ctx, viewer)
			if err != nil {
				return access{}, err
			}
			a.viewerSnap, a.ownerSnap = snap, snap
		}
		return a, nil
	}
	if hiddenFromOthers(l) {
		return access{}, ErrNotFound
	}
	if a.viewerSnap, err = s.social(ctx, viewer); err != nil {
		return access{}, err
	}
	if a.viewerSnap.BlockedBy[l.OwnerID] {
		return access{}, ErrNotFound
	}
	profs, err := s.d.Directory.GetProfiles(ctx, []string{l.OwnerID})
	if err != nil {
		return access{}, fmt.Errorf("lists: load owner profile: %w", err)
	}
	op, ok := profs[l.OwnerID]
	if !ok || op.Status != identity.AccountStatusActive {
		return access{}, ErrNotFound
	}
	a.owner = op
	if a.ownerSnap, err = s.social(ctx, l.OwnerID); err != nil {
		return access{}, err
	}
	if a.ownerSnap.BlockedByOverflow || a.ownerSnap.Blocked[viewer] {
		return access{}, ErrNotFound
	}
	return a, nil
}

// countKept is the member count a viewer is shown: the stored members minus those who block the owner (the F4 read-time drop).
func countKept(members []string, ownerBlockedBy map[string]bool) int {
	if len(ownerBlockedBy) == 0 {
		return len(members)
	}
	n := 0
	for _, m := range members {
		if !ownerBlockedBy[m] {
			n++
		}
	}
	return n
}

// view builds the View of a visible list. The owner as viewer sees the stored count (their own next write drops the blockers);
// anyone else sees it net of the members who block the owner.
func (a access) view() View {
	h := a.list.header()
	if !a.isOwner {
		h.MemberCount = countKept(a.list.MemberIDs, a.ownerSnap.BlockedBy)
	}
	return View{Header: h, Owner: a.owner}
}

// pinned reports whether viewer has the list pinned as a Home tab (W5-9). The source is users/{viewer}.homeTabs through
// identity.Directory, cache-first: 0 reads when the account-status interceptor has loaded the viewer's profile (the usual case),
// else 1. Staleness bound: the profile cache TTL on another instance; the writing instance is updated in place. A tab stored
// for a kind that is off for the viewer is still a pin of this list. A directory error answers false (a header flag, never a
// reason to fail a read).
func (s *service) pinned(ctx context.Context, viewer, listID string) bool {
	profs, err := s.d.Directory.GetProfiles(ctx, []string{viewer})
	if err != nil {
		return false
	}
	for _, t := range profs[viewer].HomeTabs() {
		if t.Kind == identity.HomeTabKindList && t.ID == listID {
			return true
		}
	}
	return false
}

// Get implements Reader.
func (s *service) Get(ctx context.Context, viewer, listID string) (ListView, error) {
	a, err := s.resolve(ctx, viewer, listID, false)
	if err != nil {
		return ListView{}, err
	}
	return a.view(), nil
}

// Members implements Reader. The owner as viewer reads their own graph (cache-first) for the owner-level drop; a non-owner's
// reads are already in resolve.
func (s *service) Members(ctx context.Context, viewer, listID string) (ListMembers, error) {
	a, err := s.resolve(ctx, viewer, listID, true)
	if err != nil {
		return ListMembers{}, err
	}
	kept := make([]string, 0, len(a.list.MemberIDs))
	for _, m := range a.list.MemberIDs {
		if !a.ownerSnap.BlockedBy[m] {
			kept = append(kept, m)
		}
	}
	h := a.list.header()
	h.MemberCount = len(kept)
	return ListMembers{Header: h, Owner: a.owner, MemberIDs: kept}, nil
}

// OwnedBy implements Reader: one uncached query of at most LISTS_MAX_PER_USER lists.
func (s *service) OwnedBy(ctx context.Context, uid string) ([]List, error) {
	return s.d.Repo.ListByOwner(ctx, uid, "", max(s.d.Limits.MaxPerUser, 1))
}

// GetList implements Service.
func (s *service) GetList(ctx context.Context, viewer, listID string) (View, error) {
	begin(ctx, "get")
	if err := validateListID(listID); err != nil {
		return View{}, mapErr(ctx, "get", viewer, listID, err)
	}
	v, err := s.Get(ctx, viewer, listID)
	if err != nil {
		return View{}, mapErr(ctx, "get", viewer, listID, err)
	}
	v.PinnedByViewer = s.pinned(ctx, viewer, listID)
	return v, nil
}

// ---- page tokens ----

func (s *service) sealed() error {
	if len(s.d.CursorKey) == 0 {
		return errors.New("lists: page tokens are not wired (no CursorKey)")
	}
	return nil
}

// ---- ListUserLists ----

func userListsBinding(viewer, owner string) string { return "lists|ulists|" + viewer + "|" + owner }

// decodeAfter opens a ListUserLists token to the id of the last list returned. An empty token is the first page. Pure.
func (s *service) decodeAfter(binding, token string) (string, error) {
	if token == "" {
		return "", nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return "", errPageToken()
	}
	v, id, ok := strings.Cut(cur.DocID, ":")
	if !ok || v != tokenVersion || !ids.ValidPostID(id) {
		return "", errPageToken()
	}
	return id, nil
}

func (s *service) encodeAfter(binding, id string) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: s.now(), DocID: tokenVersion + ":" + id}, s.now())
}

// ListUserLists implements Service (the proto doc comment is the contract). Order of the work: validation and the token (0
// reads); for another owner the viewer's graph (blockedBy names the owner), the owner's profile (missing or not ACTIVE), the
// owner's graph (the owner blocks the viewer; an overflowed blockedBy returns no lists); then one query of page_size + 1 docs
// (the extra row decides next_page_token and is not returned).
func (s *service) ListUserLists(ctx context.Context, viewer string, in UserListsInput) (UserLists, error) {
	begin(ctx, "user_lists")
	owner := in.OwnerID
	if owner == "" {
		owner = viewer
	}
	if in.OwnerID != "" && !ids.ValidUID(in.OwnerID) {
		return UserLists{}, mapErr(ctx, "user_lists", viewer, "", apierr.Validation("owner_id", "owner_id must be 1-128 characters of [A-Za-z0-9-]"))
	}
	own := owner == viewer
	if in.ContainsUserID != "" && (!own || !ids.ValidUID(in.ContainsUserID)) {
		return UserLists{}, mapErr(ctx, "user_lists", viewer, "", apierr.Validation("contains_user_id",
			"contains_user_id must be 1-128 characters of [A-Za-z0-9-] and is accepted only with your own lists"))
	}
	if err := s.sealed(); err != nil {
		return UserLists{}, mapErr(ctx, "user_lists", viewer, "", err)
	}
	binding := userListsBinding(viewer, owner)
	after, err := s.decodeAfter(binding, in.PageToken)
	if err != nil {
		return UserLists{}, mapErr(ctx, "user_lists", viewer, "", err)
	}
	var ownerProf identity.Profile
	var ownerBlockedBy map[string]bool
	if own {
		if ownerProf, err = s.profile(ctx, viewer); err != nil {
			return UserLists{}, mapErr(ctx, "user_lists", viewer, "", err)
		}
	} else {
		var empty bool
		if ownerProf, ownerBlockedBy, empty, err = s.otherOwner(ctx, viewer, owner); err != nil {
			return UserLists{}, mapErr(ctx, "user_lists", viewer, "", err)
		}
		if empty {
			return UserLists{}, nil
		}
	}
	size := limits.ClampPageSize(in.PageSize)
	rows, err := s.d.Repo.ListByOwner(ctx, owner, after, size+1)
	if err != nil {
		return UserLists{}, mapErr(ctx, "user_lists", viewer, "", err)
	}
	var out UserLists
	if len(rows) > size {
		rows = rows[:size]
		out.NextPageToken = s.encodeAfter(binding, rows[size-1].ID)
	}
	for _, l := range rows {
		if !own && hiddenFromOthers(l) {
			continue
		}
		h := l.header()
		if !own {
			h.MemberCount = countKept(l.MemberIDs, ownerBlockedBy)
		}
		out.Lists = append(out.Lists, View{Header: h, Owner: ownerProf})
		if in.ContainsUserID != "" && slices.Contains(l.MemberIDs, in.ContainsUserID) {
			out.ContainingIDs = append(out.ContainingIDs, l.ID)
		}
	}
	return out, nil
}

// otherOwner runs the owner-level checks of ListUserLists for an owner who is not the caller. An owner who is missing, not
// ACTIVE, who blocks the caller or whom the caller's blockedBy names, answers identity.ProfileNotFoundError (the bytes
// of GetProfile's missing-user error). empty is true for an owner whose blockedBy overflowed: no lists, not an error.
func (s *service) otherOwner(ctx context.Context, viewer, owner string) (prof identity.Profile, blockedBy map[string]bool, empty bool, err error) {
	vs, err := s.social(ctx, viewer)
	if err != nil {
		return identity.Profile{}, nil, false, err
	}
	if vs.BlockedBy[owner] {
		return identity.Profile{}, nil, false, identity.ProfileNotFoundError()
	}
	profs, err := s.d.Directory.GetProfiles(ctx, []string{owner})
	if err != nil {
		return identity.Profile{}, nil, false, fmt.Errorf("lists: load owner profile: %w", err)
	}
	p, ok := profs[owner]
	if !ok || p.Status != identity.AccountStatusActive {
		return identity.Profile{}, nil, false, identity.ProfileNotFoundError()
	}
	os, err := s.social(ctx, owner)
	if err != nil {
		return identity.Profile{}, nil, false, err
	}
	if os.Blocked[viewer] {
		return identity.Profile{}, nil, false, identity.ProfileNotFoundError()
	}
	if os.BlockedByOverflow {
		return p, nil, true, nil
	}
	return p, os.BlockedBy, false, nil
}

// ---- ListListMembers ----

func membersBinding(viewer, listID string) string { return "lists|members|" + viewer + "|" + listID }

func (s *service) encodeMembersToken(binding string, a pageresume.Anchor) string {
	payload := strings.Join([]string{tokenVersion, a.Next, a.Last, strconv.Itoa(a.NextIndex)}, ":")
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: s.now(), DocID: payload}, s.now())
}

// decodeMembersToken opens a members token. An empty token is the first page (nil). A foreign, expired, tampered or malformed
// token is VALIDATION page_token. Pure: 0 reads.
func (s *service) decodeMembersToken(binding, token string) (*pageresume.Anchor, error) {
	if token == "" {
		return nil, nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return nil, errPageToken()
	}
	parts := strings.Split(cur.DocID, ":")
	if len(parts) != 4 || parts[0] != tokenVersion || !ids.ValidUID(parts[1]) || !ids.ValidUID(parts[2]) {
		return nil, errPageToken()
	}
	idx, err := strconv.Atoi(parts[3])
	if err != nil || idx < 0 {
		return nil, errPageToken()
	}
	return &pageresume.Anchor{Next: parts[1], Last: parts[2], NextIndex: idx}, nil
}

// dropReason says why a member is left out of viewer's page before any profile is read (0 reads); "" keeps the row. Members
// who block the owner go for everyone; members the viewer blocks or mutes, or who block the viewer, go for the viewer; and when
// a non-owner viewer's own blockedBy overflowed (a blocker cannot be ruled out) only members they follow stay.
func dropReason(a access, member string) string {
	if a.ownerSnap.BlockedBy[member] {
		return fieldDroppedOwner
	}
	vs := a.viewerSnap
	if vs.BlockedBy[member] || vs.Blocked[member] || vs.Muted[member] {
		return fieldDroppedViewer
	}
	if !a.isOwner && vs.BlockedByOverflow && !vs.Following[member] {
		return fieldDroppedViewer
	}
	return ""
}

// ListListMembers implements Service. The token is opened before any read. memberIds is stored oldest first, so a page is a
// slice counted from the newest end (pageresume.Index resumes it across an add or a remove between two pages). The drops that
// need only the two graph snapshots run before the profiles are fetched (one cache-first GetProfiles for the page), then
// members that are not ACTIVE go. A page may be short while the token is set. Rows carry the viewer's relationship (0 reads).
func (s *service) ListListMembers(ctx context.Context, viewer, listID string, pageSize int32, token string) (MembersPage, error) {
	begin(ctx, "members")
	if err := validateListID(listID); err != nil {
		return MembersPage{}, mapErr(ctx, "members", viewer, listID, err)
	}
	if err := s.sealed(); err != nil {
		return MembersPage{}, mapErr(ctx, "members", viewer, listID, err)
	}
	binding := membersBinding(viewer, listID)
	anchor, err := s.decodeMembersToken(binding, token)
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", viewer, listID, err)
	}
	a, err := s.resolve(ctx, viewer, listID, true)
	if err != nil {
		return MembersPage{}, mapErr(ctx, "members", viewer, listID, err)
	}
	recent := a.list.MemberIDs // add order, newest last; the cache hands out a copy
	n := len(recent)
	start := 0
	if anchor != nil {
		start = pageresume.Index(recent, *anchor)
	}
	if start >= n {
		return MembersPage{}, nil
	}
	end := min(start+limits.ClampPageSize(pageSize), n)
	var page MembersPage
	if end < n {
		page.NextPageToken = s.encodeMembersToken(binding, pageresume.Anchor{Next: recent[n-1-end], Last: recent[n-end], NextIndex: end})
	}
	var dropped struct{ owner, viewer, inactive int }
	survivors := make([]string, 0, end-start)
	for p := start; p < end; p++ { // newest first
		m := recent[n-1-p]
		switch dropReason(a, m) {
		case fieldDroppedOwner:
			dropped.owner++
		case fieldDroppedViewer:
			dropped.viewer++
		default:
			survivors = append(survivors, m)
		}
	}
	if len(survivors) > 0 {
		profs, err := s.d.Directory.GetProfiles(ctx, survivors)
		if err != nil {
			return MembersPage{}, mapErr(ctx, "members", viewer, listID, fmt.Errorf("lists: load member profiles: %w", err))
		}
		for _, m := range survivors {
			p, ok := profs[m]
			if !ok || p.Status != identity.AccountStatusActive {
				dropped.inactive++
				continue
			}
			page.Items = append(page.Items, graph.ListItem{User: p, Relationship: graph.RelationshipFor(a.viewerSnap, m)})
		}
	}
	logger.SetRequestField(ctx, fieldDroppedOwner, dropped.owner)
	logger.SetRequestField(ctx, fieldDroppedViewer, dropped.viewer)
	logger.SetRequestField(ctx, fieldDroppedInactive, dropped.inactive)
	return page, nil
}
