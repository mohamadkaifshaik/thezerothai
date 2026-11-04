package messaging

import (
	"context"
	"fmt"
	"maps"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Accept implements Repo: one transaction.
//
// Reads, fresh and before any write: conversations/{convId}, then the caller's dmRequests entry, then the requester's
// own dmInbox entry (it carries requestPending). The
// rules of decideAccept apply to the conversation first, so an unknown id, a non-participant and the requester are
// ErrNotFound after the first read, and an ACCEPTED conversation is success with nothing written. A missing
// dmRequests entry (the recipient deleted the request for themselves) is ErrNotFound as well: a deleted conversation
// answers like an unknown one (D11).
//
// Writes: the conversation (state ACCEPTED, updatedAt) and the caller's dmInbox entry, a copy of the request entry as
// read (unreadCount, lastReadAt and the rest kept, changedAt = the accept stamp so the accepter's other devices pick the
// conversation up in their next INBOX since refresh; a whole-document Set, so an inbox entry that should not exist cannot
// make it fail); the requester's dmInbox entry as a field-level Update (requestPending deleted, changedAt = the accept stamp),
// only when it exists (never created, so a requester who deleted it for themselves costs nothing); and the
// dmRequests entry is deleted. The requester's own entry already lives in the requester's dmInbox, so
// the move makes both sides see the conversation in the Inbox. Nothing is emitted: a request message never pushed (F7) and
// accepting is not a message.
//
// A concurrent DeleteConversation or a reply (Send, which accepts too) makes one of the two transactions retry: the
// loser re-reads the winner's state, so the entry ends in exactly one place or none.
func (r *FirestoreRepo) Accept(ctx context.Context, p AcceptParams) (AcceptResult, error) {
	var res AcceptResult
	attempts, err := store.RunTransactionRetry(ctx, r.txRunner(), store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			res = AcceptResult{}
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
			switch status.Code(err) {
			case codes.OK:
			case codes.NotFound:
				return ErrNotFound
			default:
				return fmt.Errorf("messaging: read request entry: %w", err)
			}

			// The requester's own dmInbox entry, read fresh and before any write: it carries requestPending, which this
			// accept clears. A missing entry (the requester deleted the conversation for themselves) is left missing: a blind Update
			// would fail the whole transaction and a Set would create a ghost entry the changedAt query returns.
			reqRef := r.inboxRef(conv.RequestFrom, p.ConvID)
			rsnap, rerr := tx.Get(reqRef)
			requesterHasEntry := false
			switch status.Code(rerr) {
			case codes.OK:
				requesterHasEntry = rsnap.Exists()
			case codes.NotFound:
			default:
				return fmt.Errorf("messaging: read requester entry: %w", rerr)
			}

			now := notBefore(wireTime(p.Now), conv.UpdatedAt) // updatedAt only moves forward, whatever the clock skew
			b := store.NewFirestoreTxBatch(tx)
			b.Update(r.convRef(p.ConvID), []firestore.Update{{Path: "state", Value: stateAccepted}, {Path: "updatedAt", Value: now}})
			// changedAt = the same stamp as updatedAt: the accepter's other devices see the conversation in their next INBOX
			// since refresh. Their REQUESTS cache drops the row locally; a delete never surfaces in since.
			moved := esnap.Data()
			moved["changedAt"] = now
			b.Set(r.inboxRef(p.UID, p.ConvID), moved)
			b.Delete(r.requestsRef(p.UID, p.ConvID))
			if requesterHasEntry {
				// Field-level: requestPending off and changedAt moved, so the requester's next INBOX since refresh returns the row as ACCEPTED.
				b.Update(reqRef, []firestore.Update{{Path: "requestPending", Value: firestore.Delete}, {Path: "changedAt", Value: now}})
			}
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

// Delete implements Repo: DeleteConversation, "delete for me", one transaction.
//
// Reads, fresh and before any write: conversations/{convId}, then the caller's own entry, in the folder the
// conversation document says it lives in (decideDelete: dmRequests for the recipient of an unaccepted request, dmInbox
// otherwise), so no probe of the other folder is needed. An unknown id and a non-participant are
// ErrNotFound after the first read.
//
// Writes: clearedAt.{caller} = now and clearedKey.{caller} = the key digest on the conversation, one field-level Update of
// those two map keys with updatedAt (the peer's keys are never touched; the key costs no read and no write of its own),
// and the caller's entry is deleted. The peer's entry, the messages and the conversation state are
// untouched: a deleted request stays a REQUEST for the sender, whose cap still applies, and a later message of the peer
// recreates the caller's entry (Send's Set with MergeAll) while ListMessages shows only what is newer than clearedAt.
//
// Replays, checked in this order: (1) the digest equals clearedKey.{caller}, so this is a retry of the caller's last delete:
// success with nothing written and the entry not even read, whatever happened since (a newer message stays visible
// and its recreated entry stays); (2) no entry and a clearedAt already set (deleteIsReplay, a retry under another key):
// success, nothing written. An entry gone but no clearedAt (an anomaly) still sets clearedAt, with nothing to delete.
func (r *FirestoreRepo) Delete(ctx context.Context, p DeleteParams) (DeleteResult, error) {
	var res DeleteResult
	attempts, err := store.RunTransactionRetry(ctx, r.txRunner(), store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			res = DeleteResult{}
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
			b := store.NewFirestoreTxBatch(tx)
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
