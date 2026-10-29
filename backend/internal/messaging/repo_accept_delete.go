package messaging

import (
	"context"
	"fmt"
	"maps"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Accept implements Repo: one transaction (ADR-0027 D4, D6, D11; plan W7-9).
//
// Reads, fresh and before any write: conversations/{convId} (1), then the caller's dmRequests entry (1): 2 in all. The
// rules of decideAccept apply to the conversation first, so an unknown id, a non-participant and the requester are
// ErrNotFound after 1 read, and an ACCEPTED conversation is success after 1 read with nothing written. A missing
// dmRequests entry (the recipient deleted the request for themselves) is ErrNotFound as well: a deleted conversation
// answers like an unknown one (D11).
//
// Writes: the conversation (state ACCEPTED, updatedAt) and the caller's dmInbox entry, a copy of the request entry as
// read (unreadCount, lastReadAt and the rest kept, changedAt = the accept stamp so the accepter's other devices pick the
// conversation up in their next INBOX since refresh; a whole-document Set, so an inbox entry that should not exist cannot
// make it fail; +0 writes for changedAt); 1 delete: the dmRequests entry. The requester's own entry already lives in the requester's dmInbox, so
// the move makes both sides see the conversation in the Inbox. Nothing is emitted: a request message never pushed (F7) and
// accepting is not a message.
//
// A concurrent DeleteConversation or a reply (Send, which accepts too) makes one of the two transactions retry: the
// loser re-reads the winner's state, so the entry ends in exactly one place or none.
func (r *FirestoreRepo) Accept(ctx context.Context, p AcceptParams) (AcceptResult, error) {
	var res AcceptResult
	attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			res = AcceptResult{}
			c := budget.FromContext(ctx)
			conv, err := r.txConversation(ctx, tx, p.ConvID)
			if err != nil {
				return err
			}
			dec, err := decideAccept(conv, p.UID)
			if err != nil {
				return err
			}
			res.Conv = *conv
			if dec.Already {
				res.Already = true
				return nil
			}
			if p.PeerAllowed != nil && !p.PeerAllowed(peerOf(conv.Participants, p.UID)) {
				return errPeerFlagOff
			}
			esnap, err := tx.Get(r.requestsRef(p.UID, p.ConvID))
			c.AddReads(1)
			switch status.Code(err) {
			case codes.OK:
			case codes.NotFound:
				return ErrNotFound
			default:
				return fmt.Errorf("messaging: read request entry: %w", err)
			}

			now := notBefore(wireTime(p.Now), conv.UpdatedAt) // updatedAt only moves forward, whatever the clock skew
			b := store.NewFirestoreTxBatch(tx, c)
			b.Update(r.convRef(p.ConvID), []firestore.Update{{Path: "state", Value: stateAccepted}, {Path: "updatedAt", Value: now}})
			// changedAt = the same stamp as updatedAt: the accepter's other devices see the conversation in their next INBOX
			// since refresh (ADR-0027 note 2026-10-29). Their REQUESTS cache drops the row locally; a delete never surfaces in since.
			moved := esnap.Data()
			moved["changedAt"] = now
			b.Set(r.inboxRef(p.UID, p.ConvID), moved)
			b.Delete(r.requestsRef(p.UID, p.ConvID))
			if berr := b.Err(); berr != nil {
				return berr
			}
			res.Conv.State, res.Conv.UpdatedAt = stateAccepted, now
			return nil
		})
	store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
	if err != nil {
		return AcceptResult{}, err
	}
	return res, nil
}

