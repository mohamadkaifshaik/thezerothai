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
	engagementv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// pollVoteViolations asserts the W6-4 wiring (ADR-0029 D6): VotePoll has its own per-minute bucket and a DailyCaps entry
// named poll_votes_daily holding its own cap, and no other engagement procedure shares that cap (likes are bounded by the
// likes quota, bookmarks by bookmark_mutation_daily). VotePoll writes, so it is not NO_SIDE_EFFECTS: the read budget
// still covers it (it covers every procedure).
func pollVoteViolations(rl ratelimit.Config) []string {
	var out []string
	vote := engagementv1connect.EngagementServiceVotePollProcedure
	if rl.PerProcedure[vote] == nil {
		out = append(out, "VotePoll needs its own per-minute bucket")
	}
	named, ok := rl.DailyCaps[vote]
	if !ok || named.Cap == nil || named.Name != "poll_votes_daily" {
		out = append(out, "VotePoll has no poll_votes_daily DailyCaps entry")
	}
	for p, n := range rl.DailyCaps {
		if p != vote && ok && n.Cap == named.Cap {
			out = append(out, "procedure "+p+" shares the poll_votes_daily DailyCap")
		}
	}
	if !rl.ReadBudgetCovers(vote) {
		out = append(out, "VotePoll is not covered by the daily read budget")
	}
	return out
}

// TestPollVoteWiring_Guard proves the guard passes on the shipped wiring and can fail.
func TestPollVoteWiring_Guard(t *testing.T) {
	vote := engagementv1connect.EngagementServiceVotePollProcedure
	like := engagementv1connect.EngagementServiceLikePostProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string
	}{
		{"shipped wiring", func(*ratelimit.Config) {}, ""},
		{"loses its bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, vote) }, "own per-minute bucket"},
		{"loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, vote) }, "no poll_votes_daily"},
		{"cap is misnamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[vote]
			n.Name = "other"
			c.DailyCaps[vote] = n
		}, "no poll_votes_daily"},
		{"likes join the cap", func(c *ratelimit.Config) { c.DailyCaps[like] = c.DailyCaps[vote] }, "shares the poll_votes_daily"},
		{"read budget off", func(c *ratelimit.Config) { c.ReadBudget = nil }, "not covered by the daily read budget"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(pollVoteViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestPollVoteDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor, the (cap+1)-th VotePoll of one user is
// ResourceExhausted with limit poll_votes_daily and never reaches the handler; another user and LikePost are untouched.
func TestPollVoteDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 4
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.PollVotePerUserPerMinute = 100000
	cfg.RateLimit.LikesPerUserPerMinute = 100000
	cfg.RateLimit.ReadBudgetPerUIDPerDay = 1 << 40
	cfg.RateLimit.PollVotesPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	handled := 0
	mux := http.NewServeMux()
	for _, p := range []string{engagementv1connect.EngagementServiceVotePollProcedure, engagementv1connect.EngagementServiceLikePostProcedure} {
		mux.Handle(p, connect.NewUnaryHandler(p,
			func(context.Context, *connect.Request[commonv1.ErrorDetail]) (*connect.Response[commonv1.ErrorDetail], error) {
				handled++
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
	vote := engagementv1connect.EngagementServiceVotePollProcedure
	for i := 0; i < dailyCap; i++ {
		if err := invoke("uid-v", vote); err != nil {
			t.Fatalf("vote %d must pass: %v", i+1, err)
		}
	}
	err := invoke("uid-v", vote)
	var ce *connect.Error
	if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
		t.Fatalf("vote %d: err = %v, want ResourceExhausted", dailyCap+1, err)
	}
	limit := ""
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				limit = ed.GetMetadata()["limit"]
			}
		}
	}
	if limit != "poll_votes_daily" {
		t.Errorf("limit = %q, want poll_votes_daily", limit)
	}
	if handled != dailyCap {
		t.Errorf("handler ran %d times, want %d (the rejected call must not reach it)", handled, dailyCap)
	}
	if err := invoke("uid-v", engagementv1connect.EngagementServiceLikePostProcedure); err != nil {
		t.Errorf("LikePost is not on the poll cap: %v", err)
	}
	if err := invoke("uid-other", vote); err != nil {
		t.Errorf("another user must not share the counter: %v", err)
	}
}
