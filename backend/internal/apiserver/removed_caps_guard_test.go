package apiserver

import (
	"testing"

	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	listsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	notificationsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
)

// TestRemovedDailyCaps_ProceduresKeepAPerMinuteLimiter: the daily call caps on these procedures were removed, so each one is held
// only by its per-minute limiter, its own or the default bucket every uncovered procedure falls back to. The test pins both halves:
// no DailyCaps entry is left, and the config still carries the default limiter.
func TestRemovedDailyCaps_ProceduresKeepAPerMinuteLimiter(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	if rl.Default == nil {
		t.Fatal("no default per-minute limiter: every procedure without its own bucket would be unlimited")
	}
	for _, p := range []string{
		graphv1connect.GraphServiceListFollowersProcedure,
		graphv1connect.GraphServiceListFollowRequestsProcedure,
		graphv1connect.GraphServiceListSuggestedUsersProcedure,
		searchv1connect.SearchServiceSearchPeopleProcedure,
		searchv1connect.SearchServiceSearchPostsProcedure,
		searchv1connect.SearchServiceGetTrendsProcedure,
		identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
		identityv1connect.IdentityServiceDeleteAccountProcedure,
		identityv1connect.IdentityServiceRequestAccountExportProcedure,
		identityv1connect.IdentityServiceGetAccountExportProcedure,
		notificationsv1connect.NotificationServiceRegisterDeviceProcedure,
		notificationsv1connect.NotificationServiceUnregisterDeviceProcedure,
		notificationsv1connect.NotificationServiceMarkNotificationsSeenProcedure,
		engagementv1connect.EngagementServiceVotePollProcedure,
		listsv1connect.ListServiceCreateListProcedure,
		communitiesv1connect.CommunityServiceCreateCommunityProcedure,
		communitiesv1connect.CommunityServiceHideCommunityPostProcedure,
	} {
		if _, ok := rl.DailyCaps[p]; ok {
			t.Errorf("%s is still on a daily cap", p)
		}
	}
}
