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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const (
	// txTimeout bounds one send transaction (all re-runs), like engagement's. maxTxRuns bounds the re-runs after the SDK's
	// own attempts lost the lock race (two senders opening one conversation, a burst on one conversation document while
	// it is a REQUEST).
	txTimeout = 5 * time.Second
	maxTxRuns = 4
	txBackoff = 20 * time.Millisecond
)

// FirestoreRepo implements Repo (and the eraser and exporter sources) on Firestore. Only messaging code builds the
// paths of the three collections.
type FirestoreRepo struct {
	client *firestore.Client
	quotas *quota.Store
	now    func() time.Time
}

var _ Repo = (*FirestoreRepo)(nil)

// NewFirestoreRepo builds the repo. quotas is needed by Send only (quotas/{uid}.dmNew).
func NewFirestoreRepo(client *firestore.Client, quotas *quota.Store) *FirestoreRepo {
	return &FirestoreRepo{client: client, quotas: quotas, now: time.Now}
}

func (r *FirestoreRepo) convRef(id string) *firestore.DocumentRef {
	return r.client.Collection(conversationsCollection).Doc(id)
}

func (r *FirestoreRepo) msgRef(convID, msgID string) *firestore.DocumentRef {
	return r.convRef(convID).Collection(messagesCollection).Doc(msgID)
}

func (r *FirestoreRepo) inboxRef(uid, convID string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(dmInboxCollection).Doc(convID)
}

func (r *FirestoreRepo) requestsRef(uid, convID string) *firestore.DocumentRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(dmRequestsCollection).Doc(convID)
}

// GetConversation implements Repo. Reads 1.
func (r *FirestoreRepo) GetConversation(ctx context.Context, id string) (ConvDoc, bool, error) {
	snap, err := r.convRef(id).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return ConvDoc{}, false, nil
	}
	if err != nil {
		return ConvDoc{}, false, fmt.Errorf("messaging: get conversation: %w", err)
	}
	var c ConvDoc
	if err := snap.DataTo(&c); err != nil {
		return ConvDoc{}, false, fmt.Errorf("messaging: decode conversation: %w", err)
	}
	return c, true, nil
}

// getMessage reads the stored message of a send (1 read); found is false when it is missing.
func (r *FirestoreRepo) getMessage(ctx context.Context, convID, msgID string) (MsgDoc, bool, error) {
	snap, err := r.msgRef(convID, msgID).Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if status.Code(err) == codes.NotFound {
		return MsgDoc{}, false, nil
	}
	if err != nil {
		return MsgDoc{}, false, fmt.Errorf("messaging: get message: %w", err)
	}
	var m MsgDoc
	if err := snap.DataTo(&m); err != nil {
		return MsgDoc{}, false, fmt.Errorf("messaging: decode message: %w", err)
	}
	return m, true, nil
}

// Send implements Repo: one transaction (ADR-0027 D4 step 5).
//
// Reads, fresh and before any write: conversations/{convId} (1). A missing conversation adds the recipient's account
// status without the cache (1, FreshRecipient) and quotas/{uid} (1): 3 in all. A send refused by the unanswered-request
// cap first reads the message document (1) because a replay of the last allowed message must replay, not refuse.
//
// Writes: the message (Create, deterministic id), the sender's dmInbox entry and the recipient's entry (field-level
// Set with MergeAll; unreadCount is a FieldValue.Increment unless the recipient muted the caller). Accepted
// conversation: 3 writes. An existing REQUEST: + the conversation (requestCount +1), 4. A new conversation: + the
// conversation Create and quotas.dmNew, 5. The reply that accepts a request: the conversation state update, 4 writes,
// plus 1 delete (the replier's dmRequests entry moves to dmInbox).
//
// A replay is AlreadyExists at commit on the message Create: the whole transaction rolls back (0 writes), the stored
// message is read (1 read) and returned, or ErrKeyReused when its request digest differs.
func (r *FirestoreRepo) Send(ctx context.Context, p SendParams) (SendResult, error) {
	if r.quotas == nil {
		return SendResult{}, errors.New("messaging: repo has no quota store configured")
	}
	// Two passes at most: the second only when AlreadyExists came from the conversation Create of a concurrent first
	// message instead of from the message (the SDK normally serialises that by aborting and re-running the body).
	for pass := 0; pass < 2; pass++ {
		var res SendResult
		attempts, err := store.RunTransactionRetry(ctx, r.client, store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
			func(ctx context.Context, tx *firestore.Transaction) error {
				var terr error
				res, terr = r.sendTx(ctx, tx, p)
				return terr
			})
		store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
		switch {
		case err == nil:
			return res, nil
		case status.Code(err) != codes.AlreadyExists:
			return SendResult{}, err
		}
		stored, found, gerr := r.getMessage(ctx, p.ConvID, p.MsgID)
		if gerr != nil {
			return SendResult{}, gerr
		}
		if !found {
			continue
		}
		if stored.RequestHash != p.RequestHash {
			return SendResult{}, ErrKeyReused
		}
		return SendResult{Replay: true, Msg: stored, Conv: res.Conv}, nil
	}
	return SendResult{}, fmt.Errorf("messaging: send: %w", store.ErrContended)
}

