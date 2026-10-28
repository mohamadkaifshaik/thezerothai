package messaging

import (
	"context"
	"time"
)

// Repo is the storage seam of messaging.Service: the three collections of ADR-0027 D1 behind one interface, so a group
// fan-out or a listener-backed store changes no caller (plan W7-5 seam). FirestoreRepo is the implementation.
type Repo interface {
	// GetConversation reads conversations/{id}: 1 read. found is false for a missing document.
	GetConversation(ctx context.Context, id string) (conv ConvDoc, found bool, err error)
	// Send runs the SendMessage transaction (ADR-0027 D4 step 5).
	Send(ctx context.Context, p SendParams) (SendResult, error)
}

// SendParams is everything the send transaction needs; the service has already validated, checked blocks and flags.
type SendParams struct {
	UID, PeerUID string
	ConvID       string
	MsgID        string
	// Text is the normalised message; RequestHash the digest that tells a replay from a reused key.
	Text, RequestHash string
	Now               time.Time
	// Mutual: both follow each other; only decides the state of a conversation this send creates.
	Mutual bool
	// Silent: the recipient muted the caller (delivered without an unread increment). CallerSilent: the caller muted the
	// recipient (the flag on the sender's own entry).
	Silent, CallerSilent bool
	// Caller and Peer are the snapshots written into the other side's entry (caller's into the recipient's, peer's into
	// the sender's).
	Caller, Peer PeerDoc
	// MaxUnanswered is MESSAGES_REQUEST_MAX_UNANSWERED; DMNewLimit the daily new-conversation quota for this caller
	// (the new-account tier already applied).
	MaxUnanswered, DMNewLimit int64
	// FreshRecipient re-reads the recipient's account status without the cache (ADR-0027 D8 purge race). It is called
	// only when this send creates the conversation, inside the transaction, and returns ErrCannotMessage when the
	// recipient is not ACTIVE.
	FreshRecipient func(ctx context.Context) error
}

// SendResult is the outcome of Send.
type SendResult struct {
	// Replay: the message already existed with the same request digest; nothing was written.
	Replay bool
	// Created: this send created the conversation.
	Created bool
	// AcceptedByReply: this send was the reply that accepted a request.
	AcceptedByReply bool
	// RecipientInRequests: the recipient's entry for this message is in dmRequests (a request), else dmInbox.
	RecipientInRequests bool
	// Msg is the stored message (the replayed one on a replay); Conv the conversation after the send, best effort.
	Msg  MsgDoc
	Conv ConvDoc
}
