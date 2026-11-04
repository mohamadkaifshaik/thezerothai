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

// communityMutationProcedures and communityModProcedures share the one write bucket. Of these, only communityModCappedProcedures
// (hide a post, set a member's role, which is also how bans go) share the community_mod_actions_daily cap; RestoreCommunityPost
// stays uncapped so an owner can always undo hidden posts.
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
	communityModCappedProcedures = []string{
		communitiesv1connect.CommunityServiceHideCommunityPostProcedure,
		communitiesv1connect.CommunityServiceSetMemberRoleProcedure,
	}
	// communityReadProcedures share the read bucket.
	communityReadProcedures = []string{
		communitiesv1connect.CommunityServiceGetCommunityProcedure,
		communitiesv1connect.CommunityServiceListCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListMyCommunitiesProcedure,
		communitiesv1connect.CommunityServiceListCommunityMembersProcedure,
		communitiesv1connect.CommunityServiceListModerationLogProcedure,
	}
)

// communitiesRateLimitViolations asserts the wiring: the seven mutations share one limiter; Hide and SetMemberRole share one named
// DailyCap and nothing else in the service has a daily cap (Restore included); the five reads share a second limiter;
// GetCommunityTimeline has its own limiter and no daily cap; the three limiters are three different objects; and every
// CommunityService procedure is covered.
func communitiesRateLimitViolations(rl ratelimit.Config) []string {
	var out []string
	writeBucket := rl.PerProcedure[communityMutationProcedures[0]]
	for _, p := range append(append([]string{}, communityMutationProcedures...), communityModProcedures...) {
		if rl.PerProcedure[p] == nil || rl.PerProcedure[p] != writeBucket {
			out = append(out, "community mutation "+p+" does not share the communities write bucket")
		}
	}
	for _, p := range communityMutationProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "community mutation "+p+" must not be on a daily cap")
		}
	}
	if _, ok := rl.DailyCaps[communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure]; ok {
		out = append(out, "RestoreCommunityPost must not be on a daily cap")
	}
	var first *ratelimit.DailyCap
	for _, p := range communityModCappedProcedures {
		named, ok := rl.DailyCaps[p]
		switch {
		case !ok || named.Cap == nil || named.Name != communities.LimitModActionsDaily:
			out = append(out, "community mod action "+p+" has no "+communities.LimitModActionsDaily+" DailyCaps entry")
		case first == nil:
			first = named.Cap
		case named.Cap != first:
			out = append(out, "community mod action "+p+" does not share the "+communities.LimitModActionsDaily+" DailyCap")
		}
	}
	readBucket := rl.PerProcedure[communityReadProcedures[0]]
	for _, p := range communityReadProcedures {
		if _, ok := rl.DailyCaps[p]; ok {
			out = append(out, "community read "+p+" must not be on a daily cap")
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
	setRole := communitiesv1connect.CommunityServiceSetMemberRoleProcedure
	restore := communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure
	get := communitiesv1connect.CommunityServiceGetCommunityProcedure
	tl := timelinev1connect.TimelineServiceGetCommunityTimelineProcedure
	extra := ratelimit.NamedDailyCap{Name: "x_daily", Cap: ratelimit.NewDailyCap(200)}
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"hide loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, hide) }, "community mod action " + hide},
		{"hide has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[hide] = ratelimit.NamedDailyCap{Name: communities.LimitModActionsDaily}
		}, "community mod action " + hide},
		{"set role is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[setRole]
			n.Name = "other_daily"
			c.DailyCaps[setRole] = n
		}, "community mod action " + setRole},
		{"set role gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[setRole] = ratelimit.NamedDailyCap{Name: communities.LimitModActionsDaily, Cap: ratelimit.NewDailyCap(200)}
		}, "does not share the community_mod_actions_daily"},
		{"restore gains a cap", func(c *ratelimit.Config) { c.DailyCaps[restore] = c.DailyCaps[hide] }, "RestoreCommunityPost must not"},
		{"create gains a cap", func(c *ratelimit.Config) { c.DailyCaps[create] = extra }, "community mutation " + create + " must not"},
		{"hide leaves the write bucket", func(c *ratelimit.Config) {
			c.PerProcedure[hide] = ratelimit.NewLimiter(20, idleBucketTTL)
		}, "does not share the communities write bucket"},
		{"a read joins a daily cap", func(c *ratelimit.Config) { c.DailyCaps[get] = extra }, "community read " + get},
		{"a read leaves the read bucket", func(c *ratelimit.Config) { delete(c.PerProcedure, get) }, "does not share the communities read bucket"},
		{"the timeline joins a daily cap", func(c *ratelimit.Config) { c.DailyCaps[tl] = extra }, "GetCommunityTimeline must not"},
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

// TestCommunityModActionsDailyCap_StopsTheCapPlusFirstCall: through the wired interceptor Hide and SetMemberRole draw on ONE
// per-uid daily budget (the (cap+1)-th call of the day is ResourceExhausted whichever of the two it is), RestoreCommunityPost
// is never refused by it, the member mutations do not draw on it, and another user is untouched.
func TestCommunityModActionsDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const modCap = 5
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.CommunitiesWritePerUserPerMinute = 100000
	cfg.RateLimit.CommunitiesReadPerUserPerMinute = 100000
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
	for i := 0; i < modCap; i++ {
		if err := invoke("uid-c", communityModCappedProcedures[i%len(communityModCappedProcedures)]); err != nil {
			t.Fatalf("moderator action %d must pass: %v", i+1, err)
		}
	}
	for _, p := range communityModCappedProcedures {
		if err := invoke("uid-c", p); !exhausted(err) {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, modCap, err)
		}
	}
	if err := invoke("uid-c", communitiesv1connect.CommunityServiceRestoreCommunityPostProcedure); err != nil {
		t.Fatalf("restore must stay open with the moderator budget spent: %v", err)
	}
	for _, p := range communityMutationProcedures {
		if err := invoke("uid-c", p); err != nil {
			t.Fatalf("%s must not draw on the moderator cap: %v", p, err)
		}
	}
	if err := invoke("uid-c", communityReadProcedures[0]); err != nil {
		t.Fatalf("a community read must not draw on the cap: %v", err)
	}
	if err := invoke("uid-other", communityModCappedProcedures[0]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}
