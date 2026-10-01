// Package timeline owns the home and profile feeds (ADR-0004 algorithm, ADR-0010 slice decisions). It is
// pull-on-read and stores nothing: it reads posts through posts.Reader and the caller's social context through
// graph.Reader, and never queries `posts` or `graph` directly (ADR-0004 handoff; imports_test.go enforces that
// timeline imports only the posts and graph packages among the internal modules).
//
// T5 registers TimelineService with both RPCs behind the FEATURE_POSTS flag and otherwise Unimplemented;
// T11 (shared machinery), T12 (GetUserTimeline) and T13 (GetHomeTimeline) replace the bodies.
package timeline

import (
	"context"

	"connectrpc.com/connect"

	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// Deps is what the timeline server needs: the flag, and the two read seams it is allowed to use.
type Deps struct {
	Flags posts.FlagChecker
	Posts posts.Reader
	Graph graph.Reader
}

// Server adapts the timeline logic to timelinev1connect.TimelineServiceHandler.
type Server struct {
	timelinev1connect.UnimplementedTimelineServiceHandler
	deps Deps
}

// NewServer builds the Connect handler. Use with timelinev1connect.NewTimelineServiceHandler.
func NewServer(d Deps) *Server { return &Server{deps: d} }

var _ timelinev1connect.TimelineServiceHandler = (*Server)(nil)

// GetHomeTimeline is behind the flag and Unimplemented until T13.
func (s *Server) GetHomeTimeline(ctx context.Context, req *connect.Request[timelinev1.GetHomeTimelineRequest]) (*connect.Response[timelinev1.GetHomeTimelineResponse], error) {
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	return s.UnimplementedTimelineServiceHandler.GetHomeTimeline(ctx, req)
}

// GetUserTimeline is behind the flag and Unimplemented until T12.
func (s *Server) GetUserTimeline(ctx context.Context, req *connect.Request[timelinev1.GetUserTimelineRequest]) (*connect.Response[timelinev1.GetUserTimelineResponse], error) {
	if err := posts.GuardFeature(ctx, s.deps.Flags); err != nil {
		return nil, err
	}
	return s.UnimplementedTimelineServiceHandler.GetUserTimeline(ctx, req)
}
