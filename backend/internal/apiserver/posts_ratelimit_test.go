package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	moderationv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/moderation/v1/moderationv1connect"
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
		{"report content 5/min (ADR-0016)", moderationv1connect.ModerationServiceReportContentProcedure, 5},
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
			var detail *commonv1.ErrorDetail
			for _, d := range ce.Details() {
				if v, verr := d.Value(); verr == nil {
					if ed, ok := v.(*commonv1.ErrorDetail); ok {
						detail = ed
					}
				}
			}
			if detail == nil {
				t.Fatal("rejection carries no ErrorDetail")
			}
			if detail.GetReason() != commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED {
				t.Errorf("reason = %v, want RATE_LIMITED", detail.GetReason())
			}
			if detail.GetRetryAfter() == nil || detail.GetRetryAfter().AsDuration() <= 0 {
				t.Errorf("retry_after = %v, want a positive duration", detail.GetRetryAfter())
			}
		})
	}
}

// TestScheduledBuckets_ShareTheCreatePostBucket (ADR-0021 D4): SchedulePost and CancelScheduledPost draw on the SAME
// 10/min bucket as CreatePost, so a user's creates, schedules and cancels together cannot exceed it, while
// ListScheduledPosts is a read on the 60/min default bucket and is not starved by an exhausted create bucket.
func TestScheduledBuckets_ShareTheCreatePostBucket(t *testing.T) {
	procs := []string{
		postsv1connect.PostServiceCreatePostProcedure,
		postsv1connect.PostServiceSchedulePostProcedure,
		postsv1connect.PostServiceCancelScheduledPostProcedure,
		postsv1connect.PostServiceListScheduledPostsProcedure,
	}
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 60
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	rl := RateLimitConfig(cfg)

	for _, p := range []string{postsv1connect.PostServiceSchedulePostProcedure, postsv1connect.PostServiceCancelScheduledPostProcedure} {
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != rl.PerProcedure[postsv1connect.PostServiceCreatePostProcedure] {
			t.Errorf("%s does not use the CreatePost limiter instance", p)
		}
	}
	if _, has := rl.PerProcedure[postsv1connect.PostServiceListScheduledPostsProcedure]; has {
		t.Error("ListScheduledPosts must use the default read bucket, not a dedicated one")
	}
	for _, p := range procs {
		if _, exempt := rl.ReadBudgetExempt[p]; exempt {
			t.Errorf("%s is on the read-budget exemption list; the list must stay empty", p)
		}
		if _, charge := rl.ReadBudgetChargeOnly[p]; charge {
			t.Errorf("%s is charge-only; only the account operations may be", p)
		}
	}

	setUID := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: "uid-sched", SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(setUID, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range procs {
		mux.Handle(p, connect.NewUnaryHandler(p,
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

	// 4 creates + 3 schedules + 3 cancels = the 10 calls of the minute, in any mix.
	mix := []string{procs[0], procs[1], procs[2], procs[0], procs[1], procs[2], procs[0], procs[1], procs[2], procs[0]}
	for i, p := range mix {
		if err := invoke(p); err != nil {
			t.Fatalf("call %d (%s) must pass: %v", i+1, p, err)
		}
	}
	for _, p := range procs[:3] {
		var ce *connect.Error
		if err := invoke(p); !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Errorf("%s after 10 shared calls: err = %v, want ResourceExhausted", p, err)
		}
	}
	if err := invoke(procs[3]); err != nil {
		t.Errorf("ListScheduledPosts must not draw on the create bucket: %v", err)
	}
}
