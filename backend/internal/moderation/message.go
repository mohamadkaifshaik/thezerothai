// message.go is moderation's side of "report a message": the target type, the one parser of
// the `<convId>:<msgId>` target id, and the consumer-side seam through which moderation reaches a message. moderation
// never reads conversations/* or messages itself: messaging implements MessageLookup and the composition
// root adapts it.
package moderation

import (
	"context"
	"errors"
	"regexp"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
)

// TargetMessage is a report about one direct message. The doc stores "MESSAGE"; targetId is "<convId>:<msgId>".
const TargetMessage TargetType = "MESSAGE"

// MessagingFlagName is the wire name of FEATURE_MESSAGING (messaging.FlagName; moderation does not import messaging).
// A report of a message needs it not globally off: a user dropped from the allowlist can still report.
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
	// Text is the message text: private content, kept as evidence only.
	Text string
	// CreatedAt is the time the message was sent.
	CreatedAt time.Time
	// Encrypted: the message belongs to an end-to-end encrypted conversation. Text is empty and the report must carry the
	// decrypted content (ReportInput.MessagePayload).
	Encrypted bool
	// Verified: the payload the lookup was given hashes to the sender's report commitment (messaging computes it; the
	// commitment bytes never reach moderation). False for a plaintext message, a mismatch, a missing payload and a
	// message whose commitment is gone (swept 30 days after the send).
	Verified bool
}

// MaxMessagePayloadBytes bounds ReportContentRequest.message_payload (moderation.proto: 1-8192 bytes).
const MaxMessagePayloadBytes = 8192

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

// MessageLookup is the consumer-side seam to messaging. ReportableMessage answers whether callerUID
// is a participant of the conversation and the message is the peer's and VISIBLE, and returns its evidence. It returns
// ErrMessageNotFound (one cause, one answer) or ErrOwnMessage, or an infrastructure error. It checks no flag: the caller's
// flag rules (reports on, messaging not globally off) are the handler's. It reads the conversation (instance
// cache), the message and the sender's profile (directory cache). payload is the reporter's disclosed MessageContent
// bytes (possibly empty): for an encrypted message the lookup answers Verified by comparing their commitment with the
// sender's; it never stores, logs or parses them. The payload rules (required, empty, parses) are moderation's.
type MessageLookup interface {
	ReportableMessage(ctx context.Context, callerUID, convID, msgID string, payload []byte) (ReportedMessage, error)
}

// fieldVerified is the request-log boolean of an encrypted MESSAGE report (never the payload or its text).
const fieldVerified = "message_verified"

// encryptedEvidence applies the payload rules that depend on the looked-up message (moderation.proto
// ReportContentRequest.message_payload), after every existing refusal: an encrypted message needs a payload that parses
// as MessageContent, a plaintext one must have none (VALIDATION message_payload either way). For an encrypted message it
// replaces the evidence text with the disclosed text and adds the disclosed shared post id and the lookup's verdict.
// Nothing else of the payload is kept: not report_key, not the raw bytes. The content's shape is the sending app's rule
// (the server could not check it on send), so it is not refused here: a sender must not be able to make its own message
// unreportable; a shared post id that is not a 19-digit id is dropped from the evidence instead.
func encryptedEvidence(m ReportedMessage, payload []byte, ev *Evidence) error {
	if !m.Encrypted {
		if len(payload) > 0 {
			return apierr.Validation("message_payload", "message_payload must be empty for this message")
		}
		return nil
	}
	if len(payload) == 0 {
		return apierr.Validation("message_payload", "message_payload is required to report this message")
	}
	c, err := disclosedContent(payload)
	if err != nil {
		return err
	}
	ev.Text = c.GetText()
	if id := c.GetSharedPostId(); ids.ValidPostID(id) {
		ev.SharedPostID = id
	}
	ev.MessageEncrypted, ev.MessageVerified = true, m.Verified
	return nil
}

// disclosedContent parses an encrypted message's report payload as messaging.v1 MessageContent. Unknown fields are
// tolerated (the verification is over the raw bytes, never over a re-serialisation); bytes that do not parse are the
// VALIDATION message_payload, with a fixed text that never carries the parser's error (it could quote content).
func disclosedContent(payload []byte) (*messagingv1.MessageContent, error) {
	var c messagingv1.MessageContent
	if err := proto.Unmarshal(payload, &c); err != nil {
		return nil, apierr.Validation("message_payload", "message_payload is not a valid message content")
	}
	return &c, nil
}

// messageNotFound is the one NOT_FOUND of a message report (byte-identical for every cause).
func messageNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "message not found")
}
