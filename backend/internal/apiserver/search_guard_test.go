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
	searchv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/search/v1/searchv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// searchProcedures are the two search RPCs that have their own per-minute buckets. GetTrends is a cached single-document read
// on the 60/min default bucket.
var searchProcedures = []string{
	searchv1connect.SearchServiceSearchPeopleProcedure,
	searchv1connect.SearchServiceSearchPostsProcedure,
}

// searchViolations asserts the wiring: SearchPeople and SearchPosts each have their own per-minute bucket, and no search
// procedure (GetTrends included) is on a daily cap.
func searchViolations(rl ratelimit.Config) []string {
	var out []string
	for _, p := range append(append([]string{}, searchProcedures...), searchv1connect.SearchServiceGetTrendsProcedure) {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "search procedure "+p+" must not be on a daily cap")
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
		{"posts gains a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[posts] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(300)}
		}, "search procedure " + posts},
		{"trends gains a daily cap", func(c *ratelimit.Config) {
			c.DailyCaps[trends] = ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(400)}
		}, "search procedure " + trends},
		{"posts loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, posts) }, "own per-minute buckets"},
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

// TestSearchPosts_PerMinuteBucket (acceptance): through the wired interceptor the 21st SearchPosts call of one user in
// a minute is RESOURCE_EXHAUSTED (RATE_LIMITED, 20/min per instance); SearchPeople's own bucket and another user are
// untouched.
func TestSearchPosts_PerMinuteBucket(t *testing.T) {
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.SearchPeoplePerUserPerMinute = 100000
	cfg.RateLimit.SearchPostsPerUserPerMinute = 20
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range searchProcedures {
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
