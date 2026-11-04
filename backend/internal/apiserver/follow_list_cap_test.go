package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// TestFollowListDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor ListFollowers and ListFollowing draw on ONE
// per-uid daily budget (the (cap+1)-th call is RATE_LIMITED limit=follow_list_daily whichever of the two it is), the blocked,
// muted and follow-request lists are not counted, and another uid is untouched.
func TestFollowListDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 6
	followers := graphv1connect.GraphServiceListFollowersProcedure
	following := graphv1connect.GraphServiceListFollowingProcedure
	uncapped := []string{
		graphv1connect.GraphServiceListBlockedUsersProcedure,
		graphv1connect.GraphServiceListMutedUsersProcedure,
		graphv1connect.GraphServiceListFollowRequestsProcedure,
	}
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.GraphListPerMinute = 100000
	cfg.RateLimit.FollowListCallsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range append([]string{followers, following}, uncapped...) {
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

	// The uncapped lists first, many times over the cap: they must not spend the follow-list budget.
	for i := 0; i < 2*dailyCap; i++ {
		for _, p := range uncapped {
			if err := invoke("uid-f", p); err != nil {
				t.Fatalf("%s call %d must pass: %v", p, i+1, err)
			}
		}
	}
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-f", []string{followers, following}[i%2]); err != nil {
			t.Fatalf("follow list call %d must pass: %v", i+1, err)
		}
	}
	for _, p := range []string{followers, following} {
		err := invoke("uid-f", p)
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("%s after %d shared calls: err = %v, want ResourceExhausted", p, dailyCap, err)
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
		if limit != "follow_list_daily" {
			t.Errorf("%s limit = %q, want follow_list_daily", p, limit)
		}
	}
	for _, p := range uncapped {
		if err := invoke("uid-f", p); err != nil {
			t.Errorf("%s after the follow-list cap is spent: %v", p, err)
		}
	}
	if err := invoke("uid-other", followers); err != nil {
		t.Errorf("another uid must be unaffected: %v", err)
	}
}
