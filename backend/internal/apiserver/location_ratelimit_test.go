package apiserver

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/location/v1/locationv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// The location buckets: GetLocationSettings and ListAreas share RATE_LIMIT_LOCATION_READ_PER_MIN, SetArea has
// RATE_LIMIT_LOCATION_WRITE_PER_MIN, and ClearArea its own RATE_LIMIT_LOCATION_CLEAR_PER_MIN (a withdrawal is never
// delayed by SetArea bursts).
var (
	locationReadProcedures = []string{
		locationv1connect.LocationServiceGetLocationSettingsProcedure,
		locationv1connect.LocationServiceListAreasProcedure,
	}
	locationWriteProcedures = []string{locationv1connect.LocationServiceSetAreaProcedure}
	locationClearProcedures = []string{locationv1connect.LocationServiceClearAreaProcedure}
)

// locationRateLimitViolations asserts the wiring: each group shares one limiter, the three are different objects, and no
// location RPC is on a daily cap (the consent cap is persisted, in the SetArea transaction).
func locationRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	groups := []struct {
		name  string
		procs []string
	}{{"read", locationReadProcedures}, {"write", locationWriteProcedures}, {"clear", locationClearProcedures}}
	seen := map[*ratelimit.Limiter]string{}
	for _, g := range groups {
		for _, p := range g.procs {
			if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[g.procs[0]] {
				out = append(out, "location "+g.name+" "+p+" does not share the location "+g.name+" bucket")
			}
			if _, ok := rl.DailyCaps[p]; ok {
				out = append(out, "location "+p+" must not be on a daily cap")
			}
		}
		if b := rl.PerProcedure[g.procs[0]]; b != nil {
			if other, dup := seen[b]; dup {
				out = append(out, "the location "+g.name+" and "+other+" buckets must be different limiters")
			}
			seen[b] = g.name
		}
	}
	return out
}

// TestLocationRateLimit_Guard proves the guard passes on the shipped wiring and can fail.
func TestLocationRateLimit_Guard(t *testing.T) {
	set := locationv1connect.LocationServiceSetAreaProcedure
	clr := locationv1connect.LocationServiceClearAreaProcedure
	get := locationv1connect.LocationServiceGetLocationSettingsProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"set loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, set) }, "does not share the location write bucket"},
		{"get borrows the write bucket", func(c *ratelimit.Config) { c.PerProcedure[get] = c.PerProcedure[set] }, "does not share the location read bucket"},
		{"clear shares the write bucket", func(c *ratelimit.Config) { c.PerProcedure[clr] = c.PerProcedure[set] }, "must be different limiters"},
		{"set joins a daily cap", func(c *ratelimit.Config) {
			for _, v := range c.DailyCaps {
				c.DailyCaps[set] = v
				break
			}
		}, "must not be on a daily cap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(locationRateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
