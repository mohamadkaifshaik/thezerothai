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
	listsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/lists/v1/listsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// listMutationProcedures are the six ADR-0030 mutations: each stores an idempotency document even when it changes nothing, so
// they share one per-minute bucket and ONE per-uid daily call cap (limit_name "list_mutation_daily").
var listMutationProcedures = []string{
	listsv1connect.ListServiceCreateListProcedure,
	listsv1connect.ListServiceUpdateListProcedure,
	listsv1connect.ListServiceDeleteListProcedure,
	listsv1connect.ListServiceAddListMemberProcedure,
	listsv1connect.ListServiceRemoveListMemberProcedure,
	timelinev1connect.TimelineServiceSetHomeTabsProcedure,
}

// listReadProcedures share the RATE_LIMIT_LISTS_READ_PER_MIN bucket and have no daily cap (the read budget covers them).
var listReadProcedures = []string{
	listsv1connect.ListServiceGetListProcedure,
	listsv1connect.ListServiceListUserListsProcedure,
	listsv1connect.ListServiceListListMembersProcedure,
}

// listsRateLimitViolations asserts the W5-3 wiring (ADR-0030 D10): the six mutations share one limiter and one named DailyCap;
// the three reads share another limiter and have no daily cap; GetListTimeline has its own limiter and no daily cap; the three
// limiters are three different objects.
func listsRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	var firstCap *ratelimit.DailyCap
	for _, p := range listMutationProcedures {
		named, ok := rl.DailyCaps[p]
		switch {
		case !ok || named.Cap == nil || named.Name != "list_mutation_daily":
			out = append(out, "list mutation "+p+" has no list_mutation_daily DailyCaps entry")
		case firstCap == nil:
			firstCap = named.Cap
		case named.Cap != firstCap:
			out = append(out, "list mutation "+p+" does not share the list_mutation_daily DailyCap")
		}
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[listMutationProcedures[0]] {
			out = append(out, "list mutation "+p+" does not share the lists write bucket")
		}
	}
	for _, p := range listReadProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "list read "+p+" must not be on a daily cap (the read budget covers it)")
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
		{"create loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, create) }, "list mutation " + create},
		{"create has a nil cap", func(c *ratelimit.Config) { c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: "list_mutation_daily"} }, "list mutation " + create},
		{"create is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[create]
			n.Name = "graph_mutation_daily"
			c.DailyCaps[create] = n
		}, "list mutation " + create},
		{"create gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[create] = ratelimit.NamedDailyCap{Name: "list_mutation_daily", Cap: ratelimit.NewDailyCap(500)}
		}, "does not share the list_mutation_daily"},
		{"set home tabs leaves the write bucket", func(c *ratelimit.Config) {
			c.PerProcedure[timelinev1connect.TimelineServiceSetHomeTabsProcedure] = ratelimit.NewLimiter(30, idleBucketTTL)
		}, "does not share the lists write bucket"},
		{"a read joins the daily cap", func(c *ratelimit.Config) { c.DailyCaps[get] = c.DailyCaps[create] }, "list read " + get},
		{"a read leaves the read bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, get) }, "does not share the lists read bucket"},
		{"the timeline joins the daily cap", func(c *ratelimit.Config) { c.DailyCaps[tl] = c.DailyCaps[create] }, "GetListTimeline must not"},
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

// TestListMutationDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor the six mutations draw on ONE per-uid daily
// budget (the (cap+1)-th call of the day is ResourceExhausted whichever procedure it is), another user is untouched, and a
// read is not counted.
func TestListMutationDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 12
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.ListsWritePerUserPerMinute = 100000
	cfg.RateLimit.ListsReadPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.ListMutationsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range append(append([]string{}, listMutationProcedures...), listReadProcedures...) {
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
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-l", listMutationProcedures[i%len(listMutationProcedures)]); err != nil {
			t.Fatalf("list mutation %d must pass: %v", i+1, err)
		}
	}
	for _, p := range listMutationProcedures {
		err := invoke("uid-l", p)
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, dailyCap, err)
		}
	}
	if err := invoke("uid-l", listReadProcedures[0]); err != nil {
		t.Fatalf("a list read must not draw on the mutation cap: %v", err)
	}
	if err := invoke("uid-other", listMutationProcedures[0]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}
