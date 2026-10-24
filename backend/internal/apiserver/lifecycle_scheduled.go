// lifecycle_scheduled.go joins scheduled posts (ADR-0021 D4) to the account-lifecycle registry: the `scheduled`
// Eraser step (users/{uid}/scheduled is a subcollection, which deleting users/{uid} does not remove) and the
// `scheduled` export section (every document, with the draft wherever one is still held). Kept apart from
// registerLifecycleModules, like lifecycle_moderation.go, because the step runs after the existing ones.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// scheduledEraserStep is the scheduled step (step "scheduled"): ADR-0021 registers it BeforeIdentity after the
// existing steps, as engagement and reports are.
func scheduledEraserStep(e *posts.ScheduledEraser) identity.StepEraser {
	return eraserStep[posts.ScheduledCheckpoint]{name: "scheduled", purge: e.PurgeUser}
}

// scheduledExporter is the one method of posts.ScheduledExporter the export section needs.
type scheduledExporter interface {
	ExportUser(ctx context.Context, uid string, w io.Writer) error
}

// scheduledSection is the export's `scheduled` section: posts.ScheduledExporter streams one JSON value to w.
type scheduledSection struct{ x scheduledExporter }

func (scheduledSection) Name() string { return "scheduled" }

func (s scheduledSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportUser(ctx, uid, w)
}

// registerScheduledLifecycle registers the scheduled step and export section on l. Call it after
// registerModerationLifecycle (Lifecycle always runs the identity step last).
func registerScheduledLifecycle(l *identity.Lifecycle, repo *posts.FirestoreRepo) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, scheduledEraserStep(posts.NewScheduledEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(scheduledSection{posts.NewScheduledExporter(repo)})
}
