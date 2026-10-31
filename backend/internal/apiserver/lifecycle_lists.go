// lifecycle_lists.go joins lists (ADR-0030 D8) to the account-lifecycle registry: the `lists` Eraser step (the user's own
// lists, then the uid inside other users' lists; none of it is removed by deleting users/{uid}) and the `lists` export
// section (the user's own lists with their member ids). Both are registered whether or not FEATURE_LISTS is on, because
// documents outlive the flag. The step is appended after `messaging`: its name is persisted in deletionJob.step, so it never
// joins another module's checkpoint.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/lists"
)

// listsEraserStep is the lists step (step "lists"): BeforeIdentity, after messaging.
func listsEraserStep(e *lists.Eraser) identity.StepEraser {
	return eraserStep[lists.Checkpoint]{name: "lists", purge: e.PurgeUser}
}

// listsSection is the export's `lists` section: the embedded lists.Exporter streams one JSON value to w.
type listsSection struct{ *lists.Exporter }

func (listsSection) Name() string { return "lists" }

func (s listsSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// registerListsLifecycle registers the lists step and export section on l. Call it after registerMessagingLifecycle
// (Lifecycle always runs the identity step last). handles and social feed the `lists_member_of` part (W5-46): owner handles and the user's own follows.
func registerListsLifecycle(l *identity.Lifecycle, repo *lists.FirestoreRepo, handles lists.HandleSource, social lists.SocialSource) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, listsEraserStep(lists.NewEraser(repo))); err != nil {
		return err
	}
	return l.RegisterExportSection(listsSection{lists.NewExporter(repo).WithMembership(repo, handles, social)})
}
