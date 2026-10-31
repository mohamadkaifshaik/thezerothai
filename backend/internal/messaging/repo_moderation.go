package messaging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// removedSnippet is what a taken-down message leaves in a participant's inbox preview (the wire preview carries no
// snippet for a tombstone; the stored value only has to hold none of the removed text).
const removedSnippet = "Message removed"

// The stored message states as TakedownResult reports them, exported so the operator tool compares against the module's own
// values and not against copies of the strings.
const (
	MessageStateVisible        = msgVisible
	MessageStateRemoved        = msgRemoved
	MessageStateDeletedAccount = msgDeletedAccount
)

// TakedownResult is what TakedownMessage did.
type TakedownResult struct {
	// Before and After are the message's stored state (VISIBLE, REMOVED or DELETED_ACCOUNT). After is REMOVED for a message
	// that was VISIBLE; a message that is already REMOVED or DELETED_ACCOUNT stays as it is.
	Before, After string
	// Entries is the number of inbox or request entries whose preview was rewritten (or would be, on a dry run).
	Entries int
	// Wrote is true when anything was written; false on a dry run, on a repeat, and for a DELETED_ACCOUNT tombstone.
	Wrote bool
}

// Moderator is messaging's operator seam (ADR-0027 D12, plan W7-12): `opsctl messages takedown` takes one message down. The
// FirestoreRepo implements it; it is not part of the Repo the service uses.
type Moderator interface {
	// TakedownMessage tombstones one message. Reads: the message 1, and for a VISIBLE one the conversation 1 and each
	// participant's entry that still exists (at most 2); writes: the message 1, the conversation 1 (revision) and each entry
	// whose preview is that message (at most 2), so at most 4 reads and 4 writes; a repeat 1 read, 0 writes. Returns ErrNotFound for a message or conversation that does not exist.
	TakedownMessage(ctx context.Context, convID, msgID string, dryRun bool) (TakedownResult, error)
}

var _ Moderator = (*FirestoreRepo)(nil)