// sendTx is one run of the send transaction body. res.Conv carries the conversation as read (or created) even when the
// body fails, so the replay path can answer without another read.
func (r *FirestoreRepo) sendTx(ctx context.Context, tx *firestore.Transaction, p SendParams) (SendResult, error) {
	c := budget.FromContext(ctx)
	var conv *ConvDoc
	snap, err := tx.Get(r.convRef(p.ConvID))
	c.AddReads(1)
	switch status.Code(err) {
	case codes.OK:
		var d ConvDoc
		if derr := snap.DataTo(&d); derr != nil {
			return SendResult{}, fmt.Errorf("messaging: decode conversation: %w", derr)
		}
		conv = &d
	case codes.NotFound:
	default:
		return SendResult{}, fmt.Errorf("messaging: read conversation: %w", err)
	}

	dec, derr := decideSend(conv, p.UID, p.Mutual, p.MaxUnanswered)
	res := SendResult{}
	if conv != nil {
		res.Conv = *conv
	}
	if errors.Is(derr, ErrRequestLimit) {
		// The refused send may be the replay of the last allowed message of this key: answer it as a replay.
		return r.replayOrRefuse(ctx, tx, p, res, derr)
	}
	if derr != nil {
		return res, derr
	}

	var qrec quota.Record
	if dec.CreateConv {
		// A new conversation: the recipient's status fresh (the purge race, D8), then today's new-conversation quota.
		if p.FreshRecipient != nil {
			if ferr := p.FreshRecipient(ctx); ferr != nil {
				return res, ferr
			}
		}
		if qrec, err = r.quotas.Get(ctx, tx, p.UID); err != nil {
			return res, fmt.Errorf("messaging: quota lookup: %w", err)
		}
	}

	now := wireTime(p.Now)
	b := store.NewFirestoreTxBatch(tx, c)
	msg := MsgDoc{SenderID: p.UID, Text: p.Text, State: msgVisible, RequestHash: p.RequestHash, CreatedAt: now}
	b.Create(r.msgRef(p.ConvID, p.MsgID), msg)

	switch {
	case dec.CreateConv:
		doc := ConvDoc{
			Kind: kindDirect, Participants: sortedPair(p.UID, p.PeerUID), State: dec.State,
			CreatedAt: now, UpdatedAt: now,
		}
		if dec.State == stateRequest {
			doc.RequestFrom, doc.RequestTo, doc.RequestCount = p.UID, p.PeerUID, 1
		}
		b.Create(r.convRef(p.ConvID), doc)
		if qerr := quota.CheckAndReserve(b, r.quotas.Ref(p.UID), qrec, quota.DMNew, p.DMNewLimit); qerr != nil {
			return res, ErrDMNewDaily
		}
		res.Conv, res.Created = doc, true
	case dec.IncRequest:
		b.Update(r.convRef(p.ConvID), []firestore.Update{{Path: "requestCount", Value: firestore.Increment(1)}, {Path: "updatedAt", Value: now}})
		res.Conv.RequestCount++
	case dec.AcceptNow:
		b.Update(r.convRef(p.ConvID), []firestore.Update{{Path: "state", Value: stateAccepted}, {Path: "updatedAt", Value: now}})
		res.Conv.State, res.AcceptedByReply = stateAccepted, true
	}
	res.RecipientInRequests = dec.RecipientInRequests

	snippet := snippetOf(p.Text)
	// The sender's own entry: always dmInbox (the requester sees the conversation in the Inbox, as on X). unreadCount is
	// not touched; createdAt is set when this send created the conversation.
	own := map[string]any{
		"peerId": p.PeerUID, "peer": p.Peer.fields(), "lastMessageAt": now, "silent": p.CallerSilent,
		"last": LastDoc{MessageID: p.MsgID, FromSelf: true, Snippet: snippet, State: msgVisible}.fields(),
	}
	// The recipient's entry: dmRequests while the request is unaccepted, else dmInbox.
	other := map[string]any{
		"peerId": p.UID, "peer": p.Caller.fields(), "lastMessageAt": now, "silent": p.Silent,
		"last": LastDoc{MessageID: p.MsgID, FromSelf: false, Snippet: snippet, State: msgVisible}.fields(),
	}
	if !p.Silent {
		other["unreadCount"] = firestore.Increment(1)
	}
	if res.Created {
		own["createdAt"], other["createdAt"] = now, now
	}
	b.Set(r.inboxRef(p.UID, p.ConvID), own, firestore.MergeAll)
	otherRef := r.inboxRef(p.PeerUID, p.ConvID)
	if dec.RecipientInRequests {
		otherRef = r.requestsRef(p.PeerUID, p.ConvID)
	}
	b.Set(otherRef, other, firestore.MergeAll)
	if dec.AcceptNow {
		b.Delete(r.requestsRef(p.UID, p.ConvID))
	}
	if berr := b.Err(); berr != nil {
		return res, berr
	}
	res.Msg = msg
	return res, nil
}

