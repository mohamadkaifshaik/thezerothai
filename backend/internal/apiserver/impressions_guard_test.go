package apiserver

import (
	"strings"
	"testing"

	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// impressionViolations asserts the RecordImpressions wiring (F1 post views): its own per-minute bucket (not the shares or
// likes one) and the impressions_daily cap of its own.
func impressionViolations(rl ratelimit.Config) []string {
	var out []string
	imp := engagementv1connect.EngagementServiceRecordImpressionsProcedure
	switch rl.PerProcedure[imp] {
	case nil:
		out = append(out, "RecordImpressions needs its own per-minute bucket")
	case rl.PerProcedure[engagementv1connect.EngagementServiceLikePostProcedure], rl.PerProcedure[engagementv1connect.EngagementServiceRecordPostShareProcedure]:
		out = append(out, "RecordImpressions must not share another engagement bucket")
	}
	named, ok := rl.DailyCaps[imp]
	if !ok || named.Cap == nil || named.Name != "impressions_daily" {
		return append(out, "RecordImpressions needs the impressions_daily cap")
	}
	for p, other := range rl.DailyCaps {
		if p != imp && other.Cap == named.Cap {
			out = append(out, "the impressions_daily cap must not be shared with "+p)
		}
	}
	return out
}

// TestImpressionWiring_Guard proves the guard passes on the shipped wiring and can fail.
func TestImpressionWiring_Guard(t *testing.T) {
	imp := engagementv1connect.EngagementServiceRecordImpressionsProcedure
	share := engagementv1connect.EngagementServiceRecordPostShareProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, imp) }, "own per-minute bucket"},
		{"shares the shares bucket", func(c *ratelimit.Config) { c.PerProcedure[imp] = c.PerProcedure[share] }, "must not share"},
		{"loses its daily cap", func(c *ratelimit.Config) { delete(c.DailyCaps, imp) }, "impressions_daily cap"},
		{"cap shared", func(c *ratelimit.Config) { c.DailyCaps[share] = c.DailyCaps[imp] }, "must not be shared"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(impressionViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
