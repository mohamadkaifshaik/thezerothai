// moderation_messages.go adapts messaging to moderation.MessageLookup (ADR-0027 D12, D15; plan W7-12): the composition root is
// the one place that knows both modules. moderation defines the interface and its own types and never imports messaging;
// messaging never imports moderation.
package apiserver

import (
	"context"
	"errors"

	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/internal/moderation"
)

// lateMessageLookup is moderation.MessageLookup bound to the messaging service after it is built: moderation is constructed
// first (it is registered with the account lifecycle and wired with the report routes), the messaging service later, and
// moderation needs the lookup only per request. Set once at startup, before ListenAndServe, and never again (the
// lateAccountDirectory pattern).
type lateMessageLookup struct{ r messaging.MessageReporter }

var _ moderation.MessageLookup = (*lateMessageLookup)(nil)

// ReportableMessage maps messaging's answer to moderation's: ErrNotFound and ErrOwnMessage become moderation's sentinels
// (moderation builds the one wire NOT_FOUND from them), the evidence is copied field by field, anything else passes through.
func (l *lateMessageLookup) ReportableMessage(ctx context.Context, callerUID, convID, msgID string) (moderation.ReportedMessage, error) {
	if l.r == nil {
		return moderation.ReportedMessage{}, errors.New("message reports are not wired")
	}
	m, err := l.r.ReportableMessage(ctx, callerUID, convID, msgID)
	switch {
	case errors.Is(err, messaging.ErrNotFound):
		return moderation.ReportedMessage{}, moderation.ErrMessageNotFound
	case errors.Is(err, messaging.ErrOwnMessage):
		return moderation.ReportedMessage{}, moderation.ErrOwnMessage
	case err != nil:
		return moderation.ReportedMessage{}, err
	}
	return moderation.ReportedMessage{SenderUID: m.SenderUID, SenderHandle: m.SenderHandle, Text: m.Text, CreatedAt: m.CreatedAt}, nil
}
