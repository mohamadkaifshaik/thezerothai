// messaging_wiring.go adapts messaging's outbound seams to the rest of the monolith (D9): the
// composition root is the one place that knows both messaging.Events and notifications.Emitter.
package apiserver

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
)

// messageNotifier implements messaging.Events: a delivered message to an accepted, non-silent recipient becomes one
// push-only `message` event (generic push) that names the conversation and nothing else.
type messageNotifier struct{ slot *emitterSlot }

var _ messaging.Events = messageNotifier{}

func (n messageNotifier) MessageSent(ctx context.Context, e messaging.MessageEvent) {
	n.slot.emit(ctx, notifications.Event{
		Type: notifications.TypeMessage, ActorID: e.ActorUID, RecipientIDs: []string{e.RecipientUID},
		ConversationID: e.ConversationID, At: e.At,
	})
}
