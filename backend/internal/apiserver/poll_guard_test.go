package apiserver

import (
	"strings"
	"testing"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// pollVoteViolations asserts the wiring: VotePoll has its own per-minute bucket, not the one LikePost draws on, and no daily cap.
func pollVoteViolations(rl ratelimit.Config) []string {
	var out []string
	vote := engagementv1connect.EngagementServiceVotePollProcedure
	switch rl.PerProcedure[vote] {
	case nil:
		out = append(out, "VotePoll needs its own per-minute bucket")
	case rl.PerProcedure[engagementv1connect.EngagementServiceLikePostProcedure]:
		out = append(out, "VotePoll must not share the likes bucket")
	}
	if _, ok := rl.DailyCaps[vote]; ok {
		out = append(out, "VotePoll must not be on a daily cap")
	}
	return out
}

// TestPollVoteWiring_Guard proves the guard passes on the shipped wiring and can fail.
func TestPollVoteWiring_Guard(t *testing.T) {
	vote := engagementv1connect.EngagementServiceVotePollProcedure
	like := engagementv1connect.EngagementServiceLikePostProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, vote) }, "own per-minute bucket"},
		{"shares the likes bucket", func(c *ratelimit.Config) { c.PerProcedure[vote] = c.PerProcedure[like] }, "must not share the likes bucket"},
		{"gains a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[vote] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(300)}
		}, "must not be on a daily cap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(pollVoteViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
