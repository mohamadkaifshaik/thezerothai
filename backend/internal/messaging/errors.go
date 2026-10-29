package messaging

import (
	"errors"
	"fmt"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// Sentinels the repo returns and the service maps to the wire (ADR-0027 D4, D5).
var (
	// ErrCannotMessage is every refusal that must look the same on the wire: a block in either direction, a recipient
	// that is not ACTIVE or has messaging off, and a conversation whose peer deleted the account.
	ErrCannotMessage = errors.New("messaging: cannot message")
	// ErrRequestLimit is MESSAGES_REQUEST_MAX_UNANSWERED reached in a REQUEST conversation.
	ErrRequestLimit = errors.New("messaging: unanswered request messages limit")
	// ErrDMNewDaily is QUOTA_DM_NEW_CONVERSATIONS_PER_DAY reached.
	ErrDMNewDaily = errors.New("messaging: new conversations per day limit")
	// ErrKeyReused is an idempotency key used before for a different request.
	ErrKeyReused = errors.New("messaging: idempotency key reused with a different request")
	// ErrNotFound is a conversation that does not exist or that the caller is not a participant of.
	ErrNotFound = errors.New("messaging: not found")
)

// errRecipientInactive is ErrCannotMessage for a recipient whose fresh status read (a new conversation, ADR-0027 D8) was
// not ACTIVE. It only exists to give the log its own refused_reason; the wire answer is the same.
var errRecipientInactive = fmt.Errorf("%w: recipient is not active", ErrCannotMessage)

// errPeerFlagOff is ErrCannotMessage for an AcceptMessageRequest whose other participant has messaging off (ADR-0027 D6:
// Accept needs the flag on for the caller and the peer). Like errRecipientInactive it only gives the log its own
// refused_reason; the wire answer is the same CANNOT_MESSAGE.
var errPeerFlagOff = fmt.Errorf("%w: peer has messaging off", ErrCannotMessage)

// cannotMessageText is the one text of every CANNOT_MESSAGE answer. The same error value shape is built for every
// cause, so the bytes on the wire are identical (ADR-0027 D4): no field says which rule refused.
const cannotMessageText = "you can't message this account"

func cannotMessage() *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, cannotMessageText)
}

func limitReached(name string) *apierr.Error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "limit reached").
		WithMeta("limit", name)
}

// notFoundText is the one NOT_FOUND message for an unknown id, a non-participant and a deleted conversation (D11).
const notFoundText = "conversation not found"

func notFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, notFoundText)
}

func keyReused() *apierr.Error {
	return apierr.Validation("idempotency_key", "this idempotency_key was already used for a different message")
}

// invalidKey is the VALIDATION answer for an idempotency_key that is not 16-64 characters of [A-Za-z0-9_-]; SendMessage
// stores its key in the message id, Accept and Delete do not store theirs but format-validate it all the same (ADR-0021's
// rule for a key the RPC does not use: "unused but still format-validated").
func invalidKey() *apierr.Error {
	return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
}
