package messaging

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// lifecyclePage is the page of the eraser and of the export (a Firestore batch holds 500 writes).
const lifecyclePage = 500

// Which of a user's own entries holds a conversation (ADR-0027 D1): dmRequests only for the recipient of a request that
// has not been accepted, dmInbox for everything else.
const (
	entryInbox    = "inbox"
	entryRequests = "requests"
)

// entryFolder is the folder of uid's own entry for c: stable once uid is being deleted, because only the account's own
// reply or accept moves it, and a DELETING account can do neither.
func entryFolder(c ConvDoc, uid string) string {
	if c.State == stateRequest && c.RequestTo == uid {
		return entryRequests
	}
	return entryInbox
}

func (r *FirestoreRepo) entryRef(uid, convID, folder string) *firestore.DocumentRef {
	if folder == entryRequests {
		return r.requestsRef(uid, convID)
	}
	return r.inboxRef(uid, convID)
}

// goneResult is what marking a conversation gone learned.
type goneResult struct {
	// Missing: the conversation is gone from Firestore already (the peer's eraser deleted the tree), or uid is not a
	// participant: nothing to do.
	Missing bool
	// Both: the peer is gone too, so the whole tree is deleted once uid's part is done.
	Both bool
	// Entry is the folder of uid's own entry (entryInbox or entryRequests).
	Entry string
}

// NextConversation returns the first conversation of uid after the cursor `after` ("" = from the start) in __name__
// order: `participants array-contains uid ORDER BY __name__ ASC LIMIT 1`, served by the automatic array index. Reads: 1
// (an empty query bills 1). A conversation the eraser finished stays listed while the peer lives, so the caller moves
// the cursor past it.
func (r *FirestoreRepo) NextConversation(ctx context.Context, uid, after string) (string, bool, error) {
	q := r.client.Collection(conversationsCollection).Where("participants", "array-contains", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(r.convRef(after))
	}
	docs, err := q.Select().Limit(1).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return "", false, logger.RedactErr(fmt.Errorf("messaging: list conversations to erase: %w", err), uid, after)
	}
	if len(docs) == 0 {
		return "", false, nil
	}
	return docs[0].Ref.ID, true, nil
}

// MarkGone is steps 1 and 3 of the eraser for one conversation, in one transaction (ADR-0027 D8): add uid to
// `gone` (so no send can rewrite the deleted user's entries afterwards: the send transaction reads that document) and
// rewrite the peer's entry (snapshot to the "Deleted account" placeholder; the snippet to "Message deleted" when the
// user's message was the last one). Reads 2 (the conversation, the peer's entry; 1 when the peer is gone already);
// writes 2 (1 when the peer's entry is gone). The peer's entry also gets changedAt, so a device that cached the inbox sees the
// rewritten row at its next since refresh (+0 writes). A repeat on a conversation already marked costs 1 read and 0 writes.
func (r *FirestoreRepo) MarkGone(ctx context.Context, uid, convID string) (goneResult, error) {
	var out goneResult
	attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			out = goneResult{}
			c := budget.FromContext(ctx)
			snap, err := tx.Get(r.convRef(convID))
			c.AddReads(1)
			if status.Code(err) == codes.NotFound {
				out.Missing = true
				return nil
			}
			if err != nil {
				return fmt.Errorf("messaging: read conversation: %w", err)
			}
			var conv ConvDoc
			if derr := snap.DataTo(&conv); derr != nil {
				return fmt.Errorf("messaging: decode conversation: %w", derr)
			}
			peer := peerOf(conv.Participants, uid)
			if peer == "" {
				out.Missing = true
				return nil
			}
			out.Both, out.Entry = conv.isGone(peer), entryFolder(conv, uid)

			// The peer's entry is rewritten in the very transaction that adds uid to `gone`, so a conversation already marked
			// has had it done: a repeated call neither re-reads nor re-writes it.
			var peerRef *firestore.DocumentRef
			var peerEntry EntryDoc
			if !out.Both && !conv.isGone(uid) {
				peerRef = r.entryRef(peer, convID, entryFolder(conv, peer))
				esnap, eerr := tx.Get(peerRef)
				c.AddReads(1)
				switch status.Code(eerr) {
				case codes.OK:
					if derr := esnap.DataTo(&peerEntry); derr != nil {
						return fmt.Errorf("messaging: decode entry: %w", derr)
					}
				case codes.NotFound:
					peerRef = nil // the peer deleted the conversation for themselves: nothing to rewrite
				default:
					return fmt.Errorf("messaging: read peer entry: %w", eerr)
				}
			}

			b := store.NewFirestoreTxBatch(tx, c)
			if !conv.isGone(uid) {
				b.Update(r.convRef(convID), []firestore.Update{{Path: "gone", Value: firestore.ArrayUnion(uid)}, {Path: "updatedAt", Value: wireTime(r.now())}})
			}
			if peerRef != nil {
				ups := []firestore.Update{{Path: "peer", Value: PeerDoc{DisplayName: DeletedAccountName}.fields()}, {Path: "peerId", Value: DeletedUID}, {Path: "changedAt", Value: wireTime(r.now())}, {Path: "requestPending", Value: firestore.Delete}} // requestPending (W7-25): a request whose recipient is gone is read-only, never "waiting" (+0). changedAt: the peer's next inbox since refresh returns the rewritten entry
				if !peerEntry.Last.FromSelf {
					ups = append(ups, firestore.Update{Path: "last.snippet", Value: deletedSnippet}, firestore.Update{Path: "last.state", Value: msgDeletedAccount})
				}
				b.Update(peerRef, ups)
			}
			return b.Err()
		})
	store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
	if err != nil {
		return goneResult{}, logger.RedactErr(fmt.Errorf("messaging: mark conversation gone: %w", err), uid, convID)
	}
	return out, nil
}

