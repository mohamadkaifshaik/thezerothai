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
	identityv1connect "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
)

// defaultRateLimitCfg is the config the guard inspects: the defaults.
func defaultRateLimitCfg() config.Config {
	cfg := config.Config{}
	// Per-minute buckets (the config.Load defaults).
	cfg.RateLimit.TimelinePerUserPerMinute = 6
	cfg.RateLimit.UserTimelinePerMinute = 30
	cfg.RateLimit.PostCreatePerMinute = 10
	cfg.RateLimit.PostDeletePerMinute = 20
	cfg.RateLimit.ReportPerMinute = 5
	cfg.RateLimit.BookmarksPerUserPerMinute = 30 // Add and Remove share it
	cfg.RateLimit.BookmarksListPerUserPerMinute = 10
	cfg.RateLimit.BookmarkMutationsPerDay = 1500 // M-1: Add and Remove share one daily call cap
	// Suggestions, likes list and relationship limits (the config.Load defaults).
	cfg.RateLimit.SuggestionsPerUserPerMinute = 10
	cfg.RateLimit.LikesListPerUserPerMinute = 10
	cfg.RateLimit.ProfileRelationshipPerUserPerMinute = 60
	// Poll vote limits (the config.Load defaults).
	cfg.RateLimit.PollVotePerUserPerMinute = 30
	// Share limits (the config.Load defaults).
	cfg.RateLimit.SharesPerUserPerMinute = 20
	cfg.RateLimit.SharesRecordedPerDay = 300
	// Impression limits (the config.Load defaults).
	cfg.RateLimit.ImpressionsPerUserPerMinute = 6
	cfg.RateLimit.ImpressionsRecordedPerDay = 500
	// Search and trends limits (the config.Load defaults).
	cfg.RateLimit.SearchPeoplePerUserPerMinute = 30
	cfg.RateLimit.SearchPostsPerUserPerMinute = 20
	// Follow request limits (the config.Load default).
	cfg.RateLimit.FollowRequestsRespondPerUserPerMinute = 60
	cfg.RateLimit.GraphListPerMinute = 20    // ListFollowRequests shares the graph list bucket (RATE_LIMIT_GRAPH_LIST_PER_MIN)
	cfg.RateLimit.ProfileUpdatesPerDay = 100 // L-4
	// Messaging limits (the config.Load defaults).
	cfg.RateLimit.MessagesSendPerUserPerMinute = 20
	cfg.RateLimit.MessagesReadPerUserPerMinute = 30
	cfg.RateLimit.MessagesSendsPerDay = 300
	cfg.RateLimit.MessagesMarkReadPerDay = 500 // (the config.Load defaults)
	cfg.RateLimit.MessagesMutationsPerDay = 500
	cfg.RateLimit.NotificationsListPerUserPerMinute = 30 // ListNotifications (the config.Load default)
	// Beacon limits (the config.Load defaults).
	cfg.RateLimit.BeaconsWritePerUserPerMinute = 10
	cfg.RateLimit.BeaconsActionPerUserPerMinute = 20
	cfg.RateLimit.BeaconsReadPerUserPerMinute = 30
	cfg.RateLimit.BeaconsCreatedPerDay = 10
	return cfg
}

// bookmarkMutationProcedures are the two bookmark RPCs that write an idempotency doc even when they change nothing
// (an already bookmarked Add, a Remove of a missing bookmark) and reserve no quota; they share one daily call cap.
var bookmarkMutationProcedures = []string{
	engagementv1connect.EngagementServiceAddBookmarkProcedure,
	engagementv1connect.EngagementServiceRemoveBookmarkProcedure,
}

