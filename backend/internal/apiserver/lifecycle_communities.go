// lifecycle_communities.go joins communities (ADR-0031 D9) to the account-lifecycle registry: the `communities` Eraser step (the user's
// member docs, moderator and owner roles, moderation-log entries and communityMemberships doc; none of it is removed by deleting
// users/{uid}) and the `communities` export section. Both are registered whether or not FEATURE_COMMUNITIES is on, because documents
// outlive the flag. The step is appended after `poll_votes`: its name is persisted in deletionJob.step, so it never joins another
// module's checkpoint and is never inserted before an existing step.
package apiserver

import (
	"context"
	"io"

	"github.com/dzeroth/dzeroth/backend/internal/communities"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// communitiesEraserStep is the communities step (step "communities"): BeforeIdentity, after poll_votes.
func communitiesEraserStep(e *communities.Eraser) identity.StepEraser {
	return eraserStep[communities.Checkpoint]{name: "communities", purge: e.PurgeUser}
}

// communitiesSection is the export's `communities` section: the embedded communities.Exporter streams one JSON value to w.
type communitiesSection struct{ *communities.Exporter }

func (communitiesSection) Name() string { return "communities" }

func (s communitiesSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// registerCommunitiesLifecycle registers the communities step and export section on l. Call it after registerPollVoteLifecycle
// (Lifecycle always runs the identity step last). dir tells the step whether a moderator's account is ACTIVE before it hands a
// community over; it may be nil (every community of a deleted owner is then archived), which the registration tests rely on.
func registerCommunitiesLifecycle(l *identity.Lifecycle, repo *communities.FirestoreRepo, dir identity.Directory) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, communitiesEraserStep(communities.NewEraser(repo, dir))); err != nil {
		return err
	}
	return l.RegisterExportSection(communitiesSection{communities.NewExporter(repo)})
}
