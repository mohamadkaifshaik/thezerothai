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
	people *people // nil until WithPeople: SearchPeople then answers Unimplemented (the W4-3 skeleton)
	// pr is the SearchPosts runtime (WithPosts); nil leaves SearchPosts Unimplemented for an enabled caller.
	pr     *postsRuntime
	trends *trendsCache // nil until WithTrends: GetTrends then answers Unimplemented for a caller the flag lets through
	now    func() time.Time
}

// WithPeople wires SearchPeople (W4-5): the identity handle reader, the graph snapshot and the prefix cache.
func WithPeople(d PeopleDeps) Option { return func(s *service) { s.people = newPeople(d) } }

// WithTrends wires GetTrends (W4-10): the store behind the 10 min instance copy of trends/current. now is the clock
// (nil: time.Now); tests pass a fake.
func WithTrends(store TrendsStore, now func() time.Time) Option {
	return func(s *service) {
		if now != nil {
			s.now = now
		}
		s.trends = newTrendsCache(store, trendsCacheTTL, s.now)
	}
}

// New builds the Service: the flag gate of each RPC, then the rules of each RPC whose option is given (WithPeople: W4-5;
// WithPosts: W4-7, W4-8; WithTrends: W4-10). A nil FlagChecker is off for everyone; an RPC whose option is missing
// answers Unimplemented to a caller its flag lets through.
func New(fc FlagChecker, opts ...Option) Service {
	s := &service{flags: fc, now: time.Now}
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
