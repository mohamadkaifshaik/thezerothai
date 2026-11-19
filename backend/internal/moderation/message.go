// message.go is moderation's side of "report a message": the target type, the one parser of
// the `<convId>:<msgId>` target id, and the consumer-side seam through which moderation reaches a message. moderation
// never reads conversations/* or messages itself: messaging implements MessageLookup and the composition
// root adapts it.
package moderation

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/encoding/protowire"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
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
// ReportContentRequest.message_payload), after every existing refusal: an encrypted message needs a payload, a plaintext
// one must have none (VALIDATION message_payload either way). For an encrypted message it replaces the evidence text with
// the disclosed text and adds the disclosed shared post id and the lookup's verdict. Nothing else of the payload is kept:
// not report_key, not the raw bytes.
//
// The content is the SENDER's bytes, which the server could not check on send, so nothing about them may make the
// message unreportable: the decode is lenient (decodeContent: invalid UTF-8 becomes U+FFFD, as the app's decoder shows
// it), a shared post id that is not a 19-digit id is dropped, and a payload that is not even well-formed protobuf is
// accepted when it is exactly what the sender committed to (Verified): it is then kept as "undecodable", with no text.
// Only bytes that are malformed AND do not match the commitment (the reporter's own garbage) are VALIDATION, with a
// fixed text that quotes nothing.
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
	c, ok := decodeContent(payload)
	if !ok {
		if !m.Verified {
			return apierr.Validation("message_payload", "message_payload is not a valid message content")
		}
		ev.Text = ""
		ev.MessageEncrypted, ev.MessageVerified, ev.MessageUndecodable = true, true, true
		return nil
	}
	ev.Text = c.Text
	if ids.ValidPostID(c.SharedPostID) {
		ev.SharedPostID = c.SharedPostID
	}
	ev.MessageEncrypted, ev.MessageVerified = true, m.Verified
	return nil
}

// disclosedContent is the lenient decode of a messaging.v1 MessageContent (testdata/report_payload_decode.json holds the
// vectors the Go and Dart decoders share).
type disclosedContent struct {
	Text         string
	SharedPostID string
}

// decodeContent walks the protobuf wire format of payload: field 1 (text) and field 2 (shared_post_id) with the
// length-delimited wire type are taken, the last occurrence winning (proto semantics); every other field, and fields 1
// and 2 with another wire type, is skipped as unknown. report_key (field 3) is skipped like any other field, never read.
// Both strings are made valid UTF-8 (replaceInvalidUTF8: one U+FFFD per decoding error), as Firestore needs and as the
// app's lenient decoder shows them. ok is false only when the bytes are not well-formed protobuf (a bad or out-of-range
// tag, a truncated or overflowing value, a reserved wire type, an unbalanced group).
func decodeContent(payload []byte) (c disclosedContent, ok bool) {
	var text, shared []byte
	for b := payload; len(b) > 0; {
		num, typ, n := protowire.ConsumeTag(b)
		// ConsumeTag accepts field numbers up to MaxInt32, but a tag above 2^29-1 is out of range, and the app's Dart
		// decoder reads tags as 32-bit varints (bits above 32 dropped): it would see another field than this walk skips.
		// Such bytes are malformed, never silently skipped.
		if n < 0 || num > protowire.MaxValidNumber {
			return disclosedContent{}, false
		}
		b = b[n:]
		if (num == 1 || num == 2) && typ == protowire.BytesType {
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return disclosedContent{}, false
			}
			if num == 1 {
				text = v
			} else {
				shared = v
			}
			b = b[m:]
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, b)
		if m < 0 {
			return disclosedContent{}, false
		}
		b = b[m:]
	}
	return disclosedContent{Text: replaceInvalidUTF8(text), SharedPostID: replaceInvalidUTF8(shared)}, true
}

// replaceInvalidUTF8 replaces each byte utf8.DecodeRuneInString rejects (it reports width 1 for every decoding error) with
// U+FFFD, one replacement per error, not one per run (strings.ToValidUTF8 would collapse a run), to match the app's
// lenient decoder; testdata/report_payload_decode.json pins the counts.
func replaceInvalidUTF8(b []byte) string {
	s := string(b)
	if utf8.ValidString(s) {
		return s
	}
	var out strings.Builder
	out.Grow(len(s) + 8)
	for s != "" {
		r, w := utf8.DecodeRuneInString(s)
		if r == utf8.RuneError && w == 1 {
			out.WriteRune(utf8.RuneError)
		} else {
			out.WriteString(s[:w])
		}
		s = s[w:]
	}
	return out.String()
}

// messageNotFound is the one NOT_FOUND of a message report (byte-identical for every cause).
func messageNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "message not found")
}
