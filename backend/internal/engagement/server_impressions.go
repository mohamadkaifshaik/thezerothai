// server_impressions.go holds the Connect handler of RecordImpressions: the flag gate, then the views through the
// Impressions seam. No business logic here.
package engagement

import (
	"context"
	"fmt"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// WithImpressions supplies the service behind RecordImpressions, overriding the default: NewServer already uses svc when
// it implements Impressions (the Module does). Without either, RecordImpressions answers Unimplemented after the flag gate.
func WithImpressions(p Impressions) ServerOption { return func(s *Server) { s.impressions = p } }

// guardImpressions is the flag gate of RecordImpressions, run before any Firestore access: FEATURE_POSTS first (the posts
// guard), then FEATURE_POST_VIEWS on for the caller (FAILED_PRECONDITION + FEATURE_DISABLED, metadata
// feature=post_views). It does not need FEATURE_ENGAGEMENT. It returns the caller's uid.
func (s *Server) guardImpressions(ctx context.Context) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx) // GuardFeature proved it is set
	if err := flags.Guard(ctx, s.flags.Enabled, uid, ImpressionsFlagName); err != nil {
		logger.SetRequestField(ctx, "feature", ImpressionsFlagName)
		return "", flags.DisabledError().WithMeta("feature", ImpressionsFlagName)
	}
	return uid, nil
}

// RecordImpressions implements the RPC; the rules are Impressions.RecordImpressions (engagement.proto). A flag, shape or
// rate-bucket refusal does no Firestore access. Success is always the empty response.
func (s *Server) RecordImpressions(ctx context.Context, req *connect.Request[engagementv1.RecordImpressionsRequest]) (*connect.Response[engagementv1.RecordImpressionsResponse], error) {
	uid, err := s.guardImpressions(ctx)
	if err != nil {
		return nil, err
	}
	if s.impressions == nil {
		return nil, connect.NewError(connect.CodeUnimplemented, fmt.Errorf("RecordImpressions is not wired"))
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	if err := s.impressions.RecordImpressions(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetPostIds()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&engagementv1.RecordImpressionsResponse{}), nil
}
