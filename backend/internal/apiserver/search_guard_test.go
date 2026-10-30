package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// searchDailyProcedures are the two search RPCs that share the one search_daily cap (ADR-0028 D9). GetTrends is a cached
// single-document read on the 60/min default bucket with its own trends_daily cap (ADR-0028 note 2026-10-31 part 4).
var searchDailyProcedures = []string{
	searchv1connect.SearchServiceSearchPeopleProcedure,
	searchv1connect.SearchServiceSearchPostsProcedure,
}

// searchViolations asserts the W4-3 wiring: SearchPeople and SearchPosts each have a DailyCaps entry named search_daily
// holding the SAME DailyCap, GetTrends has its OWN non-nil trends_daily entry (W4-28, review L-4) whose Cap is not that one, and all three procedures are covered by the daily read budget
// (ADR-0010 D5; they are NO_SIDE_EFFECTS, so the generic guard also sees them).
func searchViolations(rl ratelimit.Config) []string {
	var out []string
	var first *ratelimit.DailyCap
	for _, p := range searchDailyProcedures {
		named, ok := rl.DailyCaps[p]
		switch {
		case !ok || named.Cap == nil || named.Name != "search_daily":
			out = append(out, "search procedure "+p+" has no search_daily DailyCaps entry")
		case first == nil:
			first = named.Cap
		case first != named.Cap:
			out = append(out, "search procedure "+p+" does not share the search_daily DailyCap")
		}
	}
	trends, ok := rl.DailyCaps[searchv1connect.SearchServiceGetTrendsProcedure]
	switch {
	case !ok || trends.Cap == nil || trends.Name != "trends_daily":
		out = append(out, "GetTrends has no trends_daily DailyCaps entry")
	case first != nil && trends.Cap == first:
		out = append(out, "GetTrends must not be on the search_daily cap")
	}
	for _, p := range append(append([]string{}, searchDailyProcedures...), searchv1connect.SearchServiceGetTrendsProcedure) {
		if !rl.ReadBudgetCovers(p) {
			out = append(out, "search procedure "+p+" is not covered by the daily read budget")
		}
	}
	if rl.PerProcedure[searchv1connect.SearchServiceSearchPeopleProcedure] == nil || rl.PerProcedure[searchv1connect.SearchServiceSearchPostsProcedure] == nil {
		out = append(out, "SearchPeople and SearchPosts need their own per-minute buckets")
	}
	return out
}

// TestSearchWiring_Guard proves the guard passes on the shipped wiring and can fail.
func TestSearchWiring_Guard(t *testing.T) {
	posts := searchv1connect.SearchServiceSearchPostsProcedure
	trends := searchv1connect.SearchServiceGetTrendsProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"posts loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, posts) }, "search procedure " + posts},
		{"posts has its own cap", func(c *ratelimit.Config) {
			c.DailyCaps[posts] = ratelimit.NamedDailyCap{Name: "search_daily", Cap: ratelimit.NewDailyCap(300)}
		}, "does not share"},
		{"posts cap is misnamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[posts]
			n.Name = "other"
			c.DailyCaps[posts] = n
		}, "search procedure " + posts},
		{"trends loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, trends) }, "GetTrends has no trends_daily"},
		{"trends cap is misnamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[trends]
			n.Name = "other"
			c.DailyCaps[trends] = n
		}, "GetTrends has no trends_daily"},
		{"trends joins search_daily", func(c *ratelimit.Config) {
			c.DailyCaps[trends] = ratelimit.NamedDailyCap{Name: "trends_daily", Cap: c.DailyCaps[posts].Cap}
		}, "GetTrends must not"},
		{"trends is named search_daily", func(c *ratelimit.Config) {
			c.DailyCaps[trends] = ratelimit.NamedDailyCap{Name: "search_daily", Cap: ratelimit.NewDailyCap(400)}
		}, "GetTrends has no trends_daily"},
		{"posts loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, posts) }, "own per-minute buckets"},
		{"read budget off", func(c *ratelimit.Config) { c.ReadBudget = nil }, "not covered by the daily read budget"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(searchViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestSearchDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor, SearchPeople and SearchPosts draw on ONE
// per-uid daily budget, so the (cap+1)-th call is ResourceExhausted whichever RPC it is; GetTrends and another user are
// untouched.
func TestSearchDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 6
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.SearchPeoplePerUserPerMinute = 100000
	cfg.RateLimit.SearchPostsPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.SearchCallsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	all := append(append([]string{}, searchDailyProcedures...), searchv1connect.SearchServiceGetTrendsProcedure)
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
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-s", searchDailyProcedures[i%2]); err != nil {
			t.Fatalf("search call %d must pass: %v", i+1, err)
		}
	}
	for _, p := range searchDailyProcedures {
		err := invoke("uid-s", p)
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, dailyCap, err)
		}
	}
	if err := invoke("uid-s", searchv1connect.SearchServiceGetTrendsProcedure); err != nil {
		t.Fatalf("GetTrends is not on the search cap: %v", err)
	}
	if err := invoke("uid-other", searchDailyProcedures[1]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}

