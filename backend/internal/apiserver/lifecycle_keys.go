// lifecycle_keys.go joins keys to the account-lifecycle registry: the `keys` Eraser step (users/{uid}/keyDevices and its
// keyPackages pools and users/{uid}/keyDeviceRemovals are subcollections, which deleting users/{uid} does not remove) and
// the `keys` export section (device id, times, pool size and whether a last-resort package exists; the removed marks' ids
// and times; never key bytes). Both are registered whether or not
// FEATURE_E2EE_DM is on, because documents outlive the flag. The step is appended last (after location): its name is
// persisted in deletionJob.step, so it never joins another module's checkpoint.
package apiserver

import (
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
)

// keysEraserStep is the keys step (step "keys"): BeforeIdentity, last (after location).
func keysEraserStep(e *keys.Eraser) identity.StepEraser {
	return eraserStep[keys.Checkpoint]{name: "keys", purge: e.PurgeUser}
}

// registerKeysLifecycle registers the keys step and export section on l. Call it after registerLocationLifecycle
// (Lifecycle always runs the identity step last); keys.Exporter is itself the export section. Only the repository is needed.
func registerKeysLifecycle(l *identity.Lifecycle, repo *keys.FirestoreRepo) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, keysEraserStep(keys.NewEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(keys.NewExporter(repo))
}
