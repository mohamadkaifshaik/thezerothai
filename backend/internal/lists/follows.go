package lists

// Following a public list (FEATURE_LIST_FOLLOWS), the discovery page and suggested members (FEATURE_LIST_SUGGESTIONS).
// Owner decisions for this batch are recorded in lists.v1 (the header comment): a follow marker is listFollows/{listId}_{uid};
// the list's followerCount moves in the same transaction as the marker (repo_follows.go). Visibility is decided at read
// time by resolve, so a list that turns private, is hidden, is deleted or is blocked stops being shown at once, with no
// clean-up write. The caller's own block of the owner is checked here too (resolve checks the other direction).

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// FollowFlagName is the wire name of FEATURE_LIST_FOLLOWS (lists follow, discover, the follower count).
	FollowFlagName = "list_follows"
	// SuggestionsFlagName is the wire name of FEATURE_LIST_SUGGESTIONS (suggested members on a list the caller owns).
	SuggestionsFlagName = "list_suggestions"

	// MaxFollowsPerUser is LIST_FOLLOWS_MAX_PER_USER: the follow markers one account may hold. A constant, not an env
	// var: it bounds one page of ListFollowedLists and the count the follow transaction reads.
	MaxFollowsPerUser = 100

	// suggestionsDefault and suggestionsMax are the ListSuggestedMembers page (max_results 0 => 5, clamped to 10).
	suggestionsDefault = 5
	suggestionsMax     = 10

	rpcFollowList   = "FollowList"
	rpcUnfollowList = "UnfollowList"

	limitListFollows = "list_follows"
)

// ErrFollowLimit is the repository's refusal of FollowList at MaxFollowsPerUser (LIMIT_REACHED "list_follows").
var ErrFollowLimit = errors.New("lists: follow limit reached")

// FollowRow is one follow marker as a list reader sees it: the list id and when the caller followed it.
type FollowRow struct {
	ListID    string
	CreatedAt time.Time
}

// FollowAnchor is the position after which a ListFollowedLists page starts (the last marker of the previous page).
type FollowAnchor struct {
	CreatedAt time.Time
	ListID    string
}

// DiscoverAnchor is the position after which a DiscoverLists page starts: the last list of the previous page.
type DiscoverAnchor struct {
	FollowerCount int64
	ListID        string
}

// FollowParams is one FollowList write. Refusal is the service's verdict (nil here: every refusal is decided before the
// transaction). The transaction checks visibility again on the fresh list document.
type FollowParams struct {
	UID, ListID, IdemKey, RequestHash string
	MaxFollows                        int
}

// FollowResult is what Repo.Follow answers: Written when a marker was created, Unchanged when the caller already followed
// the list or owns it (no marker written), Replayed when the idempotency document answered.
type FollowResult struct {
	Outcome Outcome
	Header  Header
}

// UnfollowParams is one UnfollowList write.
type UnfollowParams struct {
	UID, ListID, IdemKey, RequestHash string
}

// UnfollowResult is what Repo.Unfollow answers.
type UnfollowResult struct {
	Outcome Outcome
}

// FollowedListsPage is one ListFollowedLists page: the lists the caller can still see, newest follow first. A page may be
// short while NextPageToken is set (the rows the caller can no longer see are skipped).
type FollowedListsPage struct {
	Views         []View
	NextPageToken string
}

// DiscoverListsPage is one DiscoverLists page, most followed first, with the same short-page rule.
type DiscoverListsPage struct {
	Views         []View
	NextPageToken string
}

func followHash(listID string) string { return idempotency.HashRequest("follow|list_id=" + listID) }
func unfollowHash(listID string) string {
	return idempotency.HashRequest("unfollow|list_id=" + listID)
}

func followedBinding(viewer string) string { return "lists|followed|" + viewer }
func discoverBinding(viewer string) string { return "lists|discover|" + viewer }
func followTokenDoc(listID string) string  { return tokenVersion + ":" + listID }
func discoverTokenDoc(count int64, id string) string {
	return tokenVersion + ":" + strconv.FormatInt(count, 10) + ":" + id
}

// FollowList implements Service. Order: validation (no reads); resolve (the same visibility rules as GetList, cache-first). The
// owner following their own list is success with no effect. A caller who blocks the owner gets the one NOT_FOUND. Then one
// repository transaction re-checks the fresh list, creates the marker and moves followerCount.
func (s *service) FollowList(ctx context.Context, uid, key, listID string) (View, error) {
	begin(ctx, "follow")
	if err := validateKey(key); err != nil {
		return View{}, mapErr(ctx, "follow", uid, listID, err)
	}
	if err := validateListID(listID); err != nil {
		return View{}, mapErr(ctx, "follow", uid, listID, err)
	}
	a, err := s.resolve(ctx, uid, listID, true)
	if err != nil {
		return View{}, mapErr(ctx, "follow", uid, listID, err)
	}
	if a.isOwner {
		return a.view(), nil
	}
	if a.viewerSnap.Blocked[a.list.OwnerID] {
		return View{}, mapErr(ctx, "follow", uid, listID, ErrNotFound)
	}
	res, err := s.d.Repo.Follow(ctx, FollowParams{
		UID: uid, ListID: listID, IdemKey: idempotency.Key(uid, rpcFollowList, key), RequestHash: followHash(listID),
		MaxFollows: MaxFollowsPerUser,
	})
	if err != nil {
		return View{}, mapErr(ctx, "follow", uid, listID, err)
	}
	noteOutcome(ctx, res.Outcome)
	s.cache.evict(listID)
	return View{Header: res.Header, Owner: a.owner, FollowedByViewer: true}, nil
}