// TestSearchPosts_PerMinuteBucket (W4-7 acceptance): through the wired interceptor the 21st SearchPosts call of one user in
// a minute is RESOURCE_EXHAUSTED (RATE_LIMITED, 20/min per instance); SearchPeople's own bucket and another user are
// untouched.
func TestSearchPosts_PerMinuteBucket(t *testing.T) {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.SearchPeoplePerUserPerMinute = 100000
	cfg.RateLimit.SearchPostsPerUserPerMinute = 20
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.SearchCallsPerDay = 100000
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range searchDailyProcedures {
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
	postsProc := searchv1connect.SearchServiceSearchPostsProcedure
	for i := 0; i < 20; i++ {
		if err := invoke("uid-m", postsProc); err != nil {
			t.Fatalf("call %d must pass: %v", i+1, err)
		}
	}
	err := invoke("uid-m", postsProc)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("call 21: err = %v, want ResourceExhausted", err)
	}
	if err := invoke("uid-m", searchv1connect.SearchServiceSearchPeopleProcedure); err != nil {
		t.Fatalf("SearchPeople has its own bucket: %v", err)
	}
	if err := invoke("uid-other", postsProc); err != nil {
		t.Fatalf("another user must not share the bucket: %v", err)
	}
}

// TestTrendsDailyCap_StopsTheCapPlusFirstCall (W4-28 acceptance): through the wired interceptor the (cap+1)-th GetTrends
// call of one uid is RATE_LIMITED with limit=trends_daily and never reaches the handler (0 reads); another uid is
// unaffected, and SearchPeople/SearchPosts keep their own search_daily count (GetTrends calls do not spend it).
func TestTrendsDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 5
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.SearchPeoplePerUserPerMinute = 100000
	cfg.RateLimit.SearchPostsPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.SearchCallsPerDay = 2
	cfg.RateLimit.TrendsCallsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	var handled atomic.Int64
	mux := http.NewServeMux()
	trendsProc := searchv1connect.SearchServiceGetTrendsProcedure
	for _, p := range append(append([]string{}, searchDailyProcedures...), trendsProc) {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				handled.Add(1)
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
	for i := 1; i <= dailyCap; i++ {
		if err := invoke("uid-t", trendsProc); err != nil {
			t.Fatalf("trends call %d must pass: %v", i, err)
		}
	}
	before := handled.Load()
	err := invoke("uid-t", trendsProc)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("call %d: err = %v, want ResourceExhausted", dailyCap+1, err)
	}
	if handled.Load() != before {
		t.Errorf("the rejected call reached the handler (reads would be charged)")
	}
	limit := ""
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				if ed.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
					t.Errorf("reason = %v, want RATE_LIMITED", ed.GetReason())
				}
				limit = ed.GetMetadata()["limit"]
			}
		}
	}
	if limit != "trends_daily" {
		t.Errorf("limit = %q, want trends_daily", limit)
	}
	if err := invoke("uid-other", trendsProc); err != nil {
		t.Errorf("another uid must be unaffected: %v", err)
	}
	// uid-t spent 5 trends calls: the search cap (2) is untouched, so both search RPCs still pass twice.
	for i, p := range searchDailyProcedures {
		if err := invoke("uid-t", p); err != nil {
			t.Errorf("search call %d must keep its own search_daily count: %v", i+1, err)
		}
	}
}
