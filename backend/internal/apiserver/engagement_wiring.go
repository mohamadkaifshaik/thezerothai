// engagement_wiring.go composes the engagement module (P5, ADR-0018): its lifecycle registration, its
// notification adapter (ADR-0017 D2) and the composite post_delete job handler. Consumer-side adapters live here
// (the BlockChecker pattern, ADR-0002): engagement imports posts' seams only, never media or notifications.
package apiserver

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/engagement"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// engagementEraserStep is the engagement step (step "engagement", ADR-0018 D7): the user's likes and reposts
// with their counters, then userLikes/{uid}. It runs after the posts step (the user's own REPOST posts are gone)
// and before identity.
func engagementEraserStep(e engagement.Eraser) identity.StepEraser {
	return eraserStep[engagement.Checkpoint]{name: "engagement", purge: e.PurgeUser}
}

// engagementSection is the export's `engagement` section: engagement.Exporter already streams one JSON value.
type engagementSection struct{ x engagement.Exporter }

func (engagementSection) Name() string { return "engagement" }

func (s engagementSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportUser(ctx, uid, w)
}

// registerEngagementLifecycle registers the engagement step and export section on l. Call it after
// registerLifecycleModules (Lifecycle always runs the identity step last).
func registerEngagementLifecycle(l *identity.Lifecycle, repo *engagement.FirestoreRepo) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, engagementEraserStep(repo)); err != nil {
		return err
	}
	return l.RegisterExportSection(engagementSection{repo})
}

// engagementNotifier implements engagement.Events: a like notifies the post's author, a repost the original's
// author (ADR-0017 D4, D5; ADR-0018 D9). Self-actions are never announced. Replays never reach it (engagement
// calls it only for effects that were written).
type engagementNotifier struct{ slot *emitterSlot }

var _ engagement.Events = engagementNotifier{}

func (n engagementNotifier) Liked(ctx context.Context, actorUID string, post *posts.Post, at time.Time) {
	if post == nil || post.AuthorID == actorUID {
		return
	}
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeLike, ActorID: actorUID, RecipientIDs: []string{post.AuthorID}, PostID: post.ID, At: at,
	})
}

func (n engagementNotifier) Reposted(ctx context.Context, actorUID string, original *posts.Post, _ string, at time.Time) {
	if original == nil || original.AuthorID == actorUID {
		return
	}
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeRepost, ActorID: actorUID, RecipientIDs: []string{original.AuthorID}, PostID: original.ID, At: at,
	})
}

// jobHandler is the shape identity.JobHandler has (kept local: it is one method of someone else's package).
type jobHandler interface {
	Handle(ctx context.Context, data []byte) (string, error)
}

// postDeleteChain is the composite post_delete handler (ADR-0018 D10): the media step (a message without images is
// a noop that reads nothing), then the engagement step. Both always run, so a failure of one never leaves the
// other's work undone for a delivery; any error nacks the message and both steps are idempotent.
type postDeleteChain struct {
	media jobHandler
	eng   jobHandler
}

func (c postDeleteChain) Handle(ctx context.Context, data []byte) (string, error) {
	mo, merr := c.media.Handle(ctx, data)
	eo, eerr := c.eng.Handle(ctx, data)
	if err := errors.Join(merr, eerr); err != nil {
		return "", err
	}
	if mo == "noop" {
		return eo, nil
	}
	return mo + "+" + eo, nil
}