// bookmarkMutationViolations asserts the M-1 wiring (mirrors the graph_mutation_daily shape): AddBookmark and
// RemoveBookmark each have a DailyCaps entry named bookmark_mutation_daily, both entries hold the SAME DailyCap
// (one counter per uid, so Add + Remove draw on one budget), and ListBookmarks (a read)
// has none.
func bookmarkMutationViolations(rl ratelimit.Config) []string {
	var out []string
	var first *ratelimit.DailyCap
	for _, p := range bookmarkMutationProcedures {
		named, ok := rl.DailyCaps[p]
		switch {
		case !ok || named.Cap == nil || named.Name != "bookmark_mutation_daily":
			out = append(out, "bookmark mutation "+p+" has no bookmark_mutation_daily DailyCaps entry")
		case first == nil:
			first = named.Cap
		case named.Cap != first:
			out = append(out, "bookmark mutation "+p+" does not share the bookmark_mutation_daily DailyCap with the other bookmark mutation")
		}
	}
	if _, ok := rl.DailyCaps[engagementv1connect.EngagementServiceListBookmarksProcedure]; ok {
		out = append(out, "ListBookmarks must not be on the bookmark_mutation_daily cap (a read)")
	}
	return out
}

// TestBookmarkMutationDailyCap_Guard proves the M-1 guard passes on the shipped wiring and can fail.
func TestBookmarkMutationDailyCap_Guard(t *testing.T) {
	remove := engagementv1connect.EngagementServiceRemoveBookmarkProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"remove loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, remove) }, "bookmark mutation " + remove},
		{"remove has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[remove] = ratelimit.NamedDailyCap{Name: "bookmark_mutation_daily"}
		}, "bookmark mutation " + remove},
		{"remove is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[remove]
			n.Name = "graph_mutation_daily"
			c.DailyCaps[remove] = n
		}, "bookmark mutation " + remove},
		{"remove gets its own counter", func(c *ratelimit.Config) {
			c.DailyCaps[remove] = ratelimit.NamedDailyCap{Name: "bookmark_mutation_daily", Cap: ratelimit.NewDailyCap(1500)}
		}, "does not share"},
		{"list joins the cap", func(c *ratelimit.Config) {
			c.DailyCaps[engagementv1connect.EngagementServiceListBookmarksProcedure] = c.DailyCaps[remove]
		}, "ListBookmarks must not"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(bookmarkMutationViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestBookmarkMutationDailyCap_StopsTheCapPlusFirstCall (M-1): through the wired interceptor, AddBookmark and
// RemoveBookmark draw on ONE per-uid daily budget, so the (cap+1)-th call of the day is ResourceExhausted whichever
// of the two it is, and another user is untouched (the name is asserted by the guard test above).
func TestBookmarkMutationDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 10
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.BookmarksPerUserPerMinute = 100000
	cfg.RateLimit.BookmarkMutationsPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range bookmarkMutationProcedures {
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
		if err := invoke("uid-bm", bookmarkMutationProcedures[i%2]); err != nil {
			t.Fatalf("bookmark mutation %d must pass: %v", i+1, err)
		}
	}
	for _, p := range bookmarkMutationProcedures {
		err := invoke("uid-bm", p)
		var ce *connect.Error
		if !errors.As(err, &ce) || ce.Code() != connect.CodeResourceExhausted {
			t.Fatalf("%s after %d calls: err = %v, want ResourceExhausted", p, dailyCap, err)
		}
	}
	if err := invoke("uid-other", bookmarkMutationProcedures[1]); err != nil {
		t.Fatalf("another user must not share the counter: %v", err)
	}
}

// profileUpdateViolations asserts the L-4 wiring: UpdateProfile has a DailyCaps entry named profile_update_daily
// with its own counter (no other procedure draws on it, so a busy account page cannot lock out account operations or
// the graph, and the reverse), and no other procedure carries the profile_update_daily name.
func profileUpdateViolations(rl ratelimit.Config) []string {
	var out []string
	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	named, ok := rl.DailyCaps[update]
	if !ok || named.Cap == nil || named.Name != "profile_update_daily" {
		return append(out, "UpdateProfile has no profile_update_daily DailyCaps entry")
	}
	for p, other := range rl.DailyCaps {
		switch {
		case p == update:
		case other.Cap == named.Cap:
			out = append(out, "procedure "+p+" shares the profile_update_daily DailyCap")
		case other.Name == "profile_update_daily":
			out = append(out, "procedure "+p+" is named profile_update_daily; only UpdateProfile may be")
		}
	}
	return out
}

// TestProfileUpdateDailyCap_Guard proves the L-4 guard passes on the shipped wiring and can fail.
func TestProfileUpdateDailyCap_Guard(t *testing.T) {
	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	tests := []struct {
		name   string
		mutate func(*ratelimit.Config)
		want   string // "" = no violation
	}{
		{"unmutated", func(*ratelimit.Config) {}, ""},
		{"update loses its cap", func(c *ratelimit.Config) { delete(c.DailyCaps, update) }, "UpdateProfile has no profile_update_daily"},
		{"update has a nil cap", func(c *ratelimit.Config) {
			c.DailyCaps[update] = ratelimit.NamedDailyCap{Name: "profile_update_daily"}
		}, "UpdateProfile has no profile_update_daily"},
		{"update is renamed", func(c *ratelimit.Config) {
			n := c.DailyCaps[update]
			n.Name = "graph_mutation_daily"
			c.DailyCaps[update] = n
		}, "UpdateProfile has no profile_update_daily"},
		{"change handle joins the counter", func(c *ratelimit.Config) {
			c.DailyCaps[identityv1connect.IdentityServiceChangeHandleProcedure] = c.DailyCaps[update]
		}, "shares the profile_update_daily DailyCap"},
		{"account export borrows the name", func(c *ratelimit.Config) {
			c.DailyCaps[identityv1connect.IdentityServiceGetAccountExportProcedure] = ratelimit.NamedDailyCap{Name: "profile_update_daily", Cap: ratelimit.NewDailyCap(5)}
		}, "only UpdateProfile may be"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rl := RateLimitConfig(defaultRateLimitCfg())
			tt.mutate(&rl)
			got := strings.Join(profileUpdateViolations(rl), "\n")
			if tt.want == "" && got != "" {
				t.Fatalf("unexpected violations: %s", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("violations %q do not contain %q", got, tt.want)
			}
		})
	}
}

// TestProfileUpdateDailyCap_StopsTheCapPlusFirstCall (L-4): through the wired interceptor, the (cap+1)-th
// UpdateProfile call of the day is RATE_LIMITED with limit=profile_update_daily, another user is untouched, and
// GetMe (no daily cap of its own) still passes for the capped user.
func TestProfileUpdateDailyCap_StopsTheCapPlusFirstCall(t *testing.T) {
	const dailyCap = 4
	cfg := defaultRateLimitCfg()
	cfg.RateLimit.PerUserPerMinute = 100000
	cfg.RateLimit.PerIPPerMinute = 100000
	cfg.RateLimit.ProfileUpdatesPerDay = dailyCap
	rl := RateLimitConfig(cfg)

	update := identityv1connect.IdentityServiceUpdateProfileProcedure
	getMe := identityv1connect.IdentityServiceGetMeProcedure
	uidOf := connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
			return next(authn.WithClaims(ctx, authn.Claims{UID: req.Header().Get("X-Test-Uid"), SignInProvider: authn.SignInProviderGoogle}), req)
		}
	})
	opts := connect.WithInterceptors(uidOf, ratelimit.Interceptor(rl))
	mux := http.NewServeMux()
	for _, p := range []string{update, getMe} {
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
		if err := invoke("uid-edit", update); err != nil {
			t.Fatalf("UpdateProfile call %d must pass: %v", i, err)
		}
	}
	err := invoke("uid-edit", update)
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
	if limit != "profile_update_daily" {
		t.Errorf("limit = %q, want profile_update_daily", limit)
	}
	if err := invoke("uid-other", update); err != nil {
		t.Errorf("another user must not share the counter: %v", err)
	}
	if err := invoke("uid-edit", getMe); err != nil {
		t.Errorf("GetMe has no daily call cap and must pass for the capped user: %v", err)
	}
}
