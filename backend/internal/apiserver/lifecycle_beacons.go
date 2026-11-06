// lifecycle_beacons.go joins beacons to the account-lifecycle registry: the `beacons` Eraser step (the user's organised
// beacons with their participant docs, then the participant docs and membership rows of the user; none of it is removed
// by deleting users/{uid}) and the `beacons` export section (organised beacons and memberships). Both are registered
// whether or not FEATURE_BEACONS is on, because documents outlive the flag. The step is appended after `communities`:
// its name is persisted in deletionJob.step, so it never joins another module's checkpoint.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/beacons"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// beaconsEraserStep is the beacons step (step "beacons"): BeforeIdentity, after communities.
func beaconsEraserStep(e *beacons.Eraser) identity.StepEraser {
	return eraserStep[beacons.Checkpoint]{name: "beacons", purge: e.PurgeUser}
}

// beaconsSection is the export's `beacons` section: the embedded beacons.Exporter streams one JSON value to w.
type beaconsSection struct{ *beacons.Exporter }

func (beaconsSection) Name() string { return "beacons" }

func (s beaconsSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// registerBeaconsLifecycle registers the beacons step and export section on l. Call it after
// registerCommunitiesLifecycle (Lifecycle always runs the identity step last).
func registerBeaconsLifecycle(l *identity.Lifecycle, repo *beacons.FirestoreRepo) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, beaconsEraserStep(beacons.NewEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(beaconsSection{beacons.NewExporter(repo)})
}