// TakedownMessage implements Moderator. One transaction reads everything first, then writes: the message becomes `REMOVED`
// with its text and request digest cleared (field-level Update, never Set, so a message deleted meanwhile is never
// recreated), and every participant's entry whose preview (`last.messageId`) is this message gets its snippet replaced and
// its `last.state` set to REMOVED. lastMessageAt is not touched (the inbox keeps its order). A takedown reaches devices that
// cached the thread or the inbox (ADR-0027 note 2026-10-29): the conversation gets `rev` +1 (a ListMessages since token
// issued before it is retired at the next poll, the client cold-opens and drops the cached text) and `updatedAt` strictly
// forward, the message `removedAt`, and each rewritten entry `changedAt` in server time (the next ListConversations since
// refresh returns it). The revision is bumped even when no entry previews the message.
//
// Idempotent: a message that is already REMOVED or DELETED_ACCOUNT is left alone (1 read, 0 writes). A participant that is
// the DeletedUID placeholder, or whose entry no longer exists (deleted for themselves), is skipped. The tombstone keeps
// senderId, so the sender's own account deletion later finds the message through `senderId == uid` and keeps the REMOVED
// state (TombstonePage, whose writes carry the document's LastUpdateTime, so a takedown that commits during a page is never
// overwritten). Clearing requestHash means a retry of the same idempotency key can no longer be compared: Send replays the
// REMOVED tombstone for it (no key-reused error, no second message).
//
// dryRun reads exactly the same and writes nothing; it runs as a read-only transaction.
func (r *FirestoreRepo) TakedownMessage(ctx context.Context, convID, msgID string, dryRun bool) (TakedownResult, error) {
	var out TakedownResult
	cfg := store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff}
	if dryRun {
		cfg.Options = []firestore.TransactionOption{firestore.ReadOnly} // reads only: no locks taken, nothing to commit
	}
	attempts, err := store.RunTransactionRetry(ctx, r.client, cfg,
		func(ctx context.Context, tx *firestore.Transaction) error {
			out = TakedownResult{}
			r.hooks.takedownRunStart()
			c := budget.FromContext(ctx)

			msnap, err := tx.Get(r.msgRef(convID, msgID))
			c.AddReads(1)
			if status.Code(err) == codes.NotFound {
				return ErrNotFound
			}
			if err != nil {
				return fmt.Errorf("messaging: read message: %w", err)
			}
			var msg MsgDoc
			if derr := msnap.DataTo(&msg); derr != nil {
				return fmt.Errorf("messaging: decode message: %w", derr)
			}
			out.Before, out.After = msg.State, msg.State
			if msg.State != msgVisible {
				return nil // already REMOVED, or tombstoned by the sender's account deletion: nothing to take down
			}
			out.After = msgRemoved

			csnap, err := tx.Get(r.convRef(convID))
			c.AddReads(1)
			if status.Code(err) == codes.NotFound {
				return ErrNotFound // a message without its conversation is part of a tree being deleted
			}
			if err != nil {
				return fmt.Errorf("messaging: read conversation: %w", err)
			}
			var conv ConvDoc
			if derr := csnap.DataTo(&conv); derr != nil {
				return fmt.Errorf("messaging: decode conversation: %w", derr)
			}

			// Every read before any write: the participants' entries that still preview this message.
			var previews []*firestore.DocumentRef
			for _, uid := range conv.Participants {
				if uid == DeletedUID {
					continue
				}
				ref := r.entryRef(uid, convID, entryFolder(conv, uid))
				esnap, eerr := tx.Get(ref)
				c.AddReads(1)
				if status.Code(eerr) == codes.NotFound {
					continue // the participant deleted the conversation for themselves
				}
				if eerr != nil {
					return fmt.Errorf("messaging: read entry: %w", eerr)
				}
				var e EntryDoc
				if derr := esnap.DataTo(&e); derr != nil {
					return fmt.Errorf("messaging: decode entry: %w", derr)
				}
				if e.Last.MessageID == msgID {
					previews = append(previews, ref)
				}
			}
			out.Entries = len(previews)
			if herr := r.hooks.takedownReads(); herr != nil {
				return herr
			}
			if dryRun {
				return nil
			}

			b := store.NewFirestoreTxBatch(tx, c)
			b.Update(r.msgRef(convID, msgID), []firestore.Update{
				{Path: "state", Value: msgRemoved}, {Path: "text", Value: ""}, {Path: "requestHash", Value: ""},
				{Path: "removedAt", Value: firestore.ServerTimestamp},
			})
			// The thread revision: every ListMessages since token issued before this commit is retired at its next poll, even
			// when no inbox preview shows the message (the thread still did). updatedAt moves strictly forward so the instance
			// cache, which never replaces a copy with an older updatedAt (putConv), cannot restore a pre-takedown one. The stamp
			// is the transaction's own read time (Firestore server time), never the operator's laptop clock: updatedAt is the
			// floor of Accept's changedAt, Delete's clearedAt and, through stampAfterClear, of every later send, so a clock
			// that runs ahead would push all of them into the future.
			b.Update(r.convRef(convID), []firestore.Update{
				{Path: "rev", Value: firestore.Increment(1)},
				{Path: "updatedAt", Value: notBefore(wireTime(csnap.ReadTime), conv.UpdatedAt.Add(time.Microsecond))},
			})
			for _, ref := range previews {
				// changedAt in server time (not the operator's clock) puts the entry in every cached device's next since refresh.
				b.Update(ref, []firestore.Update{
					{Path: "last.snippet", Value: removedSnippet}, {Path: "last.state", Value: msgRemoved},
					{Path: "changedAt", Value: firestore.ServerTimestamp},
				})
			}
			if berr := b.Err(); berr != nil {
				return berr
			}
			out.Wrote = true
			return nil
		})
	store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return TakedownResult{}, ErrNotFound
		}
		return TakedownResult{}, redactErr(fmt.Errorf("messaging: take down message: %w", err), convID, msgID)
	}
	return out, nil
}
