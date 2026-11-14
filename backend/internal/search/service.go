package search

import (
	"context"
	"errors"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

type service struct {
	flags  FlagChecker
	people *people // nil until WithPeople: SearchPeople then answers Unimplemented (the skeleton)
	// pr is the SearchPosts runtime (WithPosts); nil leaves SearchPosts Unimplemented for an enabled caller.
	pr         *postsRuntime
	trends     *trendsCache  // nil until WithTrends: GetTrends then answers Unimplemented for a caller the flag lets through
	trendsDeny []string      // TRENDS_DENYLIST (WithTrendsDenylist), folded into trendsCache.deny by New
	dir        DirectoryDeps // SearchLists and SearchCommunities (WithDirectory); a nil seam is Unimplemented
	now        func() time.Time
}

// WithPeople wires SearchPeople: the identity handle reader, the graph snapshot and the prefix cache.
func WithPeople(d PeopleDeps) Option { return func(s *service) { s.people = newPeople(d) } }

// WithTrends wires GetTrends: the store behind the 10 min instance copy of trends/current. now is the clock
// (nil: time.Now); tests pass a fake.
func WithTrends(store TrendsStore, now func() time.Time) Option {
	return func(s *service) {
		if now != nil {
			s.now = now
		}
		s.trends = newTrendsCache(store, trendsCacheTTL, s.now)
	}
}

// WithTrendsDenylist gives GetTrends the TRENDS_DENYLIST entries (tag bodies; matched by TrendKey). It applies at serve
// time, so a denylist change takes effect on the new revision at once, no longer at the next sweep. Order among options
// does not matter.
func WithTrendsDenylist(deny []string) Option { return func(s *service) { s.trendsDeny = deny } }

// New builds the Service: the flag gate of each RPC, then the rules of each RPC whose option is given (WithPeople:;
// WithPosts:; WithTrends:). A nil FlagChecker is off for everyone; an RPC whose option is missing
// answers Unimplemented to a caller its flag lets through.
func New(fc FlagChecker, opts ...Option) Service {
	s := &service{flags: fc, now: time.Now}
	for _, o := range opts {
		o(s)
	}
	if s.trends != nil {
		s.trends.deny = trendKeySet(s.trendsDeny)
	}
	return s
}

// guard is the flag gate of every method, run before any Firestore access. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=<name>.
func (s *service) guard(ctx context.Context, uid, name string) error {
	enabled := func(uid, name string) bool { return s.flags != nil && s.flags.Enabled(uid, name) }
	err := flags.Guard(ctx, enabled, uid, name)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", name)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", name)
	}
	return err
}

// errNotImplemented is what a caller the flag lets through gets until the RPC's ticket lands. It reads nothing.
func errNotImplemented() error {
	return apierr.New(connect.CodeUnimplemented, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "not implemented yet")
}

// FlagSearchFilters is the wire name of FEATURE_SEARCH_FILTERS: SearchPostsRequest.from_following = true, per caller, after
// FlagSearch (F22).
const FlagSearchFilters = "search_filters"

// Posts is SearchPosts without from_following. Flag: search, checked before any read. Without WithPosts: Unimplemented. The
// rules are postsRuntime.search.
func (s *service) Posts(ctx context.Context, uid, query string, tab searchv1.SearchTab, pageSize int32, pageToken string) (*searchv1.SearchPostsResponse, error) {
	return s.PostsWith(ctx, uid, PostsRequest{Query: query, Tab: tab, PageSize: pageSize, PageToken: pageToken})
}

// PostsWith is SearchPosts with every request field. Flags: search, then search_filters when FromFollowing is set (a request
// without it never checks that flag), both before any read.
func (s *service) PostsWith(ctx context.Context, uid string, req PostsRequest) (*searchv1.SearchPostsResponse, error) {
	if err := s.guard(ctx, uid, FlagSearch); err != nil {
		return nil, err
	}
	if req.FromFollowing {
		if err := s.guard(ctx, uid, FlagSearchFilters); err != nil {
			return nil, err
		}
	}
	if s.pr == nil {
		return nil, errNotImplemented()
	}
	return s.pr.search(ctx, uid, req.Query, req.Tab, req.PageSize, req.PageToken, req.FromFollowing)
}
