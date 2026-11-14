package search

// directory.go is SearchLists and SearchCommunities (F20, F21): lists and communities by a prefix of their folded name. Search
// owns the RPCs, the flag gates and the query grammar (pkg/platform/namekey); the rows and the visibility rules belong to the
// lists and communities modules, reached through the two consumer-side seams below. Search never queries their collections.

import (
	"context"
	"errors"
	"unicode/utf8"

	communitiesv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1"
	listsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/namekey"
)

// FlagSearchLists is the wire name of FEATURE_SEARCH_LISTS: SearchLists and SearchCommunities, per caller, after FlagSearch.
const FlagSearchLists = "search_lists"

// ListSearcher is the lists seam (lists.Service satisfies it): public lists by folded-name prefix with the DiscoverLists rules.
type ListSearcher interface {
	SearchLists(ctx context.Context, viewer, prefix string, pageSize int32, pageToken string) (lists.SearchListsPage, error)
}

// CommunitySearcher is the communities seam (communities.Service satisfies it): ACTIVE communities by folded-name prefix.
type CommunitySearcher interface {
	SearchCommunities(ctx context.Context, uid, prefix string, pageSize int32, pageToken string) (communities.SearchPage, error)
}

// DirectoryDeps wires SearchLists (Lists) and SearchCommunities (Communities). A nil seam leaves its RPC Unimplemented for a
// caller the flags let through.
type DirectoryDeps struct {
	Lists       ListSearcher
	Communities CommunitySearcher
}

// WithDirectory enables SearchLists and SearchCommunities.
func WithDirectory(d DirectoryDeps) Option { return func(s *service) { s.dir = d } }

// dirQuery is the shared validation of both RPCs, before any read: page_size not negative, then the folded query.
func dirQuery(ctx context.Context, raw string, pageSize int32) (string, error) {
	if pageSize < 0 {
		return "", apierr.Validation("page_size", "page_size must not be negative")
	}
	q, err := namekey.Query(raw)
	switch {
	case errors.Is(err, namekey.ErrEmpty):
		return "", apierr.Validation("query", "query must not be empty")
	case errors.Is(err, namekey.ErrTooLong):
		return "", apierr.Validation("query", "query must be at most 30 characters")
	case err != nil:
		return "", apierr.Validation("query", "query must be valid text without control characters")
	}
	logger.SetRequestField(ctx, fieldQueryLen, utf8.RuneCountInString(q)) // never the query itself
	return q, nil
}

// dirGuard is the flag order of both RPCs: search, search_lists, then the module's own flag, each before any read.
func (s *service) dirGuard(ctx context.Context, uid, module string) error {
	for _, name := range []string{FlagSearch, FlagSearchLists, module} {
		if err := s.guard(ctx, uid, name); err != nil {
			return err
		}
	}
	return nil
}

// Lists is SearchLists. Flags search, search_lists, lists; then the grammar; then lists.Service.SearchLists. follower_count and
// followed_by_viewer are rendered only with FEATURE_LIST_FOLLOWS on for the caller (the GetList rule).
func (s *service) Lists(ctx context.Context, uid, query string, pageSize int32, pageToken string) (*searchv1.SearchListsResponse, error) {
	if err := s.dirGuard(ctx, uid, lists.FlagName); err != nil {
		return nil, err
	}
	q, err := dirQuery(ctx, query, pageSize)
	if err != nil {
		return nil, err
	}
	if s.dir.Lists == nil {
		return nil, errNotImplemented()
	}
	page, err := s.dir.Lists.SearchLists(ctx, uid, q, pageSize, pageToken)
	if err != nil {
		return nil, err // already an apierr from the lists module
	}
	follows := s.flags != nil && s.flags.Enabled(uid, lists.FollowFlagName)
	out := &searchv1.SearchListsResponse{Lists: make([]*listsv1.ListInfo, 0, len(page.Views)), NextPageToken: page.NextPageToken}
	for _, v := range page.Views {
		out.Lists = append(out.Lists, lists.WireInfo(v, follows))
	}
	logger.SetRequestField(ctx, fieldResults, len(out.Lists))
	return out, nil
}

// Communities is SearchCommunities. Flags search, search_lists, communities; then the grammar; then
// communities.Service.SearchCommunities.
func (s *service) Communities(ctx context.Context, uid, query string, pageSize int32, pageToken string) (*searchv1.SearchCommunitiesResponse, error) {
	if err := s.dirGuard(ctx, uid, communities.FlagName); err != nil {
		return nil, err
	}
	q, err := dirQuery(ctx, query, pageSize)
	if err != nil {
		return nil, err
	}
	if s.dir.Communities == nil {
		return nil, errNotImplemented()
	}
	page, err := s.dir.Communities.SearchCommunities(ctx, uid, q, pageSize, pageToken)
	if err != nil {
		return nil, err
	}
	out := &searchv1.SearchCommunitiesResponse{Communities: make([]*communitiesv1.Community, 0, len(page.Views)), NextPageToken: page.NextPageToken}
	for _, v := range page.Views {
		out.Communities = append(out.Communities, communities.WireCommunity(v))
	}
	logger.SetRequestField(ctx, fieldResults, len(out.Communities))
	return out, nil
}
