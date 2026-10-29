package messaging

import (
	"context"
	"errors"
	"fmt"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// removedSnippet is what a taken-down message leaves in a participant's inbox preview (the wire preview carries no
// snippet for a tombstone; the stored value only has to hold none of the removed text).
const removedSnippet = "Message removed"

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
	// participant's entry that still exists (at most 2); writes: the message 1 and each entry whose preview is that message
	// (at most 2), so at most 4 reads and 3 writes. Returns ErrNotFound for a message or conversation that does not exist.
	TakedownMessage(ctx context.Context, convID, msgID string, dryRun bool) (TakedownResult, error)
}

var _ Moderator = (*FirestoreRepo)(nil)

// TakedownMessage implements Moderator. One transaction reads everything first, then writes: the message becomes `REMOVED`
// with its text and request digest cleared (field-level Update, never Set, so a message deleted meanwhile is never
// recreated), and every participant's entry whose preview (`last.messageId`) is this message gets its snippet replaced and
// its `last.state` set to REMOVED. Both participants then see the message as removed on their next load. lastMessageAt is
// not touched (the inbox keeps its order), so a client that already cached the text keeps it until it reloads the first page
// (a `since` refresh never re-delivers an unchanged createdAt).
//
// Idempotent: a message that is already REMOVED or DELETED_ACCOUNT is left alone (1 read, 0 writes). A participant that is
// the DeletedUID placeholder, or whose entry no longer exists (deleted for themselves), is skipped. The tombstone keeps
// senderId, so the sender's own account deletion later finds the message through `senderId == uid` and keeps the REMOVED
// state (TombstonePage). Clearing requestHash means a retry of the same idempotency key now answers VALIDATION instead of
// replaying, as after the eraser.
//
// dryRun reads exactly the same and writes nothing.
func (r *FirestoreRepo) TakedownMessage(ctx context.Context, convID, msgID string, dryRun bool) (TakedownResult, error) {
	var out TakedownResult
	attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			out = TakedownResult{}
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
			if dryRun {
				return nil
			}

			b := store.NewFirestoreTxBatch(tx, c)
			b.Update(r.msgRef(convID, msgID), []firestore.Update{
				{Path: "state", Value: msgRemoved}, {Path: "text", Value: ""}, {Path: "requestHash", Value: ""},
			})
			for _, ref := range previews {
				b.Update(ref, []firestore.Update{{Path: "last.snippet", Value: removedSnippet}, {Path: "last.state", Value: msgRemoved}})
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
		return TakedownResult{}, logger.RedactErr(fmt.Errorf("messaging: take down message: %w", err), convID, msgID)
	}
	return out, nil
}