// TombstonePage is step 2: one page of at most 500 of uid's messages in the conversation after the cursor `after`
// ("" = from the start), in __name__ order (`senderId == uid`). Every one gets senderId = DeletedUID by a field-level
// Update, never a Set, and a VISIBLE one is also cleared (text and request digest emptied, state DELETED_ACCOUNT); a
// message a moderator took down keeps its REMOVED state, also against a takedown that commits during the page (each
// write carries the LastUpdateTime of the document as read: the page fails with FailedPrecondition and the step retries). A replaced message no longer matches `senderId == uid`, so a
// repeat costs nothing. It returns the last message id seen (the next cursor), how many were handled, and full=true when
// the page was full and more may follow. Reads: one per message (min 1); writes: one per message (the replacement is part
// of the tombstone write, no extra).
func (r *FirestoreRepo) TombstonePage(ctx context.Context, uid, convID, after string) (last string, tombstoned int, full bool, err error) {
	col := r.convRef(convID).Collection(messagesCollection)
	q := col.Where("senderId", "==", uid).OrderBy(firestore.DocumentID, firestore.Asc)
	if after != "" {
		q = q.StartAfter(col.Doc(after))
	}
	docs, err := q.Limit(lifecyclePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return "", 0, false, logger.RedactErr(fmt.Errorf("messaging: list messages to tombstone: %w", err), uid, convID, after)
	}
	if len(docs) == 0 {
		return after, 0, false, nil
	}
	r.hooks.tombstoneRead()
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		// Update fails on a missing document, so a message deleted meanwhile (the peer's eraser, both gone) is never recreated.
		ups := []firestore.Update{{Path: "senderId", Value: DeletedUID}}
		if st, _ := d.DataAt("state"); st == msgVisible {
			ups = append(ups, firestore.Update{Path: "text", Value: ""}, firestore.Update{Path: "requestHash", Value: ""}, firestore.Update{Path: "state", Value: msgDeletedAccount})
		}
		// LastUpdateTime: a moderator takedown that commits between this query and the batch changes the document, the
		// write fails with FailedPrecondition and the step's retry re-reads it as REMOVED, so a takedown is never
		// overwritten by DELETED_ACCOUNT.
		b.Update(d.Ref, ups, firestore.LastUpdateTime(d.UpdateTime))
		tombstoned++
	}
	if tombstoned > 0 {
		if cerr := b.Commit(ctx); cerr != nil {
			return "", 0, false, logger.RedactErr(fmt.Errorf("messaging: tombstone messages: %w", cerr), uid, convID)
		}
	}
	return docs[len(docs)-1].Ref.ID, tombstoned, len(docs) == lifecyclePage, nil
}