// replayOrRefuse answers a send the unanswered-request cap would refuse: when the message of this key already exists
// with the same digest it is a replay (returned as a successful, write-free result), with another digest ErrKeyReused,
// otherwise the original refusal. 1 extra read, only on this path.
func (r *FirestoreRepo) replayOrRefuse(ctx context.Context, tx *firestore.Transaction, p SendParams, res SendResult, refusal error) (SendResult, error) {
	snap, err := tx.Get(r.msgRef(p.ConvID, p.MsgID))
	budget.FromContext(ctx).AddReads(1)
	switch status.Code(err) {
	case codes.OK:
		var stored MsgDoc
		if derr := snap.DataTo(&stored); derr != nil {
			return res, fmt.Errorf("messaging: decode message: %w", derr)
		}
		if stored.RequestHash != p.RequestHash {
			return res, ErrKeyReused
		}
		res.Replay, res.Msg = true, stored
		return res, nil
	case codes.NotFound:
		return res, refusal
	default:
		return res, fmt.Errorf("messaging: read message: %w", err)
	}
}

func sortedPair(a, b string) []string {
	if b < a {
		a, b = b, a
	}
	return []string{a, b}
}

// requestCountCap bounds CountRequests (CLAUDE.md rule 5: every query has a Limit, aggregations included). Firestore bills
// a count() as 1 read per 1,000 matches, so the cap keeps "Message requests (N)" at 1 read; the client shows "999+".
const requestCountCap = 1000

// ListEntries implements Repo: `users/{uid}/{folder}` ordered `lastMessageAt DESC, __name__ DESC` (automatic single-field
// index, no composite), Limit q.Limit. Reads one per document returned, minimum 1 (an empty query bills 1). folder is
// dmInboxCollection or dmRequestsCollection: the caller picks it from an enum, never from request text.
func (r *FirestoreRepo) ListEntries(ctx context.Context, uid, folder string, q ListQuery) ([]EntryRow, error) {
	col := r.client.Collection(usersCollection).Doc(uid).Collection(folder)
	query := col.OrderBy("lastMessageAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc)
	if q.Before != nil {
		query = query.StartAfter(q.Before.CreatedAt, col.Doc(q.Before.DocID))
	}
	if q.After != nil {
		query = query.EndBefore(q.After.CreatedAt, col.Doc(q.After.DocID))
	}
	docs, err := query.Limit(q.Limit).Documents(ctx).GetAll()
	budget.FromContext(ctx).AddQueryReads(len(docs))
	if err != nil {
		return nil, fmt.Errorf("messaging: list %s: %w", folder, err)
	}
	out := make([]EntryRow, 0, len(docs))
	for _, d := range docs {
		var e EntryDoc
		if err := d.DataTo(&e); err != nil {
			return nil, fmt.Errorf("messaging: decode entry: %w", err)
		}
		out = append(out, EntryRow{ID: d.Ref.ID, EntryDoc: e})
	}
	return out, nil
}

// CountRequests implements Repo: count() on users/{uid}/dmRequests, Limit requestCountCap. 1 read.
func (r *FirestoreRepo) CountRequests(ctx context.Context, uid string) (int64, error) {
	q := r.client.Collection(usersCollection).Doc(uid).Collection(dmRequestsCollection).Limit(requestCountCap)
	res, err := q.NewAggregationQuery().WithCount("count").Get(ctx)
	budget.FromContext(ctx).AddReads(1)
	if err != nil {
		return 0, fmt.Errorf("messaging: count requests: %w", err)
	}
	var out struct {
		Count int64 `firestore:"count"`
	}
	if err := res.DataTo(&out); err != nil {
		return 0, fmt.Errorf("messaging: decode request count: %w", err)
	}
	return out.Count, nil
}
