package apiserver

import (
	"fmt"
	"sort"
	"strings"
	"testing"

	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	messagingv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// expectedDailyCaps is the exact set of per-uid daily call caps the interceptor carries: limit name -> procedures that draw on it.
// Any other procedure on any cap, a missing entry, or a different name fails the test, so a removed cap cannot come back and a kept
// one cannot be dropped unnoticed. Caps drawn on by a service rather than the interceptor (the per-community post cap, the new-account
// send tier, Vision units, notification recipients) are not here.
var expectedDailyCaps = map[string][]string{
	"graph_mutation_daily": {
		graphv1connect.GraphServiceFollowProcedure, graphv1connect.GraphServiceUnfollowProcedure,
		graphv1connect.GraphServiceBlockProcedure, graphv1connect.GraphServiceUnblockProcedure,
		graphv1connect.GraphServiceMuteProcedure, graphv1connect.GraphServiceUnmuteProcedure,
	},
	"bookmark_mutation_daily": {
		engagementv1connect.EngagementServiceAddBookmarkProcedure, engagementv1connect.EngagementServiceRemoveBookmarkProcedure,
	},
	"messages_daily":           {messagingv1connect.MessagingServiceSendMessageProcedure},
	"messages_mark_read_daily": {messagingv1connect.MessagingServiceMarkConversationReadProcedure},
	"messages_mutation_daily": {
		messagingv1connect.MessagingServiceAcceptMessageRequestProcedure, messagingv1connect.MessagingServiceDeleteConversationProcedure,
	},
	"profile_update_daily": {identityv1connect.IdentityServiceUpdateProfileProcedure},
	"community_mod_actions_daily": {
		communitiesv1connect.CommunityServiceHideCommunityPostProcedure, communitiesv1connect.CommunityServiceSetMemberRoleProcedure,
	},
	"search_people_daily": {searchv1connect.SearchServiceSearchPeopleProcedure},
	"follow_list_daily": {
		graphv1connect.GraphServiceListFollowersProcedure, graphv1connect.GraphServiceListFollowingProcedure,
	},
}

// requiredPerProcedureBuckets are procedures whose own per-minute bucket must stay: they once had a daily cap and the per-minute
// limiter is what holds them now.
var requiredPerProcedureBuckets = []string{
	graphv1connect.GraphServiceListFollowersProcedure,
	graphv1connect.GraphServiceListFollowingProcedure,
	graphv1connect.GraphServiceListBlockedUsersProcedure,
	graphv1connect.GraphServiceListMutedUsersProcedure,
	graphv1connect.GraphServiceListFollowRequestsProcedure,
	identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure,
}

// dailyCapInventoryViolations compares the config's DailyCaps with expectedDailyCaps exactly (procedure and name, non-nil cap,
// one shared counter per name) and checks the default limiter and the required per-procedure buckets.
func dailyCapInventoryViolations(rl ratelimit.Config) []string {
	var out []string
	want := map[string]string{} // procedure -> limit name
	for name, procs := range expectedDailyCaps {
		for _, p := range procs {
			want[p] = name
		}
	}
	got := map[string]string{}
	counters := map[string]*ratelimit.DailyCap{} // limit name -> the counter its first procedure holds
	for p, n := range rl.DailyCaps {
		got[p] = n.Name
		if n.Cap == nil {
			out = append(out, "daily cap entry "+p+" has a nil cap")
			continue
		}
		if first, ok := counters[n.Name]; !ok {
			counters[n.Name] = n.Cap
		} else if first != n.Cap {
			out = append(out, fmt.Sprintf("daily cap %s is not one shared counter (see %s)", n.Name, p))
		}
	}
	for p, name := range got {
		if wn, ok := want[p]; !ok {
			out = append(out, fmt.Sprintf("unexpected daily cap %q on %s", name, p))
		} else if wn != name {
			out = append(out, fmt.Sprintf("daily cap on %s is named %q, want %q", p, name, wn))
		}
	}
	for p, name := range want {
		if _, ok := got[p]; !ok {
			out = append(out, fmt.Sprintf("missing daily cap %q on %s", name, p))
		}
	}
	if rl.Default == nil {
		out = append(out, "no default per-minute limiter: every procedure without its own bucket would be unlimited")
	}
	for _, p := range requiredPerProcedureBuckets {
		if rl.PerProcedure[p] == nil {
			out = append(out, "no per-minute bucket on "+p)
		}
	}
	sort.Strings(out)
	return out
}

// TestDailyCapInventory_IsExact: the shipped wiring carries exactly expectedDailyCaps, and the guard fails when a cap is added on
// another procedure, renamed, dropped, split into its own counter, or when a required per-minute bucket is dropped.
func TestDailyCapInventory_IsExact(t *testing.T) {
	extra := func() ratelimit.NamedDailyCap {
		return ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(10)}
	}
	following := graphv1connect.GraphServiceListFollowingProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"a cap returns on ListBlockedUsers", func(c *ratelimit.Config) {
			c.DailyCaps[graphv1connect.GraphServiceListBlockedUsersProcedure] = extra()
		}, "unexpected daily cap"},
		{"the old graph_list_daily returns on ListFollowRequests", func(c *ratelimit.Config) {
			c.DailyCaps[graphv1connect.GraphServiceListFollowRequestsProcedure] = ratelimit.NamedDailyCap{Name: "graph_list_daily", Cap: ratelimit.NewDailyCap(100)}
		}, "unexpected daily cap \"graph_list_daily\""},
		{"SearchPosts gains a cap", func(c *ratelimit.Config) {
			c.DailyCaps[searchv1connect.SearchServiceSearchPostsProcedure] = extra()
		}, "unexpected daily cap"},
		{"RestoreCommunityPost gains a cap", func(c *ratelimit.Config) {
			c.DailyCaps[communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure] = extra()
		}, "unexpected daily cap"},
		{"a removed cap returns on a new procedure", func(c *ratelimit.Config) {
			c.DailyCaps[identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure] = ratelimit.NamedDailyCap{Name: "check_handle_daily", Cap: ratelimit.NewDailyCap(100)}
		}, "unexpected daily cap \"check_handle_daily\""},
		{"ListFollowing is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[following]
			n.Name = "graph_list_daily"
			c.DailyCaps[following] = n
		}, "is named \"graph_list_daily\""},
		{"ListFollowing loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, following) }, "missing daily cap \"follow_list_daily\""},
		{"ListFollowing gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[following] = ratelimit.NamedDailyCap{Name: "follow_list_daily", Cap: ratelimit.NewDailyCap(1000)}
		}, "not one shared counter"},
		{"a kept cap is dropped", func(c *ratelimit.Config) {
			delete(c.DailyCaps, identityv1connect.IdentityServiceUpdateProfileProcedure)
		}, "missing daily cap \"profile_update_daily\""},
		{"a cap has a nil counter", func(c *ratelimit.Config) {
			n := c.DailyCaps[searchv1connect.SearchServiceSearchPeopleProcedure]
			n.Cap = nil
			c.DailyCaps[searchv1connect.SearchServiceSearchPeopleProcedure] = n
		}, "has a nil cap"},
		{"the default limiter is gone", func(c *ratelimit.Config) { c.Default = nil }, "no default per-minute limiter"},
		{"a required bucket is dropped", func(c *ratelimit.Config) {
			delete(c.PerProcedure, graphv1connect.GraphServiceListMutedUsersProcedure)
		}, "no per-minute bucket on " + graphv1connect.GraphServiceListMutedUsersProcedure},
		{"CheckHandleAvailability loses its bucket", func(c *ratelimit.Config) {
			delete(c.PerProcedure, identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure)
		}, "no per-minute bucket on " + identityv1connect.IdentityServiceCheckHandleAvailabilityProcedure},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(dailyCapInventoryViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
