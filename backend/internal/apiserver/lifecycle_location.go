// lifecycle_location.go joins location to the account-lifecycle registry: the `location` Eraser step (users/{uid}/
// locationArea and users/{uid}/locationConsents are subcollections, which deleting users/{uid} does not remove) and the
// `location` export section (the chosen area and the full consent log). Both are registered whether or not
// FEATURE_LOCATION is on, because documents outlive the flag. The step is appended last (after impressions): its name is
// persisted in deletionJob.step, so it never joins another module's checkpoint.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/location"
)

// locationEraserStep is the location step (step "location"): BeforeIdentity, last.
func locationEraserStep(e *location.Eraser) identity.StepEraser {
	return eraserStep[location.Checkpoint]{name: "location", purge: e.PurgeUser}
}

// locationSection is the export's `location` section: the embedded location.Exporter streams one JSON value to w.
type locationSection struct{ *location.Exporter }

func (locationSection) Name() string { return "location" }

func (s locationSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// registerLocationLifecycle registers the location step and export section on l. Call it after
// registerImpressionLifecycle (Lifecycle always runs the identity step last).
func registerLocationLifecycle(l *identity.Lifecycle, repo *location.FirestoreRepo, catalog location.Catalog) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, locationEraserStep(location.NewEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(locationSection{location.NewExporter(repo, catalog)})
}
