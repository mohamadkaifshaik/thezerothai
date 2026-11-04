package apiserver

import (
	"strings"
	"testing"

	listsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// listMutationProcedures are the six list mutations: each stores an idempotency document even when it changes nothing, so
// they share one per-minute bucket.
var listMutationProcedures = []string{
	listsv1connect.ListServiceCreateListProcedure,
	listsv1connect.ListServiceUpdateListProcedure,
	listsv1connect.ListServiceDeleteListProcedure,
	listsv1connect.ListServiceAddListMemberProcedure,
	listsv1connect.ListServiceRemoveListMemberProcedure,
	timelinev1connect.TimelineServiceSetHomeTabsProcedure,
}

// listReadProcedures share the RATE_LIMIT_LISTS_READ_PER_MIN bucket.
var listReadProcedures = []string{
	listsv1connect.ListServiceGetListProcedure,
	listsv1connect.ListServiceListUserListsProcedure,
	listsv1connect.ListServiceListListMembersProcedure,
}

// listsRateLimitViolations asserts the wiring: the six mutations share one limiter; the three reads share another limiter;
// GetListTimeline has its own limiter; the three limiters are three different objects; and no list procedure is on a daily cap.
func listsRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	for _, p := range listMutationProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "list mutation "+p+" must not be on a daily cap")
		}
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[listMutationProcedures[0]] {
			out = append(out, "list mutation "+p+" does not share the lists write bucket")
		}
	}
	for _, p := range listReadProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "list read "+p+" must not be on a daily cap")
		}
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[listReadProcedures[0]] {
			out = append(out, "list read "+p+" does not share the lists read bucket")
		}
	}
	tl := timelinev1connect.TimelineServiceGetListTimelineProcedure
	if _, ok := rl.DailyCaps[tl]; ok {
		out = append(out, "GetListTimeline must not be on a daily cap")
	}
	switch w, r, l := rl.PerProcedure[listMutationProcedures[0]], rl.PerProcedure[listReadProcedures[0]], rl.PerProcedure[tl]; {
	case w == nil || r == nil || l == nil:
		out = append(out, "a lists bucket is missing")
	case w == r || w == l || r == l:
		out = append(out, "the lists write, read and timeline buckets must be three different limiters")
	}
	return out
}

// TestListsRateLimit_Guard proves the guard passes on the shipped wiring and fails when each rule is broken.
func TestListsRateLimit_Guard(t *testing.T) {
	create := listsv1connect.ListServiceCreateListProcedure
	get := listsv1connect.ListServiceGetListProcedure
	tl := timelinev1connect.TimelineServiceGetListTimelineProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"create gains a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(500)}
		}, "list mutation " + create + " must not be on a daily cap"},
		{"set home tabs leaves the write bucket", func(c *ratelimit.Config) {
			c.PerProcedure[timelinev1connect.TimelineServiceSetHomeTabsProcedure] = ratelimit.NewLimiter(30, idleBucketTTL)
		}, "does not share the lists write bucket"},
		{"a read joins a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[get] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(500)}
		}, "list read " + get},
		{"a read leaves the read bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, get) }, "does not share the lists read bucket"},
		{"the timeline joins a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[tl] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(500)}
		}, "GetListTimeline must not"},
		{"the timeline shares the read bucket", func(c *ratelimit.Config) { c.PerProcedure[tl] = c.PerProcedure[get] }, "three different limiters"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(listsRateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
