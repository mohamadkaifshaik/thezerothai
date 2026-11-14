// server_insights.go is the Connect handler of GetCreatorInsights (F2 Creator Studio insights, FEATURE_CREATOR_INSIGHTS).
package identity

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// CreatorInsightsFlag is the wire name of FEATURE_CREATOR_INSIGHTS: GetCreatorInsights needs it on for the caller, and
// the users/{uid}/dailyStats writers stage nothing while it is globally off.
const CreatorInsightsFlag = "creator_insights"

// GetCreatorInsights answers the caller's own insights. FEATURE_CREATOR_INSIGHTS off for the caller is
// FAILED_PRECONDITION + FEATURE_DISABLED (feature=creator_insights) before any Firestore read.
func (s *Server) GetCreatorInsights(ctx context.Context, _ *connect.Request[identityv1.GetCreatorInsightsRequest]) (*connect.Response[identityv1.GetCreatorInsightsResponse], error) {
	uid, err := callerUID(ctx)
	if err != nil {
		return nil, err
	}
	var enabled func(uid, name string) bool
	if s.flags != nil {
		enabled = s.flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, CreatorInsightsFlag); err != nil {
		logger.SetRequestField(ctx, "feature", CreatorInsightsFlag)
		return nil, flags.DisabledError().WithMeta("feature", CreatorInsightsFlag)
	}
	return nil, connect.NewError(connect.CodeUnimplemented, errors.New("identity: GetCreatorInsights is not served yet"))
}