// RewriteConversation is the LAST step of one conversation whose peer lives: in one transaction it replaces uid by
// DeletedUID in participants, gone, requestFrom and requestTo and removes uid's clearedAt and clearedKey entries (the map key is
// the uid, so the placeholder rule is to drop it), so the surviving peer's
// copy names the deleted user nowhere (ADR-0027 D11). It must come last: the cursor query finds a conversation through
// `participants array-contains uid`, so once this commits the conversation is no longer listed for uid, and everything
// before it (gone mark, tombstones, entry) is already done. A missing conversation, or one without uid, is a no-op.
// Reads 1, writes 1. The same write increments `rev` (+0 writes), which retires every ListMessages since token the surviving
// peer's devices hold, so their cached thread cold-opens and shows the DELETED_ACCOUNT tombstones and the "Deleted account" header.
func (r *FirestoreRepo) RewriteConversation(ctx context.Context, uid, convID string) error {
	attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
		func(ctx context.Context, tx *firestore.Transaction) error {
			c := budget.FromContext(ctx)
			snap, err := tx.Get(r.convRef(convID))
			c.AddReads(1)
			if status.Code(err) == codes.NotFound {
				return nil
			}
			if err != nil {
				return fmt.Errorf("messaging: read conversation: %w", err)
			}
			var conv ConvDoc
			if derr := snap.DataTo(&conv); derr != nil {
				return fmt.Errorf("messaging: decode conversation: %w", derr)
			}
			if !conv.hasParticipant(uid) {
				return nil
			}
			swap := func(in []string) []string {
				out := make([]string, len(in))
				for i, v := range in {
					out[i] = v
					if v == uid {
						out[i] = DeletedUID
					}
				}
				return out
			}
			ups := []firestore.Update{
				{Path: "participants", Value: swap(conv.Participants)}, {Path: "gone", Value: swap(conv.Gone)},
				{Path: "updatedAt", Value: wireTime(r.now())}, {Path: "rev", Value: firestore.Increment(1)},
			}
			if conv.RequestFrom == uid {
				ups = append(ups, firestore.Update{Path: "requestFrom", Value: DeletedUID})
			}
			if conv.RequestTo == uid {
				ups = append(ups, firestore.Update{Path: "requestTo", Value: DeletedUID})
			}
			if _, ok := conv.ClearedAt[uid]; ok {
				ups = append(ups, firestore.Update{FieldPath: firestore.FieldPath{"clearedAt", uid}, Value: firestore.Delete})
			}
			if _, ok := conv.ClearedKey[uid]; ok {
				ups = append(ups, firestore.Update{FieldPath: firestore.FieldPath{"clearedKey", uid}, Value: firestore.Delete})
			}
			b := store.NewFirestoreTxBatch(tx, c)
			b.Update(r.convRef(convID), ups)
			return b.Err()
		})
	store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
	if err != nil {
		return logger.RedactErr(fmt.Errorf("messaging: rewrite conversation: %w", err), uid, convID)
	}
	return nil
}

// DeleteEntry is step 4 for one conversation: delete uid's own entry in the given folder. A delete of a missing
// document is a no-op. Writes: 1 delete.
func (r *FirestoreRepo) DeleteEntry(ctx context.Context, uid, convID, folder string) error {
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	b.Delete(r.entryRef(uid, convID, folder))
	if err := b.Commit(ctx); err != nil {
		return logger.RedactErr(fmt.Errorf("messaging: delete entry: %w", err), uid, convID)
	}
	return nil
}

