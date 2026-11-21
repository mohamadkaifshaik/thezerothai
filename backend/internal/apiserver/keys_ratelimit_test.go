package apiserver

import (
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// The key directory buckets: RegisterKeyDevice, RemoveKeyDevice and UploadKeyPackages share RATE_LIMIT_KEYS_WRITE_PER_MIN,
// ListMyKeyDevices and GetKeyDevices share RATE_LIMIT_KEYS_READ_PER_MIN, ClaimKeyPackages has RATE_LIMIT_KEYS_CLAIM_PER_MIN
// alone, and only ClaimKeyPackages is on an interceptor daily cap (keys_claims_daily, KEYS_CLAIMS_PER_DAY). Its
// per-(caller, target) cap (keys_claims_per_target_daily) is the service's; see keys_wiring_test.go.
var (
	keysWriteProcedures = []string{
		keysv1connect.KeyServiceRegisterKeyDeviceProcedure,
		keysv1connect.KeyServiceRemoveKeyDeviceProcedure,
		keysv1connect.KeyServiceUploadKeyPackagesProcedure,
	}
	keysReadProcedures = []string{
		keysv1connect.KeyServiceListMyKeyDevicesProcedure,
		keysv1connect.KeyServiceGetKeyDevicesProcedure,
	}
	keysClaimProcedures = []string{keysv1connect.KeyServiceClaimKeyPackagesProcedure}
)

// keysRateLimitCfg is defaultRateLimitCfg with the key directory's config.Load defaults.
func keysRateLimitCfg() config.Config {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.KeysWritePerUserPerMinute = 20
	cfg.RateLimit.KeysReadPerUserPerMinute = 60
	cfg.RateLimit.KeysClaimPerUserPerMinute = 20
	cfg.RateLimit.KeysClaimsPerDay = 300
	return cfg
}

// keysRateLimitViolations asserts the wiring: all six procedures mapped, each group on one shared limiter, the three
// limiters distinct, the daily cap named keys_claims_daily on ClaimKeyPackages only.
func keysRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	groups := []struct {
		name  string
		procs []string
	}{{"write", keysWriteProcedures}, {"read", keysReadProcedures}, {"claim", keysClaimProcedures}}
	seen := map[*ratelimit.Limiter]string{}
	for _, g := range groups {
		for _, p := range g.procs {
			if rl.PerProcedure[p] == nil {
				out = append(out, "keys "+p+" is not mapped")
			} else if rl.PerProcedure[p] != rl.PerProcedure[g.procs[0]] {
				out = append(out, "keys "+g.name+" "+p+" does not share the keys "+g.name+" bucket")
			}
			named, capped := rl.DailyCaps[p]
			switch {
			case g.name == "claim" && (!capped || named.Cap == nil || named.Name != "keys_claims_daily"):
				out = append(out, "keys "+p+" has no keys_claims_daily cap")
			case g.name != "claim" && capped:
				out = append(out, "keys "+p+" must not be on a daily cap")
			}
		}
		if b := rl.PerProcedure[g.procs[0]]; b != nil {
			if other, dup := seen[b]; dup {
				out = append(out, "the keys "+g.name+" and "+other+" buckets must be different limiters")
			}
			seen[b] = g.name
		}
	}
	for p, named := range rl.DailyCaps {
		if named.Name == "keys_claims_daily" && p != keysv1connect.KeyServiceClaimKeyPackagesProcedure {
			out = append(out, "keys_claims_daily is drawn on by "+p)
		}
	}
	return out
}

