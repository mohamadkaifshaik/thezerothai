package apiserver

import (
	"strings"
	"testing"

	beaconsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/beacons/v1/beaconsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// beaconWriteProcedures share RATE_LIMIT_BEACONS_WRITE_PER_MIN; CreateBeacon alone carries the beacons_created_daily cap.
var beaconWriteProcedures = []string{
	beaconsv1connect.BeaconServiceCreateBeaconProcedure,
	beaconsv1connect.BeaconServiceUpdateBeaconProcedure,
	beaconsv1connect.BeaconServiceCancelBeaconProcedure,
}

// beaconActionProcedures share RATE_LIMIT_BEACONS_ACTION_PER_MIN (wired now so PR 3 touches no rate-limit code).
var beaconActionProcedures = []string{
	beaconsv1connect.BeaconServiceRequestToJoinProcedure,
	beaconsv1connect.BeaconServiceWithdrawJoinRequestProcedure,
	beaconsv1connect.BeaconServiceRespondToJoinRequestProcedure,
	beaconsv1connect.BeaconServiceLeaveBeaconProcedure,
	beaconsv1connect.BeaconServiceRemoveParticipantProcedure,
}

// beaconReadProcedures share RATE_LIMIT_BEACONS_READ_PER_MIN.
var beaconReadProcedures = []string{
	beaconsv1connect.BeaconServiceGetBeaconProcedure,
	beaconsv1connect.BeaconServiceListBeaconsProcedure,
	beaconsv1connect.BeaconServiceListMyBeaconsProcedure,
	beaconsv1connect.BeaconServiceListParticipantsProcedure,
}

// beaconsRateLimitViolations asserts the wiring: each group shares one limiter, the three limiters are three different
// objects, CreateBeacon alone has a DailyCaps entry and it is named beacons_created_daily.
func beaconsRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	groups := []struct {
		name  string
		procs []string
	}{{"write", beaconWriteProcedures}, {"action", beaconActionProcedures}, {"read", beaconReadProcedures}}
	for _, g := range groups {
		for _, p := range g.procs {
			if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[g.procs[0]] {
				out = append(out, "beacon "+g.name+" "+p+" does not share the beacons "+g.name+" bucket")
			}
			if _, ok := rl.DailyCaps[p]; ok && p != beaconsv1connect.BeaconServiceCreateBeaconProcedure {
				out = append(out, "beacon "+g.name+" "+p+" must not be on a daily cap")
			}
		}
	}
	switch w, a, r := rl.PerProcedure[beaconWriteProcedures[0]], rl.PerProcedure[beaconActionProcedures[0]], rl.PerProcedure[beaconReadProcedures[0]]; {
	case w == nil || a == nil || r == nil:
		out = append(out, "a beacons bucket is missing")
	case w == a || w == r || a == r:
		out = append(out, "the beacons write, action and read buckets must be three different limiters")
	}
	create := beaconsv1connect.BeaconServiceCreateBeaconProcedure
	if named, ok := rl.DailyCaps[create]; !ok || named.Cap == nil || named.Name != "beacons_created_daily" {
		out = append(out, "CreateBeacon has no beacons_created_daily DailyCaps entry")
	}
	return out
}

// TestBeaconsRateLimit_Guard proves the guard passes on the shipped wiring and can fail.
func TestBeaconsRateLimit_Guard(t *testing.T) {
	create := beaconsv1connect.BeaconServiceCreateBeaconProcedure
	get := beaconsv1connect.BeaconServiceGetBeaconProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"create loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, create) }, "does not share the beacons write bucket"},
		{"get borrows the write bucket", func(c *ratelimit.Config) { c.PerProcedure[get] = c.PerProcedure[create] }, "does not share the beacons read bucket"},
		{"create loses its daily cap", func(c *ratelimit.Config) { delete(c.DailyCaps, create) }, "CreateBeacon has no beacons_created_daily"},
		{"create cap is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[create]
			n.Name = "graph_mutation_daily"
			c.DailyCaps[create] = n
		}, "CreateBeacon has no beacons_created_daily"},
		{"get joins a daily cap", func(c *ratelimit.Config) { c.DailyCaps[get] = c.DailyCaps[create] }, "must not be on a daily cap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(beaconsRateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}