// DeleteTreePage deletes up to 500 messages of the conversation and, once a page comes back short, the conversation
// document itself (last, so a crash leaves a conversation the cursor query still finds). Used when both participants
// are gone. done is true when the document was deleted. Reads: one per message (min 1); deletes: one per message, +1.
func (r *FirestoreRepo) DeleteTreePage(ctx context.Context, convID string) (deleted int, done bool, err error) {
	docs, err := r.convRef(convID).Collection(messagesCollection).Select().Limit(lifecyclePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return 0, false, logger.RedactErr(fmt.Errorf("messaging: list messages to delete: %w", err), convID)
	}
	b := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	for _, d := range docs {
		b.Delete(d.Ref)
	}
	if len(docs) > 0 {
		if cerr := b.Commit(ctx); cerr != nil {
			return 0, false, logger.RedactErr(fmt.Errorf("messaging: delete messages: %w", cerr), convID)
		}
	}
	if len(docs) == lifecyclePage {
		return len(docs), false, nil
	}
	cb := store.NewFirestoreBatch(r.client, budget.FromContext(ctx))
	cb.Delete(r.convRef(convID))
	if cerr := cb.Commit(ctx); cerr != nil {
		return len(docs), false, logger.RedactErr(fmt.Errorf("messaging: delete conversation: %w", cerr), convID)
	}
	return len(docs), true, nil
}

// ExportConv is one conversation of the account export (the data the section needs, no peer uid kept past the lookup).
type ExportConv struct {
	ID        string
	PeerUID   string
	State     string
	CreatedAt time.Time
	ClearedAt time.Time
	PeerGone  bool
}

// ExportMsg is one message of the account export.
type ExportMsg struct {
	ID        string
	FromSelf  bool
	Text      string
	State     string
	CreatedAt time.Time
}

// ExportConversations returns every conversation of uid, in pages of 500 by __name__ (`participants array-contains
// uid`). Reads: one per conversation (min 1).
func (r *FirestoreRepo) ExportConversations(ctx context.Context, uid string) ([]ExportConv, error) {
	var out []ExportConv
	after := ""
	for {
		q := r.client.Collection(conversationsCollection).Where("participants", "array-contains", uid).OrderBy(firestore.DocumentID, firestore.Asc)
		if after != "" {
			q = q.StartAfter(r.convRef(after))
		}
		docs, err := q.Limit(lifecyclePage).Documents(ctx).GetAll()
		budget.FromContext(ctx).AddQueryReads(len(docs))
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("messaging: export conversations: %w", err), uid, after)
		}
		for _, d := range docs {
			var c ConvDoc
			if derr := d.DataTo(&c); derr != nil {
				return nil, logger.RedactErr(fmt.Errorf("messaging: decode conversation %s: %w", d.Ref.ID, derr), uid, d.Ref.ID)
			}
			peer := peerOf(c.Participants, uid)
			out = append(out, ExportConv{
				ID: d.Ref.ID, PeerUID: peer, State: c.State, CreatedAt: c.CreatedAt.UTC(),
				ClearedAt: c.ClearedAt[uid].UTC(), PeerGone: c.isGone(peer),
			})
		}
		if len(docs) < lifecyclePage {
			return out, nil
		}
		after = docs[len(docs)-1].Ref.ID
	}
}

// ExportMessages returns one page (at most 500) of the conversation's messages strictly after the position (createdAt,
// id) `after` (nil = from the newest), newest first: `createdAt DESC, __name__ DESC`, the automatic single-field index.
// Both sides are read, to order the section. Reads: one per message (min 1).
func (r *FirestoreRepo) ExportMessages(ctx context.Context, uid, convID string, after *ExportMsg) ([]ExportMsg, error) {
	col := r.convRef(convID).Collection(messagesCollection)
	q := col.OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
	if after != nil {
		q = q.StartAfter(after.CreatedAt, col.Doc(after.ID))
	}
	docs, err := q.Limit(lifecyclePage).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("messaging: export messages: %w", err), uid, convID)
	}
	out := make([]ExportMsg, 0, len(docs))
	for _, d := range docs {
		var m MsgDoc
		if derr := d.DataTo(&m); derr != nil {
			return nil, logger.RedactErr(fmt.Errorf("messaging: decode message %s: %w", d.Ref.ID, derr), uid, convID, d.Ref.ID)
		}
		out = append(out, ExportMsg{ID: d.Ref.ID, FromSelf: m.SenderID == uid, Text: m.Text, State: m.State, CreatedAt: m.CreatedAt.UTC()})
	}
	return out, nil
}
