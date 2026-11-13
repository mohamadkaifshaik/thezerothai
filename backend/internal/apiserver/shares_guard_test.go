package apiserver

import (
	"strings"
	"testing"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// shareViolations asserts the RecordPostShare wiring (shares design §4.7): its own per-minute bucket (not the likes one)
// and the shares_daily cap of its own (not shared with another procedure).
func shareViolations(rl ratelimit.Config) []string {
	var out []string
	share := engagementv1connect.EngagementServiceRecordPostShareProcedure
	switch rl.PerProcedure[share] {
	case nil:
		out = append(out, "RecordPostShare needs its own per-minute bucket")
	case rl.PerProcedure[engagementv1connect.EngagementServiceLikePostProcedure]:
		out = append(out, "RecordPostShare must not share the likes bucket")
	}
	named, ok := rl.DailyCaps[share]
	if !ok || named.Cap == nil || named.Name != "shares_daily" {
		out = append(out, "RecordPostShare needs the shares_daily cap")
		return out
	}
	for p, other := range rl.DailyCaps {
		if p != share && other.Cap == named.Cap {
			out = append(out, "the shares_daily cap must not be shared with "+p)
		}
	}
	return out
}

// TestShareWiring_Guard proves the guard passes on the shipped wiring and can fail.
func TestShareWiring_Guard(t *testing.T) {
	share := engagementv1connect.EngagementServiceRecordPostShareProcedure
	like := engagementv1connect.EngagementServiceLikePostProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, share) }, "own per-minute bucket"},
		{"shares the likes bucket", func(c *ratelimit.Config) { c.PerProcedure[share] = c.PerProcedure[like] }, "must not share the likes bucket"},
		{"loses its daily cap", func(c *ratelimit.Config) { delete(c.DailyCaps, share) }, "shares_daily cap"},
		{"cap renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[share]
			n.Name = "messages_daily"
			c.DailyCaps[share] = n
		}, "shares_daily cap"},
		{"cap shared", func(c *ratelimit.Config) { c.DailyCaps[like] = c.DailyCaps[share] }, "must not be shared"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(shareViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
