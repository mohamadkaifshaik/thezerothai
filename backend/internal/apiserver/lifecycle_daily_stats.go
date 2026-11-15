// lifecycle_daily_stats.go joins F2 creator insights to the account-lifecycle registry: the `daily_stats` Eraser step
// (users/{uid}/dailyStats is a subcollection, which deleting users/{uid} does not remove, and its 400-day TTL is far too
// late to count as erasure) and the `daily_stats` export section (the creator's own numbers, oldest first). Registered
// whether or not FEATURE_CREATOR_INSIGHTS is on, because documents outlive the flag. The step is appended last (after
// impressions): its name is persisted in deletionJob.step, and running after posts and graph means no counter write can
// reach the account any more (identity/daily_stats.go).
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// dailyStatsEraserStep is the daily_stats step (step "daily_stats"): BeforeIdentity, last.
func dailyStatsEraserStep(e *identity.DailyStatsEraser) identity.StepEraser {
	return eraserStep[identity.DailyStatsCheckpoint]{name: "daily_stats", purge: e.PurgeUser}
}

// dailyStatsExporter is the one method of identity's DailyStatsRepo the export section needs.
type dailyStatsExporter interface {
	ExportDailyStats(ctx context.Context, uid string, w io.Writer) error
}

// dailyStatsSection is the export's `daily_stats` section: one JSON array of {date, impressions, engagements,
// followersGained, followersLost}.
type dailyStatsSection struct{ x dailyStatsExporter }

func (dailyStatsSection) Name() string { return "daily_stats" }

func (s dailyStatsSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportDailyStats(ctx, uid, w)
}

// dailyStatsLifecycle is what the registration needs of identity's DailyStatsRepo.
type dailyStatsLifecycle interface {
	identity.DailyStatsPurger
	dailyStatsExporter
}

// registerDailyStatsLifecycle registers the daily_stats step and export section on l. Call it after
// registerImpressionLifecycle.
func registerDailyStatsLifecycle(l *identity.Lifecycle, repo dailyStatsLifecycle) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, dailyStatsEraserStep(identity.NewDailyStatsEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(dailyStatsSection{repo})
}
