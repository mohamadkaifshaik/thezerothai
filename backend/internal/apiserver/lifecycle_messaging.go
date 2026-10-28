// lifecycle_messaging.go joins direct messages (ADR-0027 D8) to the account-lifecycle registry: the `messaging` Eraser
// step (conversations, their messages and users/{uid}/dmInbox and dmRequests, none of which deleting users/{uid} removes)
// and the `messages` export section (own messages in full, received ones as time and "received", no peer uid, F5). Both
// are registered whether or not FEATURE_MESSAGING is on, because documents outlive the flag. The step is appended after
// `follow_requests`: its name is persisted in deletionJob.step, so it never joins another module's checkpoint.
package apiserver

import (
	"context"
	"io"
	"log/slog"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// messagingStep adapts messaging.Eraser (whose checkpoint is already opaque bytes) to identity.StepEraser.
type messagingStep struct{ e messaging.Eraser }

func (messagingStep) Name() string { return "messaging" }

func (s messagingStep) Run(ctx context.Context, uid string, checkpoint []byte) ([]byte, bool, error) {
	return s.e.PurgeUser(ctx, uid, checkpoint)
}

// messagesSection is the export's `messages` section: messaging.Exporter streams one JSON value to w.
type messagesSection struct{ x messaging.Exporter }

func (messagesSection) Name() string { return "messages" }

func (s messagesSection) WriteSection(ctx context.Context, uid string, w io.Writer) error {
	return s.x.ExportUser(ctx, uid, w)
}

// messagingEraserStep is the messaging step (step "messaging"): BeforeIdentity, after follow_requests.
func messagingEraserStep(repo *messaging.FirestoreRepo, log *slog.Logger) identity.StepEraser {
	return messagingStep{messaging.NewEraser(repo, log)}
}

// registerMessagingLifecycle registers the messaging step and the messages export section on l. Call it after
// registerFollowRequestsLifecycle (Lifecycle always runs the identity step last). handles resolves the peers' current
// handles for the export (identity.Directory).
func registerMessagingLifecycle(l *identity.Lifecycle, repo *messaging.FirestoreRepo, handles messaging.HandleSource, log *slog.Logger) error {
	if err := l.RegisterEraser(identity.BeforeIdentity, messagingEraserStep(repo, log)); err != nil {
		return err
	}
	return l.RegisterExportSection(messagesSection{messaging.NewExporter(repo, handles)})
}