// Delete implements Repo: DeleteConversation, "delete for me" (ADR-0027 D1, D14; plan W7-9), one transaction.
//
// Reads, fresh and before any write: conversations/{convId} (1), then the caller's own entry (1), in the folder the
// conversation document says it lives in (decideDelete: dmRequests for the recipient of an unaccepted request, dmInbox
// otherwise), so no probe of the other folder is needed: 2 reads in all. An unknown id and a non-participant are
// ErrNotFound after 1 read.
//
// Writes: clearedAt.{caller} = now and clearedKey.{caller} = the key digest on the conversation, one field-level Update of
// those two map keys with updatedAt (the peer's keys are never touched; the key costs no read and no write of its own,
// ADR-0027 2026-10-29 note), and 1 delete: the caller's entry. The peer's entry, the messages and the conversation state are
// untouched: a deleted request stays a REQUEST for the sender, whose cap still applies, and a later message of the peer
// recreates the caller's entry (Send's Set with MergeAll) while ListMessages shows only what is newer than clearedAt.
//
// Replays, checked in this order: (1) the digest equals clearedKey.{caller}, so this is a retry of the caller's last delete:
// success with nothing written and the entry not even read (1 read), whatever happened since (a newer message stays visible
// and its recreated entry stays); (2) no entry and a clearedAt already set (deleteIsReplay, a retry under another key):
// success, nothing written, 2 reads. An entry gone but no clearedAt (an anomaly) still sets clearedAt: 1 write, 0 deletes.
func (r *FirestoreRepo) Delete(ctx context.Context, p DeleteParams) (DeleteResult, error) {
	var res DeleteResult
	attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			res = DeleteResult{}
			c := budget.FromContext(ctx)
			conv, err := r.txConversation(ctx, tx, p.ConvID)
			if err != nil {
				return err
			}
			folder, err := decideDelete(conv, p.UID)
			if err != nil {
				return err
			}
			res.Conv, res.Folder = *conv, folder
			if deleteIsKeyReplay(*conv, p.UID, p.KeyDigest) {
				res.Replay = true
				return nil
			}
			entry := r.entryRef(p.UID, p.ConvID, folder)
			esnap, err := tx.Get(entry)
			c.AddReads(1)
			exists := true
			var lastMessageAt time.Time
			switch status.Code(err) {
			case codes.OK:
				var ed EntryDoc
				if derr := esnap.DataTo(&ed); derr != nil {
					return fmt.Errorf("messaging: decode entry: %w", derr)
				}
				lastMessageAt = ed.LastMessageAt
			case codes.NotFound:
				exists = false
			default:
				return fmt.Errorf("messaging: read entry: %w", err)
			}
			if deleteIsReplay(*conv, p.UID, exists) {
				res.Replay = true
				return nil
			}

			// clearedAt is the handler's clock, but not before the newest message the caller's entry shows (a send may have
			// stamped one ahead of this clock, stampAfterClear), so everything the caller saw is cleared; updatedAt gets the same
			// stamp and never goes backwards.
			now := notBefore(wireTime(p.Now), conv.UpdatedAt, lastMessageAt)
			updates := []firestore.Update{
				{FieldPath: firestore.FieldPath{"clearedAt", p.UID}, Value: now},
				{Path: "updatedAt", Value: now},
			}
			if p.KeyDigest != "" {
				updates = append(updates, firestore.Update{FieldPath: firestore.FieldPath{"clearedKey", p.UID}, Value: p.KeyDigest})
			}
			b := store.NewFirestoreTxBatch(tx, c)
			b.Update(r.convRef(p.ConvID), updates)
			if exists {
				b.Delete(entry)
			}
			if berr := b.Err(); berr != nil {
				return berr
			}
			cleared := maps.Clone(conv.ClearedAt)
			if cleared == nil {
				cleared = map[string]time.Time{}
			}
			cleared[p.UID] = now
			res.Conv.ClearedAt, res.Conv.UpdatedAt, res.EntryDeleted = cleared, now, exists
			if p.KeyDigest != "" {
				keys := maps.Clone(conv.ClearedKey)
				if keys == nil {
					keys = map[string]string{}
				}
				keys[p.UID] = p.KeyDigest
				res.Conv.ClearedKey = keys
			}
			return nil
		})
	store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
	if err != nil {
		return DeleteResult{}, err
	}
	return res, nil
}
