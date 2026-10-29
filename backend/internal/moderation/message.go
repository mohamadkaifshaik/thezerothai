// message.go is moderation's side of "report a message" (ADR-0027 D12, plan W7-12): the target type, the one parser of
// the `<convId>:<msgId>` target id, and the consumer-side seam through which moderation reaches a message. moderation
// never reads conversations/* or messages itself (ADR-0027 D11): messaging implements MessageLookup and the composition
// root adapts it.
package moderation

import (
	"context"
	"errors"
	"regexp"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// TargetMessage is a report about one direct message. The doc stores "MESSAGE"; targetId is "<convId>:<msgId>".
const TargetMessage TargetType = "MESSAGE"

// MessagingFlagName is the wire name of FEATURE_MESSAGING (messaging.FlagName; moderation does not import messaging).
// A report of a message needs it not globally off (ADR-0027 D6, F6): a user dropped from the allowlist can still report.
const MessagingFlagName = "messaging"

// messageTargetPattern is the one shape of a MESSAGE target_id: the conversation id and the message id, 32 lower-case hex
// each, joined by ":" (moderation.proto REPORT_TARGET_TYPE_MESSAGE).
var messageTargetPattern = regexp.MustCompile(`^([0-9a-f]{32}):([0-9a-f]{32})$`)

// ParseMessageTarget splits a MESSAGE target id into its conversation and message ids. ok is false for anything that is
// not exactly `<32 hex>:<32 hex>`. It is the one parser: ReportContent and `opsctl messages takedown` both use it.
func ParseMessageTarget(id string) (convID, msgID string, ok bool) {
	m := messageTargetPattern.FindStringSubmatch(id)
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// MessageTargetID is the inverse of ParseMessageTarget: the target id of one message.
func MessageTargetID(convID, msgID string) string { return convID + ":" + msgID }

// ReportedMessage is what a MessageLookup answers: the evidence of one message, taken at report time.
type ReportedMessage struct {
	// SenderUID is the peer who wrote the message; it becomes the report's TargetOwnerID (so `suspend-user --report` accepts
	// a message report). It never reaches a client or a log.
	SenderUID string
	// SenderHandle is the sender's handle, or "" when the sender is no longer ACTIVE (the thread still shows the message).
	SenderHandle string
	// Text is the message text: private content, kept as evidence only (ADR-0016 note 2026-10-28).
	Text string
	// CreatedAt is the time the message was sent.
	CreatedAt time.Time
}

// Lookup errors. Both are sentinels: moderation, not the implementer, builds the wire answer, so every "no such message"
// cause has the same bytes.
var (
	// ErrMessageNotFound covers every way a message can be unreportable for this caller: an unknown conversation, a
	// conversation the caller is not in, an unknown message, a message that is no longer VISIBLE (taken down, or its sender
	// deleted the account).
	ErrMessageNotFound = errors.New("moderation: message not found")
	// ErrOwnMessage is a message the caller wrote.
	ErrOwnMessage = errors.New("moderation: own message")
)

// MessageLookup is the consumer-side seam to messaging (ADR-0027 D12, D15). ReportableMessage answers whether callerUID
// is a participant of the conversation and the message is the peer's and VISIBLE, and returns its evidence. It returns
// ErrMessageNotFound (one cause, one answer) or ErrOwnMessage, or an infrastructure error. It checks no flag: the caller's
// flag rules (reports on, messaging not globally off) are the handler's. Firestore, worst case: conversation 1 (instance
// cache, 0 warm) + message 1 + the sender's profile 1 (directory cache, 0 warm).
type MessageLookup interface {
	ReportableMessage(ctx context.Context, callerUID, convID, msgID string) (ReportedMessage, error)
}

// messageNotFound is the one NOT_FOUND of a message report (ADR-0027 D11: byte-identical for every cause).
func messageNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "message not found")
}