// UnfollowList implements Service. No visibility check: a private, hidden or deleted list can be unfollowed (the caller's own
// marker is removed; the count moves only when the list still exists). A list the caller never followed is success.
func (s *service) UnfollowList(ctx context.Context, uid, key, listID string) error {
	begin(ctx, "unfollow")
	if err := validateKey(key); err != nil {
		return mapErr(ctx, "unfollow", uid, listID, err)
	}
	if err := validateListID(listID); err != nil {
		return mapErr(ctx, "unfollow", uid, listID, err)
	}
	res, err := s.d.Repo.Unfollow(ctx, UnfollowParams{
		UID: uid, ListID: listID, IdemKey: idempotency.Key(uid, rpcUnfollowList, key), RequestHash: unfollowHash(listID),
	})
	if err != nil {
		return mapErr(ctx, "unfollow", uid, listID, err)
	}
	noteOutcome(ctx, res.Outcome)
	s.cache.evict(listID)
	return nil
}

// FollowedAmong implements Service: the viewer's follow markers for listIDs, in one batched read.
func (s *service) FollowedAmong(ctx context.Context, viewer string, listIDs []string) (map[string]bool, error) {
	valid := make([]string, 0, len(listIDs))
	for _, id := range listIDs {
		if ids.ValidPostID(id) {
			valid = append(valid, id)
		}
	}
	m, err := s.d.Repo.FollowedAmong(ctx, viewer, valid)
	if err != nil {
		return nil, fmt.Errorf("lists: followed among: %w", logger.RedactErr(err, viewer))
	}
	return m, nil
}

// ListFollowedLists implements Service: the viewer's follow markers newest first, each resolved with the visibility rules (a
// list the viewer can no longer see is skipped, not an error). Each page is read with page_size markers; the token is the
// position of the last marker read, so a short page can still have a next page.
func (s *service) ListFollowedLists(ctx context.Context, viewer string, pageSize int32, token string) (FollowedListsPage, error) {
	begin(ctx, "followed")
	if err := s.sealed(); err != nil {
		return FollowedListsPage{}, mapErr(ctx, "followed", viewer, "", err)
	}
	anchor, err := s.decodeFollowAnchor(followedBinding(viewer), token)
	if err != nil {
		return FollowedListsPage{}, mapErr(ctx, "followed", viewer, "", err)
	}
	limit := limits.ClampPageSize(pageSize)
	rows, err := s.d.Repo.FollowedPage(ctx, viewer, anchor, limit)
	if err != nil {
		return FollowedListsPage{}, mapErr(ctx, "followed", viewer, "", err)
	}
	var page FollowedListsPage
	for _, r := range rows {
		a, err := s.resolve(ctx, viewer, r.ListID, true)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return FollowedListsPage{}, mapErr(ctx, "followed", viewer, r.ListID, err)
		}
		if a.isOwner || a.viewerSnap.Blocked[a.list.OwnerID] {
			continue
		}
		v := a.view()
		v.FollowedByViewer = true
		page.Views = append(page.Views, v)
	}
	if len(rows) == limit {
		last := rows[len(rows)-1]
		page.NextPageToken = s.encodeFollowAnchor(followedBinding(viewer), last)
	}
	return page, nil
}

// DiscoverLists implements Service: public lists by follower count, most followed first (ties by list id). The repository reads
// the public, not-private rows; resolve drops every list the viewer may not see (hidden, owner not ACTIVE, a block either way,
// protected owner) and the viewer's own lists. A page may be short while NextPageToken is set.
func (s *service) DiscoverLists(ctx context.Context, viewer string, pageSize int32, token string) (DiscoverListsPage, error) {
	begin(ctx, "discover")
	if err := s.sealed(); err != nil {
		return DiscoverListsPage{}, mapErr(ctx, "discover", viewer, "", err)
	}
	anchor, err := s.decodeDiscoverAnchor(discoverBinding(viewer), token)
	if err != nil {
		return DiscoverListsPage{}, mapErr(ctx, "discover", viewer, "", err)
	}
	limit := limits.ClampPageSize(pageSize)
	rows, err := s.d.Repo.DiscoverPage(ctx, anchor, limit)
	if err != nil {
		return DiscoverListsPage{}, mapErr(ctx, "discover", viewer, "", err)
	}
	var page DiscoverListsPage
	var visible []string
	for _, l := range rows {
		a, err := s.resolve(ctx, viewer, l.ID, true)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return DiscoverListsPage{}, mapErr(ctx, "discover", viewer, l.ID, err)
		}
		if a.isOwner || a.viewerSnap.Blocked[a.list.OwnerID] {
			continue
		}
		page.Views = append(page.Views, a.view())
		visible = append(visible, l.ID)
	}
	if len(visible) > 0 {
		followed, err := s.FollowedAmong(ctx, viewer, visible)
		if err != nil {
			return DiscoverListsPage{}, mapErr(ctx, "discover", viewer, "", err)
		}
		for i := range page.Views {
			page.Views[i].FollowedByViewer = followed[page.Views[i].Header.ID]
		}
	}
	if len(rows) == limit {
		last := rows[len(rows)-1]
		page.NextPageToken = s.encodeDiscoverAnchor(discoverBinding(viewer), DiscoverAnchor{FollowerCount: int64(last.FollowerCount), ListID: last.ID})
	}
	return page, nil
}

