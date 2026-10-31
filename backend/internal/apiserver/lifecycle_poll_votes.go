// lifecycle_poll_votes.go joins poll votes (ADR-0029 D8, ticket W6-8) to the account-lifecycle registry: the `poll_votes` Eraser
// step (pollVotes/{postId}_{uid}, a top-level collection that deleting users/{uid} does not touch) and the `poll_votes` export
// section (post id, choice and time per row). Both are registered whether or not FEATURE_POLLS is on, because documents outlive the
// flag. The step is appended after `messaging`, before identity: its name is persisted in deletionJob.step, so it never joins
// engagement's checkpoint and inserting it mid-sequence would strand in-flight jobs (ADR-0011 Q1). It still runs after
// `engagement`, which deleted userLikes (and userLikes.pollVotes) already.
package apiserver //nolint:dupl // mirrors lifecycle_bookmarks.go: the same step and section adapters over a different collection

import (
	"context"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// pollVoteSection is the export's `poll_votes` section: the embedded engagement.PollVoteExporter streams one JSON value.
type pollVoteSection struct{ *engagement.PollVoteExporter }

func (pollVoteSection) Name() string { return "poll_votes" }

func (s pollVoteSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.ExportUser(ctx, uid, w)
}

// pollVoteEraserStep is the poll_votes step (step "poll_votes"): BeforeIdentity, after messaging.
func pollVoteEraserStep(e *engagement.PollVoteEraser) identity.StepEraser {
	return eraserStep[engagement.PollVoteCheckpoint]{name: "poll_votes", purge: e.PurgeUser}
}

// registerPollVoteLifecycle registers the poll_votes step and export section on l. Call it after registerMessagingLifecycle
// (Lifecycle always runs the identity step last).
func registerPollVoteLifecycle(l *identity.Lifecycle, repo *engagement.FirestoreRepo, voteTTL time.Duration) error {
	err := l.RegisterEraser(identity.BeforeIdentity, pollVoteEraserStep(engagement.NewPollVoteEraser(repo)))
	if err == nil {
		err = l.RegisterExportSection(pollVoteSection{engagement.NewPollVoteExporter(repo).WithChoices(repo.LoadUserLikes, voteTTL, nil)})
	}
	return err
}
