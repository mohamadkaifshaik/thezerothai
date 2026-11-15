package apiserver

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TestCreatorInsightsBucket_IsItsOwn (F2): GetCreatorInsights draws on its own per-user bucket
// (RATE_LIMIT_CREATOR_INSIGHTS_PER_MIN), not the default and not another procedure's, holds exactly the configured
// burst per uid, and has no daily cap.
func TestCreatorInsightsBucket_IsItsOwn(t *testing.T) {
	proc := identityv1connect.IdentityServiceGetCreatorInsightsProcedure
	for _, n := range []int{10, 3} {
		cfg := defaultRateLimitCfg()
		cfg.RateLimit.CreatorInsightsPerUserPerMinute = n
		rl := RateLimitConfig(cfg)
		lim := rl.PerProcedure[proc]
		if lim == nil || lim == rl.Default {
			t.Fatalf("%s has no bucket of its own", proc)
		}
		for p, other := range rl.PerProcedure {
			if p != proc && other == lim {
				t.Errorf("%s shares its bucket with %s", proc, p)
			}
		}
		if _, ok := rl.DailyCaps[proc]; ok {
			t.Errorf("%s must not have a daily cap", proc)
		}
		for i := 0; i < n; i++ {
			if ok, _ := lim.Allow("uid-1"); !ok {
				t.Fatalf("rate %d: call %d refused", n, i+1)
			}
		}
		if ok, _ := lim.Allow("uid-1"); ok {
			t.Errorf("rate %d: call %d allowed, want the bucket empty", n, n+1)
		}
		if ok, _ := lim.Allow("uid-2"); !ok {
			t.Errorf("rate %d: the bucket must be per user", n)
		}
	}
}

type fakeTopSource struct {
	ps  []*posts.Post
	err error
}

func (f fakeTopSource) TopPostsByViews(context.Context, string, int) ([]*posts.Post, error) {
	return f.ps, f.err
}

// TestTopPostsAdapter: the index-missing error becomes identity.ErrTopPostsUnavailable (the RPC degrades), other
// errors pass through, and the text is cut to 140 characters (runes, not bytes).
func TestTopPostsAdapter(t *testing.T) {
	ctx := context.Background()
	if _, err := (topPostsAdapter{fakeTopSource{err: posts.ErrTopPostsIndexMissing}}).TopPostsByViews(ctx, "u", 5); !errors.Is(err, identity.ErrTopPostsUnavailable) {
		t.Fatalf("index missing = %v", err)
	}
	boom := errors.New("boom")
	if _, err := (topPostsAdapter{fakeTopSource{err: boom}}).TopPostsByViews(ctx, "u", 5); !errors.Is(err, boom) {
		t.Fatalf("other error = %v", err)
	}
	at := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	long := strings.Repeat("日", 150)
	got, err := (topPostsAdapter{fakeTopSource{ps: []*posts.Post{{ID: "p1", Text: long, CreatedAt: at, ViewCount: 7, LikeCount: 2, ReplyCount: 1}}}}).TopPostsByViews(ctx, "u", 5)
	if err != nil || len(got) != 1 {
		t.Fatalf("got %v, %v", got, err)
	}
	if p := got[0]; p.ID != "p1" || len([]rune(p.Text)) != 140 || !p.CreatedAt.Equal(at) || p.ViewCount != 7 || p.LikeCount != 2 || p.ReplyCount != 1 {
		t.Fatalf("converted = %+v", p)
	}
	if cutRunes("short", 140) != "short" {
		t.Fatal("cutRunes changed a short text")
	}
}
