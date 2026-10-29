package messaging

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Repo is the storage seam of messaging.Service: the three collections of ADR-0027 D1 behind one interface, so a group
// fan-out or a listener-backed store changes no caller (plan W7-5 seam). FirestoreRepo is the implementation.
type Repo interface {
	// GetConversation reads conversations/{id}: 1 read. found is false for a missing document.
	GetConversation(ctx context.Context, id string) (conv ConvDoc, found bool, err error)
	// Send runs the SendMessage transaction (ADR-0027 D4 step 5).
	Send(ctx context.Context, p SendParams) (SendResult, error)
	// ListEntries reads one page of the caller's entries in a folder (W7-7): reads max(len(rows), 1).
	ListEntries(ctx context.Context, uid string, folder string, q ListQuery) ([]EntryRow, error)
	// CountRequests is count() on the caller's dmRequests, capped at requestCountCap: 1 read.
	CountRequests(ctx context.Context, uid string) (int64, error)
	// CountUnreadConversations is count() on the caller's dmInbox where unreadCount > 0, Limit unreadConversationsCap
	// (ADR-0027 D10, W7-11): 1 read.
	CountUnreadConversations(ctx context.Context, uid string) (int64, error)
	// ListMessages reads one page of a conversation's messages (W7-8): reads max(len(rows), 1).
	ListMessages(ctx context.Context, convID string, q MessageQuery) ([]MessageRow, error)
	// MarkRead sets unreadCount = 0 and lastReadAt on the caller's own entry, in dmInbox else dmRequests, with an Exists
	// precondition (W7-8): 0 reads, 1 write; found is false (0 writes) when neither entry exists.
	MarkRead(ctx context.Context, uid, convID string, at time.Time) (found bool, err error)
	// GetEntry reads the caller's own entry in one folder (entryInbox or entryRequests, from entryFolder; W7-27): 1 read, billed
	// whether or not the document exists. found is false for a missing entry (delete-for-me, or never created).
	GetEntry(ctx context.Context, uid, convID, folder string) (entry EntryDoc, found bool, err error)
	// GetMessage reads one stored message (W7-12, report a message): 1 read; found is false for a missing document.
	GetMessage(ctx context.Context, convID, msgID string) (msg MsgDoc, found bool, err error)
	// Accept runs the AcceptMessageRequest transaction (W7-9): 2 reads (the conversation, the caller's dmRequests entry),
	// 2 writes and 1 delete; an already accepted conversation 1 read and nothing written.
	Accept(ctx context.Context, p AcceptParams) (AcceptResult, error)
	// Delete runs the DeleteConversation transaction (W7-9): 2 reads (the conversation, the caller's entry), 1 write
	// (clearedAt, clearedKey) and 1 delete (the entry); a retry with the same key 1 read in the transaction and nothing written,
	// any other repeat of a delete that already happened 2 reads and nothing written.
	Delete(ctx context.Context, p DeleteParams) (DeleteResult, error)
}

// AcceptParams is everything the accept transaction needs; the service has already validated the id and the caller's flag.
type AcceptParams struct {
	UID, ConvID string
	Now         time.Time
	// PeerAllowed reports whether the other participant has messaging on (the per-recipient half of ADR-0027 D6). It is
	// pure (flags are env vars, 0 reads) and runs inside the transaction once the peer is known, only when something
	// would be written. nil allows.
	PeerAllowed func(peerUID string) bool
}

// AcceptResult is the outcome of Accept.
type AcceptResult struct {
	// Already: the conversation was ACCEPTED before this call; nothing was written.
	Already bool
	// Conv is the conversation after the call, from the transaction's own read (the cache is updated from it).
	Conv ConvDoc
}

// DeleteParams is everything the delete transaction needs.
type DeleteParams struct {
	UID, ConvID string
	Now         time.Time
	// KeyDigest is keyDigest(uid, "DeleteConversation", idempotency_key). It is stored as clearedKey.{uid} with clearedAt, and
	// a delete whose digest equals the stored one is a replay (nothing written, whatever happened since).
	KeyDigest string
}

// DeleteResult is the outcome of Delete.
type DeleteResult struct {
	// Replay: nothing was written, because the request's key digest equals the stored clearedKey (a retry of the last delete),
	// or the entry was gone and the conversation already cleared for the caller.
	Replay bool
	// Folder is the folder the caller's entry lives in (entryInbox or entryRequests); EntryDeleted says one was deleted.
	Folder       string
	EntryDeleted bool
	// Conv is the conversation after the call (clearedAt[caller] included), from the transaction's own read.
	Conv ConvDoc
}

// MessageRow is one stored message with its id (the document id).
type MessageRow struct {
	ID string
	MsgDoc
}

// MessageQuery is one page of ListMessages: `createdAt DESC, __name__ DESC`, Limit rows. Before resumes below a position
// (an older page: StartAfter); After keeps only messages strictly newer than a position (a `since` refresh or a gap
// fill: EndBefore); ClearedAt, when set, drops every message with createdAt <= ClearedAt (the caller's delete-for-me).
type MessageQuery struct {
	Limit         int
	Before, After *cursor.Cursor
	ClearedAt     time.Time
}

// EntryRow is one inbox or requests entry with its conversation id (the document id).
type EntryRow struct {
	ID string
	EntryDoc
}

// ListQuery is one page of ListEntries: `lastMessageAt DESC, __name__ DESC`, Limit rows. Before resumes below a position
// (an older page: StartAfter); After keeps only entries strictly newer than a position (a `since` refresh: EndBefore). A
// query with After orders and positions by `changedAt` instead (After.CreatedAt is a changedAt), so a takedown or an erasure
// that changes an entry without moving its lastMessageAt still reaches a cached device.
type ListQuery struct {
	Limit         int
	Before, After *cursor.Cursor
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
