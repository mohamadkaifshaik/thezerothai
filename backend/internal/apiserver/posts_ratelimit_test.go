package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestPostsBuckets_AreWiredAtTheADR0010Rates (T4): through the config Build wires, the Nth call of a minute is
// allowed and the N+1th is RATE_LIMITED, per procedure, with the ADR-0010 Handoff numbers (home 6, user timeline
// 30, create 10, delete 20, GetPost 60 = the default bucket). Each bucket is independent: exhausting one
// procedure does not affect another.
func TestPostsBuckets_AreWiredAtTheADR0010Rates(t *testing.T) {
	tests := []struct {
		name string
		proc string
		n    int
	}{
		{"home timeline 6/min", timelinev1connect.TimelineServiceGetHomeTimelineProcedure, 6},
		{"user timeline 30/min", timelinev1connect.TimelineServiceGetUserTimelineProcedure, 30},
		{"create post 10/min", postsv1connect.PostServiceCreatePostProcedure, 10},
		{"delete post 20/min", postsv1connect.PostServiceDeletePostProcedure, 20},
		{"get post 60/min (default bucket)", postsv1connect.PostServiceGetPostProcedure, 60},
	}
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 60
	cfg.RateLimit.PerIPPerMinute = 100000
	// The read budget is not under test here; make it generous so only the per-minute buckets can reject.
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	rl := RateLimitConfig(cfg)

	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: "uid-posts", SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(setUID, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, tt := range tests {
		mux.Handle(tt.proc, connect.NewUnaryHandler(tt.proc,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				return connect.NewResponse(&commonv1.ErrorDetail{}), nil
			}, opts))
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	invoke := func(proc string) error {
		c := connect.NewClient[commonv1.ErrorDetail, commonv1.ErrorDetail](srv.Client(), srv.URL+proc)
		_, err := c.CallUnary(context.Background(), connect.NewRequest(&commonv1.ErrorDetail{}))
		return err
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for i := 1; i <= tt.n; i++ {
				if err := invoke(tt.proc); err != nil {
					t.Fatalf("call %d of %d must pass: %v", i, tt.n, err)
				}
			}
			err := invoke(tt.proc)
			var ce *connect.Error
			if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
				t.Fatalf("call %d: err = %v, want ResourceExhausted", tt.n+1, err)
			}
		})
	}
}
