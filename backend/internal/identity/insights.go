// insights.go is GetCreatorInsights (F2 Creator Studio insights, FEATURE_CREATOR_INSIGHTS): the caller's own daily stats
// (users/{uid}/dailyStats, daily_stats.go) over a window of IST days and the window before it, and up to five of the
// caller's posts by lifetime view count (posts owns them: TopPostsReader, the consumer-side seam wired in apiserver).
//
// Reads per call: one GetAll of 2 x window docs (56 at the default 28) and one top-posts query (Limit 5). Writes none.
// Caller only: the service takes the uid from the token, there is no target. The flag is checked before any read.
package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// MaxTopPosts is the length of CreatorInsights.TopPosts.
const MaxTopPosts = 5

// ErrTopPostsUnavailable is what a TopPostsReader answers when its query cannot run yet (Firestore's FAILED_PRECONDITION:
// the composite index is not deployed). GetCreatorInsights then answers with no top posts instead of failing.
var ErrTopPostsUnavailable = errors.New("identity: top posts unavailable")

// TopPost is one of the creator's posts in the top-posts list.
type TopPost struct {
	ID          string
	Text        string
	CreatedAt   time.Time
	ViewCount   int64
	LikeCount   int64
	RepostCount int64
	ReplyCount  int64
	QuoteCount  int64
}

// TopPostsReader is the consumer-side seam to posts (identity cannot import posts): uid's visible posts by lifetime
// viewCount, most viewed first, at most limit, none with zero views. ErrTopPostsUnavailable when the query cannot run.
type TopPostsReader interface {
	TopPostsByViews(ctx context.Context, uid string, limit int) ([]TopPost, error)
}

// DailyStatsReader reads a creator's daily stats by day key (*DailyStatsRepo).
type DailyStatsReader interface {
	ReadDailyStats(ctx context.Context, uid string, days []string) ([]DailyStats, error)
}

// InsightsTotals are sums over a window; every day is clamped at 0 per field before it is added.
type InsightsTotals struct {
	Impressions     int64
	Engagements     int64
	FollowersGained int64
	FollowersLost   int64
}

// CreatorInsights is the answer of GetCreatorInsights.
type CreatorInsights struct {
	WindowDays int
	Current    InsightsTotals
	Previous   InsightsTotals
	// Days are the window's days, oldest first, ending today, each clamped at 0.
	Days     []DailyStats
	TopPosts []TopPost
	// ImpressionsChangePct and EngagementsChangePct are (current - previous) / previous x 100; nil when previous is 0.
	ImpressionsChangePct *float64
	EngagementsChangePct *float64
}

// CreatorInsightsService serves GetCreatorInsights.
type CreatorInsightsService interface {
	GetCreatorInsights(ctx context.Context, uid string, windowDays int) (CreatorInsights, error)
}

// InsightsDeps are the collaborators of NewCreatorInsights.
type InsightsDeps struct {
	// Flags is FEATURE_CREATOR_INSIGHTS (nil = off for everyone).
	Flags FlagChecker
	Stats DailyStatsReader
	// TopPosts may be nil (no top posts).
	TopPosts TopPostsReader
	// Now is the clock (nil = time.Now).
	Now func() time.Time
}

type creatorInsights struct{ d InsightsDeps }

// NewCreatorInsights builds the service.
func NewCreatorInsights(d InsightsDeps) CreatorInsightsService { return &creatorInsights{d: d} }

// GetCreatorInsights implements CreatorInsightsService.
func (s *creatorInsights) GetCreatorInsights(ctx context.Context, uid string, windowDays int) (CreatorInsights, error) {
	var enabled func(uid, name string) bool
	if s.d.Flags != nil {
		enabled = s.d.Flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, CreatorInsightsFlag); err != nil {
		logger.SetRequestField(ctx, "feature", CreatorInsightsFlag)
		return CreatorInsights{}, flags.DisabledError().WithMeta("feature", CreatorInsightsFlag)
	}
	window, err := insightsWindow(windowDays)
	if err != nil {
		return CreatorInsights{}, err
	}
	if s.d.Stats == nil {
		return CreatorInsights{}, errors.New("identity: creator insights has no stats reader")
	}
	now := time.Now
	if s.d.Now != nil {
		now = s.d.Now
	}
	days := insightsDays(now(), 2*window)
	stats, err := s.d.Stats.ReadDailyStats(ctx, uid, days)
	if err != nil {
		return CreatorInsights{}, logger.RedactErr(fmt.Errorf("identity: creator insights: %w", err), uid)
	}
	out := aggregateInsights(stats, window)
	if s.d.TopPosts != nil {
		top, err := s.d.TopPosts.TopPostsByViews(ctx, uid, MaxTopPosts)
		switch {
		case errors.Is(err, ErrTopPostsUnavailable):
			slog.WarnContext(ctx, "creator_insights_top_posts_unavailable") // the index is missing: no ids, no uid
			top = nil
		case err != nil:
			return CreatorInsights{}, logger.RedactErr(fmt.Errorf("identity: creator insights: top posts: %w", err), uid)
		}
		if len(top) > MaxTopPosts {
			top = top[:MaxTopPosts]
		}
		out.TopPosts = top
	}
	return out, nil
}

// insightsWindow is the request's window: 0 is the default (MaxInsightsWindowDays), 1..MaxInsightsWindowDays is
// accepted, anything else is VALIDATION.
func insightsWindow(n int) (int, error) {
	switch {
	case n == 0:
		return MaxInsightsWindowDays, nil
	case n < 0 || n > MaxInsightsWindowDays:
		return 0, apierr.Validation("window_days", fmt.Sprintf("window_days must be between 1 and %d", MaxInsightsWindowDays))
	}
	return n, nil
}

// insightsDays are the n IST day keys ending with now's, oldest first. IST has no daylight saving, so 24 h steps are
// exact days.
func insightsDays(now time.Time, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = StatsDay(now.Add(-time.Duration(n-1-i) * 24 * time.Hour))
	}
	return out
}

// aggregateInsights splits 2 x window days (oldest first) into the previous and the current window, clamps every day
// at 0 per field (an undo-heavy day never subtracts from the others) and computes the % changes. Pure.
func aggregateInsights(stats []DailyStats, window int) CreatorInsights {
	out := CreatorInsights{WindowDays: window}
	split := max(len(stats)-window, 0)
	for i, d := range stats {
		d = clampDay(d)
		if i < split {
			out.Previous.add(d)
			continue
		}
		out.Current.add(d)
		out.Days = append(out.Days, d)
	}
	out.ImpressionsChangePct = changePct(out.Current.Impressions, out.Previous.Impressions)
	out.EngagementsChangePct = changePct(out.Current.Engagements, out.Previous.Engagements)
	return out
}

func clampDay(d DailyStats) DailyStats {
	d.Impressions, d.Engagements = max(d.Impressions, 0), max(d.Engagements, 0)
	d.FollowersGained, d.FollowersLost = max(d.FollowersGained, 0), max(d.FollowersLost, 0)
	return d
}

func (t *InsightsTotals) add(d DailyStats) {
	t.Impressions += d.Impressions
	t.Engagements += d.Engagements
	t.FollowersGained += d.FollowersGained
	t.FollowersLost += d.FollowersLost
}

// changePct is (cur - prev) / prev x 100, nil when prev is 0 (no baseline).
func changePct(cur, prev int64) *float64 {
	if prev <= 0 {
		return nil
	}
	v := float64(cur-prev) / float64(prev) * 100
	return &v
}
