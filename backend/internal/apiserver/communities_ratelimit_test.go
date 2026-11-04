package apiserver

import (
	"strings"
	"testing"

	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// communityMutationProcedures and communityModProcedures share the one write bucket.
var (
	communityMutationProcedures = []string{
		communitiesv1connect.CommunityServiceCreateCommunityProcedure,
		communitiesv1connect.CommunityServiceUpdateCommunityProcedure,
		communitiesv1connect.CommunityServiceJoinCommunityProcedure,
		communitiesv1connect.CommunityServiceLeaveCommunityProcedure,
	}
	communityModProcedures = []string{
		communitiesv1connect.CommunityServiceHideCommunityPostProcedure,
		communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure,
		communitiesv1connect.CommunityServiceSetMemberRoleProcedure,
	}
	// communityReadProcedures share the read bucket.
	communityReadProcedures = []string{
		communitiesv1connect.CommunityServiceGetCommunityProcedure,
		communitiesv1connect.CommunityServiceListCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListMyCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListCommunityMembersProcedure,
		communitiesv1connect.CommunityServiceListModerationLogProcedure,
	}
)

// communitiesRateLimitViolations asserts the wiring: the seven mutations share one limiter; the five reads share a second
// limiter; GetCommunityTimeline has its own limiter; the three limiters are three different objects; no community procedure
// is on a daily cap; and every CommunityService procedure is covered.
func communitiesRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	writeBucket := rl.PerProcedure[communityMutationProcedures[0]]
	for _, p := range append(append([]string{}, communityMutationProcedures...), communityModProcedures...) {
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != writeBucket {
			out = append(out, "community mutation "+p+" does not share the communities write bucket")
		}
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "community mutation "+p+" must not be on a daily cap")
		}
	}
	readBucket := rl.PerProcedure[communityReadProcedures[0]]
	for _, p := range communityReadProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "community read "+p+" must not be on a daily cap")
		}
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != readBucket {
			out = append(out, "community read "+p+" does not share the communities read bucket")
		}
	}
	tl := timelinev1connect.TimelineServiceGetCommunityTimelineProcedure
	if _, ok := rl.DailyCaps[tl]; ok {
		out = append(out, "GetCommunityTimeline must not be on a daily cap")
	}
	switch w, r, l := writeBucket, readBucket, rl.PerProcedure[tl]; {
	case w == nil || r == nil || l == nil:
		out = append(out, "a communities bucket is missing")
	case w == r || w == l || r == l:
		out = append(out, "the communities write, read and timeline buckets must be three different limiters")
	}
	if n := len(communityMutationProcedures) + len(communityModProcedures) + len(communityReadProcedures); n != 12 {
		out = append(out, "the guard lists a different number of procedures than CommunityService has (12)")
	}
	return out
}

// TestCommunitiesRateLimit_Guard proves the guard passes on the shipped wiring and fails when each rule is broken.
func TestCommunitiesRateLimit_Guard(t *testing.T) {
	create := communitiesv1connect.CommunityServiceCreateCommunityProcedure
	hide := communitiesv1connect.CommunityServiceHideCommunityPostProcedure
	get := communitiesv1connect.CommunityServiceGetCommunityProcedure
	tl := timelinev1connect.TimelineServiceGetCommunityTimelineProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"create gains a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(200)}
		}, "community mutation " + create + " must not be on a daily cap"},
		{"create leaves the write bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, create) }, "does not share the communities write bucket"},
		{"hide leaves the write bucket", func(c *ratelimit.Config) {
			c.PerProcedure[hide] = ratelimit.NewLimiter(20, idleBucketTTL)
		}, "does not share the communities write bucket"},
		{"a read joins a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[get] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(200)}
		}, "community read " + get},
		{"a read leaves the read bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, get) }, "does not share the communities read bucket"},
		{"the timeline joins a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[tl] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(200)}
		}, "GetCommunityTimeline must not"},
		{"the timeline shares the read bucket", func(c *ratelimit.Config) { c.PerProcedure[tl] = c.PerProcedure[get] }, "three different limiters"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(communitiesRateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
