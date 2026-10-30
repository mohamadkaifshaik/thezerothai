package search

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

type service struct {
	flags FlagChecker
	// pr is the SearchPosts runtime (WithPosts); nil leaves SearchPosts Unimplemented for an enabled caller.
	pr *postsRuntime
}

// New builds the Service: the flag gate of each RPC, then the rules of each RPC whose option is given (WithPosts: W4-7,
// W4-8). A nil FlagChecker is off for everyone.
func New(fc FlagChecker, opts ...Option) Service {
	s := &service{flags: fc}
	for _, o := range opts {
		o(s)
	}
	return s
}

// guard is the flag gate of every method, run before any Firestore access. Disabled is FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata feature=<name>, 0 reads.
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

// People is SearchPeople. Flag: search. Skeleton (W4-3): FEATURE_DISABLED or Unimplemented, 0 reads, 0 writes.
// Worst case once built (W4-5): 22 reads at limit 20 (ADR-0028 D2), 0 writes.
func (s *service) People(ctx context.Context, uid, _ string, _ int32) (*searchv1.SearchPeopleResponse, error) {
	if err := s.guard(ctx, uid, FlagSearch); err != nil {
		return nil, err
	}
	return nil, errNotImplemented()
}

// Posts is SearchPosts. Flag: search, checked before any read. Without WithPosts: Unimplemented, 0 reads.
// Worst case (interceptor included, writes 0): 33 cold for TOP, LATEST page 1 and MEDIA page 1 (page_size <= 30) and for
// a MEDIA scan, 53 for LATEST at page_size 50, 23 / 53 for older LATEST pages at 20 / 50, 0 to 3 warm (ADR-0028 D3);
// the rules are postsRuntime.search.
func (s *service) Posts(ctx context.Context, uid, query string, tab searchv1.SearchTab, pageSize int32, pageToken string) (*searchv1.SearchPostsResponse, error) {
	if err := s.guard(ctx, uid, FlagSearch); err != nil {
		return nil, err
	}
	if s.pr == nil {
		return nil, errNotImplemented()
	}
	return s.pr.search(ctx, uid, query, tab, pageSize, pageToken)
}

// Trends is GetTrends. Flag: trends. Skeleton (W4-3): FEATURE_DISABLED or Unimplemented, 0 reads, 0 writes.
// Worst case once built (W4-9): 2 reads cold (interceptor, trends/current), 0 writes (ADR-0028 D6).
func (s *service) Trends(ctx context.Context, uid string, _ int32, _ string) (*searchv1.GetTrendsResponse, error) {
	if err := s.guard(ctx, uid, FlagTrends); err != nil {
		return nil, err
	}
	return nil, errNotImplemented()
}
