package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	communitiesv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/communities/v1/communitiesv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// communityMutationProcedures share the community_mutation_daily cap (ADR-0031 D11); communityModProcedures share
// community_mod_actions_daily; all seven share the one write bucket.
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
	// communityReadProcedures share the read bucket and have no daily cap (the read budget covers them).
	communityReadProcedures = []string{
		communitiesv1connect.CommunityServiceGetCommunityProcedure,
		communitiesv1connect.CommunityServiceListCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListMyCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListCommunityMembersProcedure,
		communitiesv1connect.CommunityServiceListModerationLogProcedure,
	}
)

// communitiesRateLimitViolations asserts the wiring (ADR-0031 D11): the seven mutations share one limiter; the four member
// mutations share one named DailyCap and the three moderator actions another, and the two caps are different counters; the five
// reads share a second limiter with no daily cap; GetCommunityTimeline has its own limiter and no daily cap; the three limiters are
// three different objects; and every CommunityService procedure is covered.
func communitiesRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	writeBucket := rl.PerProcedure[communityMutationProcedures[0]]
	checkCap := func(procs []string, name string) *ratelimit.DailyCap {
		var first *ratelimit.DailyCap
		for _, p := range procs {
			named, ok := rl.DailyCaps[p]
			switch {
			case !ok || named.Cap == nil || named.Name != name:
				out = append(out, "community mutation "+p+" has no "+name+" DailyCaps entry")
			case first == nil:
				first = named.Cap
			case named.Cap != first:
				out = append(out, "community mutation "+p+" does not share the "+name+" DailyCap")
			}
			if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != writeBucket {
				out = append(out, "community mutation "+p+" does not share the communities write bucket")
			}
		}
		return first
	}
	a := checkCap(communityMutationProcedures, communities.LimitMutationDaily)
	b := checkCap(communityModProcedures, communities.LimitModActionsDaily)
	if a != nil && a == b {
		out = append(out, "the mutation and moderator caps must be different counters")
	}
	readBucket := rl.PerProcedure[communityReadProcedures[0]]
	for _, p := range communityReadProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "community read "+p+" must not be on a daily cap (the read budget covers it)")
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
		{"create loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, create) }, "community mutation " + create},
		{"create has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: communities.LimitMutationDaily}
		}, "community mutation " + create},
		{"create is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[create]
			n.Name = "list_mutation_daily"
			c.DailyCaps[create] = n
		}, "community mutation " + create},
		{"create gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: communities.LimitMutationDaily, Cap: ratelimit.NewDailyCap(200)}
		}, "does not share the community_mutation_daily"},
		{"hide gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[hide] = ratelimit.NamedDailyCap{Name: communities.LimitModActionsDaily, Cap: ratelimit.NewDailyCap(200)}
		}, "does not share the community_mod_actions_daily"},
		{"hide joins the mutation cap", func(c *ratelimit.Config) {
			c.DailyCaps[hide] = c.DailyCaps[create]
		}, "has no community_mod_actions_daily"},
		{"hide leaves the write bucket", func(c *ratelimit.Config) {
			c.PerProcedure[hide] = ratelimit.NewLimiter(20, idleBucketTTL)
		}, "does not share the communities write bucket"},
		{"a read joins the daily cap", func(c *ratelimit.Config) { c.DailyCaps[get] = c.DailyCaps[create] }, "community read " + get},
		{"a read leaves the read bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, get) }, "does not share the communities read bucket"},
		{"the timeline joins the daily cap", func(c *ratelimit.Config) { c.DailyCaps[tl] = c.DailyCaps[create] }, "GetCommunityTimeline must not"},
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

// TestCommunityDailyCaps_StopTheCapPlusFirstCall: through the wired interceptor the four member mutations draw on ONE per-uid
// daily budget and the three moderator actions on ANOTHER (the (cap+1)-th call of the day is ResourceExhausted whichever
// procedure it is), another user is untouched, the two budgets do not eat each other and a read is not counted.
func TestCommunityDailyCaps_StopTheCapPlusFirstCall(t *testing.T) {
	const memberCap, modCap = 8, 5
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.CommunitiesWritePerUserPerMinute = 100000
	cfg.RateLimit.CommunitiesReadPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.CommunityMutationsPerDay = memberCap
	cfg.RateLimit.CommunityModActionsPerDay = modCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	all := append(append(append([]string{}, communityMutationProcedures...), communityModProcedures...), communityReadProcedures...)
	for _, p := range all {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(uid, proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		req := connect.NewRequest(&commonv1.ErrorDetail{})
		req.Header().Set("X-Test-Uid", uid)
		_, err := c.CallUnary(context.Background(), req)
		return err
	}
	exhausted := func(err error) bool {
		var ce *connect.Error
		return errors.As(err, &ce) && ce.Code() == connect.CodeResourceExhausted
	}
	for i := 0; i < memberCap; i++ {
		if err := invoke("uid-c", communityMutationProcedures[i%len(communityMutationProcedures)]); err != nil {
			t.Fatalf("community mutation %d must pass: %v", i+1, err)
		}
	}
	for _, p := range communityMutationProcedures {
		if err := invoke("uid-c", p); !exhausted(err) {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, memberCap, err)
		}
	}
	// The member budget is spent; the moderator budget is untouched.
	for i := 0; i < modCap; i++ {
		if err := invoke("uid-c", communityModProcedures[i%len(communityModProcedures)]); err != nil {
			t.Fatalf("moderator action %d must pass with the member cap spent: %v", i+1, err)
		}
	}
	for _, p := range communityModProcedures {
		if err := invoke("uid-c", p); !exhausted(err) {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, modCap, err)
		}
	}
	if err := invoke("uid-c", communityReadProcedures[0]); err != nil {
		t.Fatalf("a community read must not draw on either cap: %v", err)
	}
	if err := invoke("uid-other", communityMutationProcedures[0]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}
