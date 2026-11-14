// lifecycle_impressions.go joins F1 post views to the account-lifecycle registry: the `impressions` Eraser step
// (users/{uid}/impressions is a subcollection, which deleting users/{uid} does not remove, and its 48 h TTL is too late to
// count as erasure). There is no export section (purge_impressions.go). Registered whether or not FEATURE_POST_VIEWS is
// on, because documents outlive the flag. The step is appended last (after billing_bindings): its name is persisted in
// deletionJob.step, so it never joins engagement's checkpoint.
package apiserver

import (
	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// impressionEraserStep is the impressions step (step "impressions"): BeforeIdentity, last.
func impressionEraserStep(e *engagement.ImpressionEraser) identity.StepEraser {
	return eraserStep[engagement.ImpressionCheckpoint]{name: "impressions", purge: e.PurgeUser}
}

// registerImpressionLifecycle registers the impressions step on l. Call it after registerBillingLifecycle.
func registerImpressionLifecycle(l *identity.Lifecycle, repo engagement.ImpressionPurger) error {
	return l.RegisterEraser(identity.BeforeIdentity, impressionEraserStep(engagement.NewImpressionEraser(repo)))
}
