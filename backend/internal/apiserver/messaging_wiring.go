// messaging_wiring.go adapts messaging's outbound seams to the rest of the monolith (ADR-0027 D4 step 6, D9): the
// composition root is the one place that knows both messaging.Events and notifications.Emitter.
package apiserver

import (
	"context"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
)

// messageEventType is the wire name of the push-only `message` notification type (ADR-0027 D9). notifications has no
// such type before W7-10, so notifications.Type(messageEventType) is not Valid(): Emitter.Emit drops the event in
// prepare (no publish, 0 cost), and a fan-out that does receive one drops it as "unknown_type" and acknowledges it.
// W7-10 replaces this constant with notifications.TypeMessage and fills Event.ConversationID.
const messageEventType notifications.Type = "message"

// messageNotifier implements messaging.Events: a delivered message to an accepted, non-silent recipient becomes one
// `message` event (generic push, W7-10). The conversation id is on the messaging.MessageEvent already; the notifications
// Event has no field for it yet (W7-10 adds Event.ConversationID), so it is not forwarded here.
type messageNotifier struct{ slot *emitterSlot }

var _ messaging.Events = messageNotifier{}

func (n messageNotifier) MessageSent(ctx context.Context, e messaging.MessageEvent) {
	n.slot.emit(ctx, notifications.Event{
		Type: messageEventType, ActorID: e.ActorUID, RecipientIDs: []string{e.RecipientUID}, At: e.At,
	})
}
