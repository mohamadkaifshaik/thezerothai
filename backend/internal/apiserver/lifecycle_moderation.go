// lifecycle_moderation.go joins the moderation module to the account-lifecycle registry (ADR-0016 D5): the reports
// Eraser step (anonymise the reports the account filed) and the `reports` export section (the reports the account
// filed, never reports about it). Kept apart from registerLifecycleModules so slices that add their own lines
// there do not collide with this one.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// reportsEraserStep is the reports step (step "reports"): ADR-0011 Q1 runs it with the other module steps, before
// the identity step.
func reportsEraserStep(e moderation.Eraser) identity.StepEraser {
	return eraserStep[moderation.Checkpoint]{name: "reports", purge: e.PurgeReporter}
}

// reportsSection is the export's `reports` section: moderation.Exporter already streams one JSON value to w.
type reportsSection struct{ x moderation.Exporter }

func (reportsSection) Name() string { return "reports" }

func (s reportsSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportUser(ctx, uid, w)
}

// registerModerationLifecycle registers the reports step and export section on l. Call it after
// registerLifecycleModules (Lifecycle always runs the identity step last).
func registerModerationLifecycle(l *identity.Lifecycle, repo *moderation.FirestoreRepo) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, reportsEraserStep(repo)); err != nil {
		return err
	}
	return l.RegisterExportSection(reportsSection{repo})
}
