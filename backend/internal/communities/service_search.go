package communities

// service_search.go is SearchCommunityMembers (F36): find members of one community by handle prefix. The member docs
// hold no handle (D2), so the candidates are the first `limit` handles of the whole platform with that prefix (identity's
// handle-prefix query, read through search's shared 60 s prefix cache via apiserver), then one batch read of their member
// docs here. No query of communityMembers, no index, no new field.

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// MemberSearchFlagName is the wire name of FEATURE_COMMUNITY_MEMBER_SEARCH: the `feature` metadata of its FEATURE_DISABLED
// and the string in GetMe.enabled_features.
const MemberSearchFlagName = "community_member_search"

const (
	// minSearchPrefix and maxSearchPrefix bound the handle prefix (handles are 3 to 15 of [a-z0-9_]; a prefix 2 to 15),
	// the SearchPeople rule.
	minSearchPrefix = 2
	maxSearchPrefix = 15
	// defaultSearchLimit and maxSearchLimit: limit 0 means 20; anything else is clamped to 1..20 (identity's bound).
	defaultSearchLimit = 20
	maxSearchLimit     = 20
)

// HandlePrefixReader is the consumer-side seam to search's shared prefix cache (*search.PrefixCache satisfies it;
// communities never imports search). Lookup answers the RAW identity rows for a lower-cased prefix, at most limit, in
// handle order, and whether the cache answered; the slice is shared and read-only.
type HandlePrefixReader interface {
	Lookup(ctx context.Context, prefix string, limit int) ([]identity.Profile, bool, error)
}

// SearchInput is a SearchCommunityMembers request after the transport layer.
type SearchInput struct {
	CommunityID string
	Prefix      string
	Filter      MemberFilter
	Limit       int32
}

// normalizeSearchPrefix applies the prefix rule: trim, one optional leading "@", 2 to 15 of [A-Za-z0-9_], lower-cased.
func normalizeSearchPrefix(raw string) (string, error) {
	p := strings.TrimPrefix(strings.TrimSpace(raw), "@")
	if len(p) < minSearchPrefix || len(p) > maxSearchPrefix {
		return "", apierr.Validation("prefix", "prefix must be 2 to 15 handle characters")
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if c != '_' && (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
			return "", apierr.Validation("prefix", "prefix must be 2 to 15 handle characters")
		}
	}
	return strings.ToLower(p), nil
}

// searchLimit: 0 means 20; otherwise clamped to 1..20 (never a validation error).
func searchLimit(n int32) int {
	switch {
	case n == 0:
		return defaultSearchLimit
	case n < 1:
		return 1
	case n > maxSearchLimit:
		return maxSearchLimit
	}
	return int(n)
}

// memberSearchGuard is the FEATURE_COMMUNITY_MEMBER_SEARCH gate (the communities Guard already ran in the handler):
// FAILED_PRECONDITION + FEATURE_DISABLED, metadata feature=community_member_search. A nil checker is off for everyone.
func memberSearchGuard(ctx context.Context, fc FlagChecker, uid string) error {
	return guardFlag(ctx, fc, uid, MemberSearchFlagName)
}

// SearchCommunityMembers implements Service. Order, cheapest first: the flag (0 reads), the community id, prefix and
// filter (0 reads), the community (cache first; missing and SUSPENDED are the one NOT_FOUND), the BANNED gate (the
// community document alone decides), the handle candidates (the shared prefix cache, else one identity query of at most
// limit docs), one batch read of their member docs (kept when the state matches the filter), the caller's graph, and
// the rows exactly as ListCommunityMembers builds them, in handle order. No page token (approved exception).
func (s *service) SearchCommunityMembers(ctx context.Context, uid string, in SearchInput) ([]MemberItem, error) {
	begin(ctx, "member_search")
	if err := memberSearchGuard(ctx, s.d.Flags, uid); err != nil {
		return nil, err
	}
	cid := in.CommunityID
	if err := ValidateCommunityID(cid); err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, err)
	}
	prefix, err := normalizeSearchPrefix(in.Prefix)
	if err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, err)
	}
	if in.Filter != FilterJoined && in.Filter != FilterBanned {
		return nil, mapErr(ctx, "member_search", uid, cid, apierr.Validation("filter", "filter must be JOINED or BANNED"))
	}
	limit := searchLimit(in.Limit)
	logger.SetRequestField(ctx, "prefix_len", len(prefix)) // never the prefix itself
	c, err := s.loadCommunity(ctx, cid)
	if err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, err)
	}
	if c.Status == StatusSuspended {
		return nil, mapErr(ctx, "member_search", uid, cid, ErrNotFound)
	}
	isMod := c.RoleOf(uid) != RoleNone
	banned := in.Filter == FilterBanned
	if banned && !isMod {
		logger.SetRequestField(ctx, fieldOutcome, "rejected:not_moderator")
		return nil, Forbidden(ReasonNotModerator)
	}
	if s.d.Handles == nil {
		return nil, mapErr(ctx, "member_search", uid, cid, errors.New("handle prefix reader is not wired"))
	}
	cands, hit, err := s.d.Handles.Lookup(ctx, prefix, limit)
	if err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, fmt.Errorf("search handles: %w", err))
	}
	logger.SetRequestField(ctx, "prefix_cache_hit", hit)
	if len(cands) > limit {
		cands = cands[:limit]
	}
	if len(cands) == 0 {
		logger.SetRequestField(ctx, "results", 0)
		return nil, nil
	}
	uids := make([]string, len(cands))
	profiles := make(map[string]identity.Profile, len(cands))
	for i, p := range cands {
		uids[i] = p.UserID
		profiles[p.UserID] = p
	}
	docs, err := s.d.Repo.MembersByUID(ctx, cid, uids)
	if err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, err)
	}
	want := MemberJoined
	if banned {
		want = MemberBanned
	}
	rows := make([]MemberRow, 0, len(uids))
	for _, u := range uids {
		if m, ok := docs[u]; ok && m.State == want {
			rows = append(rows, MemberRow{UID: u, At: m.At})
		}
	}
	logger.SetRequestField(ctx, "non_members", len(uids)-len(rows))
	if len(rows) == 0 {
		logger.SetRequestField(ctx, "results", 0)
		return nil, nil
	}
	if s.d.Graph == nil {
		return nil, mapErr(ctx, "member_search", uid, cid, errors.New("graph reader is not wired"))
	}
	snap, err := s.d.Graph.Snapshot(ctx, uid)
	if err != nil {
		return nil, mapErr(ctx, "member_search", uid, cid, fmt.Errorf("load graph: %w", err))
	}
	items := memberItems(ctx, c, rows, profiles, snap, isMod, banned)
	logger.SetRequestField(ctx, "results", len(items))
	return items, nil
}