// ListSuggestedMembers implements Service. Owner only: any other caller gets the one NOT_FOUND. Candidates are the caller's
// RecentFollowing (the newest 30 followees, newest first) minus the members and the owner; each must pass the AddMember verdict
// (targetVerdict, the same rules and the same answers). A full list (LIST_MAX_MEMBERS) has no suggestions. No cursor: the
// result is at most suggestionsMax (the ListSuggestedUsers precedent).
func (s *service) ListSuggestedMembers(ctx context.Context, uid, listID string, maxResults int32) ([]identity.Profile, error) {
	begin(ctx, "suggest")
	if err := validateListID(listID); err != nil {
		return nil, mapErr(ctx, "suggest", uid, listID, err)
	}
	a, err := s.resolve(ctx, uid, listID, true)
	if err != nil {
		return nil, mapErr(ctx, "suggest", uid, listID, err)
	}
	if !a.isOwner {
		return nil, mapErr(ctx, "suggest", uid, listID, ErrNotFound)
	}
	if s.d.Limits.MaxMembers > 0 && len(a.list.MemberIDs) >= s.d.Limits.MaxMembers {
		return nil, nil
	}
	n := suggestionsDefault
	if maxResults > 0 {
		n = min(int(maxResults), suggestionsMax)
	}
	members := make(map[string]bool, len(a.list.MemberIDs))
	for _, m := range a.list.MemberIDs {
		members[m] = true
	}
	seen := make(map[string]bool)
	var cands []string
	for _, c := range a.viewerSnap.RecentFollowing {
		if c == uid || members[c] || seen[c] || !ids.ValidUID(c) {
			continue
		}
		seen[c] = true
		cands = append(cands, c)
	}
	if len(cands) == 0 {
		return nil, nil
	}
	profs, err := s.d.Directory.GetProfiles(ctx, cands)
	if err != nil {
		return nil, mapErr(ctx, "suggest", uid, listID, fmt.Errorf("load suggestion profiles: %w", err))
	}
	out := make([]identity.Profile, 0, n)
	for _, c := range cands {
		if len(out) == n {
			break
		}
		p, found := profs[c]
		refusal, err := s.targetVerdict(ctx, uid, c, a.ownerSnap, p, found)
		if err != nil {
			return nil, mapErr(ctx, "suggest", uid, listID, err)
		}
		if refusal != nil {
			continue
		}
		out = append(out, p)
	}
	return out, nil
}

// sealedAnchorDecoder opens a page token bound to binding and returns the payload of its DocID and its CreatedAt. An empty
// token is the first page (ok false).
func (s *service) openToken(binding, token string) (cursor.Cursor, bool, error) {
	if token == "" {
		return cursor.Cursor{}, false, nil
	}
	cur, err := cursor.DecodeAt(s.d.CursorKey, binding, token, s.now())
	if err != nil || cursor.IsFirstPage(cur) {
		return cursor.Cursor{}, false, errPageToken()
	}
	return cur, true, nil
}

func (s *service) decodeFollowAnchor(binding, token string) (*FollowAnchor, error) {
	cur, ok, err := s.openToken(binding, token)
	if err != nil || !ok {
		return nil, err
	}
	v, id, found := strings.Cut(cur.DocID, ":")
	if !found || v != tokenVersion || !ids.ValidPostID(id) {
		return nil, errPageToken()
	}
	return &FollowAnchor{CreatedAt: cur.CreatedAt, ListID: id}, nil
}

func (s *service) encodeFollowAnchor(binding string, row FollowRow) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: row.CreatedAt, DocID: followTokenDoc(row.ListID)}, s.now())
}

func (s *service) decodeDiscoverAnchor(binding, token string) (*DiscoverAnchor, error) {
	cur, ok, err := s.openToken(binding, token)
	if err != nil || !ok {
		return nil, err
	}
	parts := strings.SplitN(cur.DocID, ":", 3)
	if len(parts) != 3 || parts[0] != tokenVersion || !ids.ValidPostID(parts[2]) {
		return nil, errPageToken()
	}
	count, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || count < 0 {
		return nil, errPageToken()
	}
	return &DiscoverAnchor{FollowerCount: count, ListID: parts[2]}, nil
}

func (s *service) encodeDiscoverAnchor(binding string, a DiscoverAnchor) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: s.now(), DocID: discoverTokenDoc(a.FollowerCount, a.ListID)}, s.now())
}
