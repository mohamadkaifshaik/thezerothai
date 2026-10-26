package apiserver

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// ADR-0024 D10 wiring (ticket W3-4): ListSuggestedUsers, ListLikedPosts and GetProfileRelationship each draw on their
// own per-user bucket, only ListSuggestedUsers has a daily call cap, and none is read-budget exempt or charge-only.
var (
	w3SuggestionsProc = graphv1connect.GraphServiceListSuggestedUsersProcedure
	w3LikesListProc   = engagementv1connect.EngagementServiceListLikedPostsProcedure
	w3RelationProc    = graphv1connect.GraphServiceGetProfileRelationshipProcedure
)

func TestProfileGraphBuckets_AreSeparateAndUnexempt(t *testing.T) {
	rl := RateLimitConfig(defaultRateLimitCfg())
	sug, likes, rel := rl.PerProcedure[w3SuggestionsProc], rl.PerProcedure[w3LikesListProc], rl.PerProcedure[w3RelationProc]
	if sug == nil || likes == nil || rel == nil {
		t.Fatalf("a W3 procedure has no per-procedure limiter: suggestions=%v likes=%v relationship=%v", sug, likes, rel)
	}
	if sug == likes || sug == rel || likes == rel {
		t.Error("the three W3 RPCs must each have their own limiter instance")
	}
	for _, p := range []string{w3SuggestionsProc, w3LikesListProc, w3RelationProc} {
		if rl.PerProcedure[p] == rl.Default {
			t.Errorf("%s must not share the default bucket", p)
		}
		if _, exempt := rl.ReadBudgetExempt[p]; exempt {
			t.Errorf("%s is on the read-budget exemption list; the list must stay empty", p)
		}
		if _, charge := rl.ReadBudgetChargeOnly[p]; charge {
			t.Errorf("%s is charge-only; only the account operations may be", p)
		}
	}
	named, ok := rl.DailyCaps[w3SuggestionsProc]
	if !ok || named.Cap == nil || named.Name != "suggestions_daily" {
		t.Errorf("ListSuggestedUsers DailyCaps entry = %+v, want a non-nil cap named suggestions_daily", named)
	}
	for _, p := range []string{w3LikesListProc, w3RelationProc} {
		if _, ok := rl.DailyCaps[p]; ok {
			t.Errorf("%s must not have a daily call cap (a read: the read budget covers it)", p)
		}
	}
}

// TestSuggestionsDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor, the (cap+1)-th ListSuggestedUsers
// call of the day is RATE_LIMITED with limit=suggestions_daily, another user is untouched, and the likes list (no
// daily cap) is unaffected.
func TestSuggestionsDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 5
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.SuggestionsPerUserPerMinute = 100000
	cfg.RateLimit.LikesListPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.SuggestionsCallsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range []string{w3SuggestionsProc, w3LikesListProc} {
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
	for i := 1; i <= dailyCap; i++ {
		if err := invoke("uid-sug", w3SuggestionsProc); err != nil {
			t.Fatalf("suggestions call %d must pass: %v", i, err)
		}
	}
	err := invoke("uid-sug", w3SuggestionsProc)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("call %d: err = %v, want ResourceExhausted", dailyCap+1, err)
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
	if limit != "suggestions_daily" {
		t.Errorf("limit = %q, want suggestions_daily", limit)
	}
	if err := invoke("uid-other", w3SuggestionsProc); err != nil {
		t.Errorf("another uid must be unaffected: %v", err)
	}
	if err := invoke("uid-sug", w3LikesListProc); err != nil {
		t.Errorf("the likes list has no daily cap and must pass: %v", err)
	}
}