// TestKeysRateLimit_Guard proves the guard passes on the shipped wiring and can fail.
func TestKeysRateLimit_Guard(t *testing.T) {
	reg := keysv1connect.KeyServiceRegisterKeyDeviceProcedure
	upload := keysv1connect.KeyServiceUploadKeyPackagesProcedure
	list := keysv1connect.KeyServiceListMyKeyDevicesProcedure
	get := keysv1connect.KeyServiceGetKeyDevicesProcedure
	claim := keysv1connect.KeyServiceClaimKeyPackagesProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"upload loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, upload) }, "is not mapped"},
		{"get gets its own bucket", func(c *ratelimit.Config) { c.PerProcedure[get] = ratelimit.NewLimiter(60, idleBucketTTL) }, "does not share the keys read bucket"},
		{"claim shares the write bucket", func(c *ratelimit.Config) { c.PerProcedure[claim] = c.PerProcedure[reg] }, "must be different limiters"},
		{"read shares the claim bucket", func(c *ratelimit.Config) {
			c.PerProcedure[list], c.PerProcedure[get] = c.PerProcedure[claim], c.PerProcedure[claim]
		}, "must be different limiters"},
		{"claim loses its daily cap", func(c *ratelimit.Config) { delete(c.DailyCaps, claim) }, "has no keys_claims_daily cap"},
		{"claim cap renamed", func(c *ratelimit.Config) {
			c.DailyCaps[claim] = ratelimit.NamedDailyCap{Name: "other", Cap: c.DailyCaps[claim].Cap}
		}, "has no keys_claims_daily cap"},
		{"get joins the claim cap", func(c *ratelimit.Config) { c.DailyCaps[get] = c.DailyCaps[claim] }, "must not be on a daily cap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(keysRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(keysRateLimitViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestKeysRateLimit_Buckets: through the limiters themselves, the write bucket is one budget across Register, Remove
// and Upload (20/min), the read bucket one across ListMy and Get (60/min), the claim bucket its own 20/min; another
// user is untouched.
func TestKeysRateLimit_Buckets(t *testing.T) {
	rl := RateLimitConfig(keysRateLimitCfg())
	for _, g := range []struct {
		procs []string
		n     int
	}{{keysWriteProcedures, 20}, {keysReadProcedures, 60}, {keysClaimProcedures, 20}} {
		for i := 0; i < g.n; i++ {
			if ok, _ := rl.PerProcedure[g.procs[i%len(g.procs)]].Allow("uid-keys"); !ok {
				t.Fatalf("%v call %d refused, want the first %d allowed", g.procs, i+1, g.n)
			}
		}
		for _, p := range g.procs {
			if ok, retry := rl.PerProcedure[p].Allow("uid-keys"); ok || retry <= 0 {
				t.Errorf("%s after %d calls in the group = %v retry %v, want refused", p, g.n, ok, retry)
			}
		}
		if ok, _ := rl.PerProcedure[g.procs[0]].Allow("uid-keys-other"); !ok {
			t.Errorf("%v: another user was refused", g.procs)
		}
	}
}

// TestKeysClaimsDailyCap: through the real interceptor the (cap+1)-th ClaimKeyPackages of a uid is RATE_LIMITED with
// metadata limit=keys_claims_daily, another uid is untouched, and GetKeyDevices has a separate service-level cap.
func TestKeysClaimsDailyCap(t *testing.T) {
	const dailyCap = 3
	claim := keysv1connect.KeyServiceClaimKeyPackagesProcedure
	get := keysv1connect.KeyServiceGetKeyDevicesProcedure
	cfg := keysRateLimitCfg()
	cfg.RateLimit.KeysClaimsPerDay = dailyCap
	cfg.RateLimit.KeysClaimPerUserPerMinute = 1_000_000
	cfg.RateLimit.KeysReadPerUserPerMinute = 1_000_000
	invoke := messagingCapInvoker(t, cfg, claim, get)
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-claimer", claim); err != nil {
			t.Fatalf("claim %d must pass: %v", i+1, err)
		}
	}
	wantCapRefusal(t, invoke("uid-claimer", claim), "keys_claims_daily")
	for i := 0; i < dailyCap+2; i++ {
		if err := invoke("uid-claimer", get); err != nil {
			t.Fatalf("GetKeyDevices %d must pass the claims interceptor cap: %v", i+1, err)
		}
	}
	if err := invoke("uid-other", claim); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}
