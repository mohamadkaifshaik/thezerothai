package messaging

import (
	"context"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// Repo is the storage seam of messaging.Service: the three collections behind one interface, so a group
// fan-out or a listener-backed store changes no caller (seam). FirestoreRepo is the implementation.
type Repo interface {
	// GetConversation reads conversations/{id}. found is false for a missing document.
	GetConversation(ctx context.Context, id string) (conv ConvDoc, found bool, err error)
	// Send runs the SendMessage transaction.
	Send(ctx context.Context, p SendParams) (SendResult, error)
	// ListEntries reads one page of the caller's entries in a folder.
	ListEntries(ctx context.Context, uid string, folder string, q ListQuery) ([]EntryRow, error)
	// CountRequests is count() on the caller's dmRequests, capped at requestCountCap.
	CountRequests(ctx context.Context, uid string) (int64, error)
	// CountUnreadConversations is count() on the caller's dmInbox where unreadCount > 0, Limit unreadConversationsCap.
	CountUnreadConversations(ctx context.Context, uid string) (int64, error)
	// ListMessages reads one page of a conversation's messages.
	ListMessages(ctx context.Context, convID string, q MessageQuery) ([]MessageRow, error)
	// MarkRead sets unreadCount = 0 and lastReadAt on the caller's own entry, in dmInbox else dmRequests, with an Exists
	// precondition, with no read; found is false (and nothing is written) when neither entry exists. receipt also sets
	// readReceiptAt (F3: the caller's read-receipts setting is on); false leaves any earlier readReceiptAt as it was.
	MarkRead(ctx context.Context, uid, convID string, at time.Time, receipt bool) (found bool, err error)
	// GetEntry reads the caller's own entry in one folder (entryInbox or entryRequests, from entryFolder). found is false for a missing entry (delete-for-me, or never created).
	GetEntry(ctx context.Context, uid, convID, folder string) (entry EntryDoc, found bool, err error)
	// GetMessage reads one stored message (report a message); found is false for a missing document.
	GetMessage(ctx context.Context, convID, msgID string) (msg MsgDoc, found bool, err error)
	// Accept runs the AcceptMessageRequest transaction: it reads the conversation and the caller's dmRequests entry, writes two docs and deletes
	// the request entry; an already accepted conversation reads once and writes nothing.
	Accept(ctx context.Context, p AcceptParams) (AcceptResult, error)
	// Delete runs the DeleteConversation transaction: it reads the conversation and the caller's entry, writes
	// clearedAt and clearedKey and deletes the entry; a retry with the same key, or any other repeat of a delete that
	// already happened, writes nothing.
	Delete(ctx context.Context, p DeleteParams) (DeleteResult, error)
}

// AcceptParams is everything the accept transaction needs; the service has already validated the id and the caller's flag.
type AcceptParams struct {
	UID, ConvID string
	Now         time.Time
	// PeerAllowed reports whether the other participant has messaging on (the per-recipient half of the flag gate). It is
	// pure (flags are env vars, no read) and runs inside the transaction once the peer is known, only when something
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
	// SharedPostID is the original post this message shares ("" for none): stored on the message, flagged on both previews.
	SharedPostID string
	Now          time.Time
	// CallerFollowsPeer: the caller follows the recipient (from the caller.s cached graph, 60 s). Mutual = this AND the
	// recipient.s FRESH Following[caller] read in the transaction; it only decides the state of a conversation this send
	// creates.
	CallerFollowsPeer bool
	// CallerSilent: the caller muted the recipient (the flag on the sender.s own entry). Whether the RECIPIENT muted the
	// caller (Silent) is read in the transaction and returned in SendResult.
	CallerSilent bool
	// Caller and Peer are the snapshots written into the other side's entry (caller's into the recipient's, peer's into
	// the sender's).
	Caller, Peer PeerDoc
	// MaxUnanswered is MESSAGES_REQUEST_MAX_UNANSWERED; DMNewLimit the daily new-conversation quota for this caller
	// (the new-account tier already applied).
	MaxUnanswered, DMNewLimit int64
	// RecipientGraphInTx reads the recipient.s graph/{uid} through the transaction (graph.TxReader.SnapshotInTx, uncached).
	// Required. Blocked[caller] refuses the send before every cap; Following[caller] makes
	// the conversation mutual; Muted[caller] makes it silent.
	// RecipientFollowingOnly (F9): the recipient's dm_policy is FOLLOWING_ONLY and FEATURE_DM_POLICY is on for them, as the
	// service read it from the recipient's profile (instance-cached, at most CACHE_TTL stale). The rule itself runs in the
	// transaction against the recipient's fresh Following set (dmPolicyRefuses).
	RecipientFollowingOnly bool
	RecipientGraphInTx     func(ctx context.Context, tx *firestore.Transaction) (graph.Snapshot, error)
	// RecipientInTx reads the recipient.s users/{uid} through the transaction (identity.TxProfiles.ProfileInTx). It
	// is called only when this send creates the conversation (purge race, security review L-3); a missing
	// document or a status other than ACTIVE refuses the send. Required for a new conversation.
	RecipientInTx func(ctx context.Context, tx *firestore.Transaction) (identity.Profile, error)
}

// SendResult is the outcome of Send.
type SendResult struct {
	// Replay: the message already existed with the same request digest; nothing was written.
	Replay bool
	// Created: this send created the conversation.
	Created bool
	// AcceptedByReply: this send was the reply that accepted a request.
	AcceptedByReply bool
	// Silent: the recipient muted the caller (the delivery has no unread increment, no push); Mutual: both follow each
	// other. Both come from the graph document read in the transaction, never from a cache.
	Silent, Mutual bool
	// RecipientInRequests: the recipient's entry for this message is in dmRequests (a request), else dmInbox.
	RecipientInRequests bool
	// Msg is the stored message (the replayed one on a replay); Conv the conversation after the send, best effort.
	Msg  MsgDoc
	Conv ConvDoc
}
