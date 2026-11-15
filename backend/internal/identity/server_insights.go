// server_insights.go is the Connect handler of GetCreatorInsights (F2 Creator Studio insights, FEATURE_CREATOR_INSIGHTS).
package identity

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// CreatorInsightsFlag is the wire name of FEATURE_CREATOR_INSIGHTS: GetCreatorInsights needs it on for the caller, and
// the users/{uid}/dailyStats writers stage nothing while it is globally off.
const CreatorInsightsFlag = "creator_insights"

// WithCreatorInsights wires the GetCreatorInsights service. Without it, a caller the flag is on for gets Unimplemented.
func WithCreatorInsights(s CreatorInsightsService) ServerOption {
	return func(srv *Server) { srv.insights = s }
}

// GetCreatorInsights answers the caller's own insights (the uid comes from the token; there is no target). The
// service checks FEATURE_CREATOR_INSIGHTS before any read (FAILED_PRECONDITION + FEATURE_DISABLED,
// feature=creator_insights).
func (s *Server) GetCreatorInsights(ctx context.Context, req *connect.Request[identityv1.GetCreatorInsightsRequest]) (*connect.Response[identityv1.GetCreatorInsightsResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	if s.insights == nil {
		var enabled func(uid, name string) bool
		if s.flags != nil {
			enabled = s.flags.Enabled
		}
		if err := flags.Guard(ctx, enabled, uid, CreatorInsightsFlag); err != nil {
			logger.SetRequestField(ctx, "feature", CreatorInsightsFlag)
			return nil, flags.DisabledError().WithMeta("feature", CreatorInsightsFlag)
		}
		return nil, connect.NewError(connect.CodeUnimplemented, errors.New("identity: GetCreatorInsights is not wired"))
	}
	out, err := s.insights.GetCreatorInsights(ctx, uid, int(req.Msg.GetWindowDays()))
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(toProtoInsights(out)), nil
}

func toProtoInsights(c CreatorInsights) *identityv1.GetCreatorInsightsResponse {
	totals := func(t InsightsTotals) *identityv1.CreatorInsightsTotals {
		return &identityv1.CreatorInsightsTotals{Impressions: t.Impressions, Engagements: t.Engagements, FollowersGained: t.FollowersGained, FollowersLost: t.FollowersLost}
	}
	window := int32(MaxInsightsWindowDays)
	if c.WindowDays > 0 && c.WindowDays < MaxInsightsWindowDays {
		window = int32(c.WindowDays) // #nosec G115 -- bounded by MaxInsightsWindowDays above
	}
	out := &identityv1.GetCreatorInsightsResponse{
		WindowDays: window, Current: totals(c.Current), Previous: totals(c.Previous),
		ImpressionsChangePct: c.ImpressionsChangePct, EngagementsChangePct: c.EngagementsChangePct,
	}
	for _, d := range c.Days {
		out.Days = append(out.Days, &identityv1.CreatorInsightsDay{Date: d.Date, Impressions: d.Impressions, Engagements: d.Engagements, FollowersGained: d.FollowersGained, FollowersLost: d.FollowersLost})
	}
	for _, p := range c.TopPosts {
		out.TopPosts = append(out.TopPosts, &identityv1.CreatorTopPost{
			PostId: p.ID, Text: p.Text, CreatedAt: timestamppb.New(p.CreatedAt), ViewCount: p.ViewCount,
			LikeCount: p.LikeCount, RepostCount: p.RepostCount, ReplyCount: p.ReplyCount, QuoteCount: p.QuoteCount,
		})
	}
	return out
}
