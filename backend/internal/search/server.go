// server.go is the thin Connect handler for SearchService: caller uid, deadline, Service. The flag check lives in the
// service layer (service.go), so a later split of the module keeps it; no business logic and no Firestore here.
package search

import (
	"context"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

// rpcDeadline bounds one search call (<= 10 s, go-service skill).
const rpcDeadline = 8 * time.Second

// Server adapts Service to searchv1connect.SearchServiceHandler.
type Server struct {
	searchv1connect.UnimplementedSearchServiceHandler
	svc Service
}

// NewServer builds the Connect handler. Use with searchv1connect.NewSearchServiceHandler.
func NewServer(svc Service) *Server { return &Server{svc: svc} }

var _ searchv1connect.SearchServiceHandler = (*Server)(nil)

// call is the shared RPC shell: caller uid from the token, the deadline, the service method. The errors the service
// returns are apierr errors (FEATURE_DISABLED, VALIDATION, ...) that the error middleware converts.
func call[Req, Resp any](ctx context.Context, req *connect.Request[Req], fn func(context.Context, string, *Req) (*Resp, error)) (*connect.Response[Resp], error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return nil, apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	resp, err := fn(ctx, uid, req.Msg)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(resp), nil
}

// SearchPeople implements the RPC; the rules are Service.People.
func (s *Server) SearchPeople(ctx context.Context, req *connect.Request[searchv1.SearchPeopleRequest]) (*connect.Response[searchv1.SearchPeopleResponse], error) {
	return call(ctx, req, func(ctx context.Context, uid string, m *searchv1.SearchPeopleRequest) (*searchv1.SearchPeopleResponse, error) {
		return s.svc.People(ctx, uid, m.GetQuery(), m.GetLimit())
	})
}

// SearchPosts implements the RPC; the rules are Service.Posts.
func (s *Server) SearchPosts(ctx context.Context, req *connect.Request[searchv1.SearchPostsRequest]) (*connect.Response[searchv1.SearchPostsResponse], error) {
	return call(ctx, req, func(ctx context.Context, uid string, m *searchv1.SearchPostsRequest) (*searchv1.SearchPostsResponse, error) {
		return s.svc.Posts(ctx, uid, m.GetQuery(), m.GetTab(), m.GetPageSize(), m.GetPageToken())
	})
}

// GetTrends implements the RPC; the rules are Service.Trends.
func (s *Server) GetTrends(ctx context.Context, req *connect.Request[searchv1.GetTrendsRequest]) (*connect.Response[searchv1.GetTrendsResponse], error) {
	return call(ctx, req, func(ctx context.Context, uid string, m *searchv1.GetTrendsRequest) (*searchv1.GetTrendsResponse, error) {
		return s.svc.Trends(ctx, uid, m.GetLimit(), m.GetPrefix())
	})
}
