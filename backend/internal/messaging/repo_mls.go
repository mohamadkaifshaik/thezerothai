package messaging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// The MLS documents of a conversation: the commit records (conversations/{id}/commits) and the per-device welcomes
// (users/{uid}/dmWelcomes). Every writer that creates either (mls_init in the send transaction, CommitConversation's
// commit and reset in Repo.Commit) also writes the conversation document it read in the same transaction, so two writers
// for one conversation are serialised by Firestore and the "one welcome per (conversation, device)" lookup below cannot
// race another writer. Only deletions skip it: AckWelcomes (the caller's own welcomes by id) and the account eraser.

func (r *FirestoreRepo) commitRef(convID string, gen, epoch int64) *firestore.DocumentRef {
	return r.convRef(convID).Collection(commitsCollection).Doc(commitDocID(gen, epoch))
}

func (r *FirestoreRepo) welcomesCol(uid string) *firestore.CollectionRef {
	return r.client.Collection(usersCollection).Doc(uid).Collection(dmWelcomesCollection)
}

// earlierWelcomes reads, inside the transaction and before any write, the stored welcome of each target device for this
// conversation: users/{owner}/dmWelcomes where convId == convID and deviceId == target (two equality filters, served by
// the automatic single-field indexes, no composite; the precedent of identity's exports and posts' moderation queries),
// Limit 1, Select() (names only: the welcome bytes are not read). There is at most one by construction (the replacement
// below). One query per target, at most MaxWelcomeDevices. The result is aligned with targets; nil where none exists.
func (r *FirestoreRepo) earlierWelcomes(tx *firestore.Transaction, convID string, targets []welcomeTarget) ([]*firestore.DocumentRef, error) {
	out := make([]*firestore.DocumentRef, len(targets))
	for i, t := range targets {
		q := r.welcomesCol(t.Owner).Where("convId", "==", convID).Where("deviceId", "==", t.DeviceID).Select().Limit(1)
		docs, err := tx.Documents(q).GetAll()
		if err != nil {
			return nil, fmt.Errorf("messaging: read earlier welcome: %w", err)
		}
		if len(docs) > 0 {
			out[i] = docs[0].Ref
		}
	}
	return out, nil
}

// putWelcomes buffers one welcome document per target for the commit built on (gen, epoch), each carrying the same
// welcome bytes, and deletes the target's earlier welcome for this conversation (earlier, from earlierWelcomes) so at
// most one is kept per (conversation, device): the newest replaces. The new document is written with Set: when the
// earlier one has the very same id (the same conversation, pair and device: only possible when a conversation was
// deleted and recreated) it is overwritten instead of deleted and created in one commit. Writes: len(targets) sets and
// at most len(targets) deletes.
func (r *FirestoreRepo) putWelcomes(b store.Batch, convID string, gen, epoch int64, welcome []byte, targets []welcomeTarget, earlier []*firestore.DocumentRef, now time.Time) {
	for i, t := range targets {
		ref := r.welcomesCol(t.Owner).Doc(welcomeDocID(convID, gen, epoch, t.DeviceID))
		if old := earlier[i]; old != nil && old.Path != ref.Path {
			b.Delete(old)
		}
		b.Set(ref, WelcomeDoc{
			DeviceID: t.DeviceID, ConvID: convID, Gen: gen, Epoch: epoch, Data: welcome,
			CreatedAt: now, ExpireAt: now.Add(WelcomeRetention),
		})
	}
}

// initGen and initEpoch are the pair an mls_init commit is built on; the conversation then stands at (initGen, initEpoch+1).
const (
	initGen   int64 = 1
	initEpoch int64 = 0
)

// putInit buffers what an mls_init stores besides the message and the conversation's encryption fields: the commit
// record (initGen, initEpoch) and the welcomes for the (initGen, initEpoch) commit.
//
// The record is a Create when the transaction read none (initLeftover, zero leftover). An init only runs on a conversation
// that is missing or NONE (encGate), and encryption is one-way, so in this incarnation of the conversation no (1, 0) record
// can exist: one that does is left over from an earlier conversation with the same id, and a Create would fail on it
// forever (AlreadyExists, then "busy" on every retry). Such a leftover is overwritten under its LastUpdateTime
// (putCommitRecord). Tree deletion can no longer produce one (since E2EE plan 3 Task 8 the account eraser deletes the
// commit records with the conversation tree, DeleteTreePage); the handling stays as defence in depth. The first-wins
// guard of two racing inits is the conversation document both read and write (or both Create) in their transactions.
func (r *FirestoreRepo) putInit(b store.Batch, p SendParams, earlier []*firestore.DocumentRef, leftover time.Time, now time.Time) {
	in := p.Enc.Init
	r.putCommitRecord(b, r.commitRef(p.ConvID, initGen, initEpoch), CommitDoc{
		Data: in.Commit, SenderID: p.UID, Gen: initGen, Epoch: initEpoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention),
	}, leftover)
	r.putWelcomes(b, p.ConvID, initGen, initEpoch, in.Welcome, in.Targets, earlier, now)
}

// initLeftover reads, inside the send transaction of an mls_init and before any write, the (1, 0) record: it can only
// exist as a leftover of an earlier conversation with the same id (putInit), which tree deletion no longer leaves; the read
// is kept as defence in depth. It returns that record's update time, zero when there is none. 1 read.
func (r *FirestoreRepo) initLeftover(tx *firestore.Transaction, convID string) (time.Time, error) {
	_, updated, err := r.txCommitRecord(tx, convID, initGen, initEpoch)
	return updated, err
}

// commitStamp is the updatedAt a commit or a reset writes: now, but strictly after the updatedAt the transaction read
// (one microsecond, a Firestore timestamp's resolution, as the moderation takedown does). putConv keeps a cached copy
// unless the newcomer is not older, and breaks a tie by rev, which a commit never changes; so a stamp equal to the old one
// would let a late reader of the pre-commit document put the old pair back in the instance cache.
func commitStamp(now, convUpdated time.Time) time.Time {
	return notBefore(now, convUpdated.Add(time.Microsecond))
}

// startEncryption sets the encryption fields an mls_init gives a conversation: MLS at (initGen, initEpoch+1).
func startEncryption(c *ConvDoc) {
	c.Encryption, c.MlsGen, c.MlsEpoch = encMLS, initGen, initEpoch+1
}

// initUpdates are startEncryption as field updates of an existing conversation.
func initUpdates() []firestore.Update {
	return []firestore.Update{{Path: "encryption", Value: encMLS}, {Path: "mlsGen", Value: initGen}, {Path: "mlsEpoch", Value: initEpoch + 1}}
}

// newMsgDoc is the message a send stores (sendTx and the unit tests' fake): an encrypted one carries the ciphertext, the
// commitment, the pair, mlsKey and ctExpireAt; a plaintext one leaves them zero (omitted).
func newMsgDoc(p SendParams, now time.Time) MsgDoc {
	msg := MsgDoc{SenderID: p.UID, Text: p.Text, State: msgVisible, RequestHash: p.RequestHash, CreatedAt: now, SharedPostID: p.SharedPostID}
	if p.Enc != nil {
		msg.Ciphertext, msg.Commitment, msg.MlsGen, msg.MlsEpoch = p.Enc.Ciphertext, p.Enc.Commitment, p.Enc.Gen, p.Enc.Epoch
		msg.MlsKey, msg.CtExpireAt = mlsKey(p.Enc.Gen, p.Enc.Epoch), now.Add(CiphertextRetention)
	}
	return msg
}

// Commit implements Repo: CommitConversation, one transaction, in the proto's order of answers.
//
// Reads, all before any write: conversations/{id} (1; NOT_FOUND, VALIDATION conversation_id for NONE, CANNOT_MESSAGE for
// a gone peer), the peer's graph/{uid} (1, a block by the peer; the caller's own block comes from its cached snapshot), the
// commit record of the target pair (1; retry recognition), and, for an accepted commit with a welcome, the earlier welcome
// of each addressed device (at most MaxWelcomeDevices queries, Limit 1): at most 13. Between the record read and the pair
// check the service's field verdict is answered, then the welcome-device check runs against the key directory (at most 2
// queries of at most 5 devices, not transactional, after the conversation read that names the peer).
//
// Writes on acceptance: the conversation (mlsGen, mlsEpoch, updatedAt; never rev), the commit record, one welcome per
// device and the delete of each device's earlier welcome: at most 2 + 20. The record is a Create (first wins), except
// when the transaction read a record at a pair the conversation has not left: such a record cannot have been written in
// this incarnation of the conversation (the record and the move are one transaction), so it is a leftover of an earlier
// conversation with the same id and is overwritten under a LastUpdateTime precondition (putCommitRecord); tree deletion
// no longer leaves such records (DeleteTreePage deletes them), so this is defence in depth. The
// conversation's updatedAt is stamped strictly after the one it read (commitStamp). Every accepted commit writes the conversation document it read,
// so two commits on one pair, a commit and a reset, and a commit and an encrypted send (whose transaction reads the
// conversation too) are serialised by Firestore: the loser re-runs and answers from the winner's state.
func (r *FirestoreRepo) Commit(ctx context.Context, p CommitParams) (CommitResult, error) {
	// Two passes at most, as Send: an AlreadyExists of the record Create (a writer the transaction's read did not see)
	// re-runs the whole transaction once, which then reads that record.
	for pass := 0; pass < 2; pass++ {
		var res CommitResult
		attempts, err := store.RunTransactionRetry(ctx, r.txRunner(), store.TxnRetry{Timeout: txTimeout, MaxRuns: maxTxRuns, Backoff: txBackoff},
			func(ctx context.Context, tx *firestore.Transaction) error {
				var terr error
				res, terr = r.commitTx(ctx, tx, p)
				return terr
			})
		store.NoteTxnAttempts(ctx, "messaging_txn_contention", attempts)
		if status.Code(err) != codes.AlreadyExists {
			return res, err
		}
	}
	return CommitResult{}, fmt.Errorf("messaging: commit: %w", store.ErrContended)
}

// commitTx is one run of the commit transaction body.
func (r *FirestoreRepo) commitTx(ctx context.Context, tx *firestore.Transaction, p CommitParams) (CommitResult, error) {
	var res CommitResult
	conv, err := r.txConversation(ctx, tx, p.ConvID)
	if err != nil {
		return res, err
	}
	// Step 2: the conversation, then a block in either direction.
	peer, err := commitConvRefusal(conv, p.UID)
	if err != nil {
		return res, err
	}
	res.Conv = *conv
	if p.RecipientGraphInTx == nil || p.CallerBlocks == nil {
		return res, errors.New("messaging: commit has no graph readers")
	}
	theirs, err := p.RecipientGraphInTx(ctx, tx, peer)
	if err != nil {
		return res, fmt.Errorf("messaging: recipient graph: %w", err)
	}
	if theirs.Blocked[p.UID] {
		return res, errBlocked
	}
	blocks, err := p.CallerBlocks(ctx, peer)
	if err != nil {
		return res, fmt.Errorf("messaging: caller graph: %w", err)
	}
	if blocks {
		return res, errBlocked
	}

	// Step 3: retry recognition on the record this request would create.
	gen, epoch := commitRecordPair(p)
	rec, recUpdated, err := r.txCommitRecord(tx, p.ConvID, gen, epoch)
	if err != nil {
		return res, err
	}
	if isCommitRetry(*conv, rec, p.UID, p.Commit, gen, epoch) {
		res.Retry = true
		return res, nil
	}

	// Step 4: the remaining fields, then the welcome devices.
	if p.FieldErr != nil {
		return res, p.FieldErr
	}
	var targets []welcomeTarget
	if len(p.DeviceIDs) > 0 {
		if p.WelcomeTargets == nil {
			return res, errors.New("messaging: commit has no device directory")
		}
		if targets, err = p.WelcomeTargets(ctx, peer); err != nil {
			return res, err
		}
	}

	// Step 5: the pair.
	if err := commitPairStale(*conv, p); err != nil {
		return res, err
	}

	earlier, err := r.earlierWelcomes(tx, p.ConvID, targets)
	if err != nil {
		return res, err
	}
	now := wireTime(p.Now)
	nextGen, nextEpoch := commitNextPair(p)
	updatedAt := commitStamp(now, conv.UpdatedAt)
	b := store.NewFirestoreTxBatch(tx)
	b.Update(r.convRef(p.ConvID), []firestore.Update{
		{Path: "mlsGen", Value: nextGen}, {Path: "mlsEpoch", Value: nextEpoch}, {Path: "updatedAt", Value: updatedAt},
	})
	// A record read here is a leftover of an earlier conversation with this id (see Commit): overwritten under its update
	// time; none read: Create.
	doc := CommitDoc{Data: p.Commit, SenderID: p.UID, Gen: gen, Epoch: epoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention)}
	r.putCommitRecord(b, r.commitRef(p.ConvID, gen, epoch), doc, recUpdated)
	r.putWelcomes(b, p.ConvID, gen, epoch, p.Welcome, targets, earlier, now)
	if berr := b.Err(); berr != nil {
		return res, berr
	}
	res.Conv.MlsGen, res.Conv.MlsEpoch, res.Conv.UpdatedAt = nextGen, nextEpoch, updatedAt
	return res, nil
}

// ListCommits implements Repo: ONE read-only transaction (a consistent snapshot), so the conversation's current pair and
// the commit records come from the same instant and "no commit returned while the pair is ahead" is a real gap, never a
// race between two reads. Reads: the conversation (1; a missing one or a caller who is not one of its two participants is
// ErrNotFound and nothing else is read), then, for an MLS conversation only, conversations/{id}/commits ordered by
// document id (commitDocID sorts by generation, then epoch) StartAfter q.AfterID, Limit q.Limit: no field filter, so no
// index is involved. A NONE conversation is the snapshot with no rows.
func (r *FirestoreRepo) ListCommits(ctx context.Context, q CommitsQuery) (CommitsPage, error) {
	var page CommitsPage
	_, err := store.RunTransaction(ctx, r.client, func(ctx context.Context, tx *firestore.Transaction) error {
		page = CommitsPage{}
		conv, err := r.txConversation(ctx, tx, q.ConvID)
		if err != nil {
			return err
		}
		if conv == nil || peerOf(conv.Participants, q.UID) == "" {
			return ErrNotFound
		}
		page.Conv = *conv
		if !conv.encrypted() {
			return nil
		}
		col := r.convRef(q.ConvID).Collection(commitsCollection)
		query := col.OrderBy(firestore.DocumentID, firestore.Asc)
		if q.AfterID != "" {
			query = query.StartAfter(q.AfterID)
		}
		docs, err := tx.Documents(query.Limit(q.Limit)).GetAll()
		if err != nil {
			return fmt.Errorf("messaging: list commits: %w", err)
		}
		page.Rows = make([]CommitRow, 0, len(docs))
		for _, d := range docs {
			var c CommitDoc
			if err := d.DataTo(&c); err != nil {
				return fmt.Errorf("messaging: decode commit record: %w", err)
			}
			page.Rows = append(page.Rows, CommitRow{ID: d.Ref.ID, CommitDoc: c})
		}
		return nil
	}, firestore.ReadOnly)
	if err != nil {
		return CommitsPage{}, err
	}
	return page, nil
}

// ListEpochMessages implements Repo: conversations/{id}/messages where mlsKey == key ordered by document id (ascending),
// StartAfter afterID, Limit limit. One equality filter plus the implicit __name__ order is served by the automatic
// single-field index on mlsKey, no composite (the precedent of articles' and billing's `field == x` + document-id pages).
func (r *FirestoreRepo) ListEpochMessages(ctx context.Context, convID, key, afterID string, limit int) ([]MessageRow, error) {
	query := r.convRef(convID).Collection(messagesCollection).Where("mlsKey", "==", key).OrderBy(firestore.DocumentID, firestore.Asc)
	if afterID != "" {
		query = query.StartAfter(afterID)
	}
	docs, err := query.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("messaging: list epoch messages: %w", err)
	}
	return messageRows(docs)
}

// lowestMessageID sorts at or before every message document id (32 lower-case hex): StartAt(t, lowestMessageID) is "at
// time t, before every id". The Go client needs one cursor value per OrderBy, so a time-only position cannot be passed
// as StartAt(t) on a query ordered by createdAt then document id.
const lowestMessageID = "00000000000000000000000000000000"

// ListEpochMessagesByTime implements Repo: conversations/{id}/messages where mlsKey == key ordered by createdAt, then
// document id (both ascending), served by the composite index messages (mlsKey ASC, createdAt ASC) with its implicit
// __name__ ASC. A full position (after.DocID set) resumes StartAfter it; a time-only position (DocID "", CreatedAt set)
// StartAt that time before every id; a zero position reads from the start. Limit limit. A FAILED_PRECONDITION (the index
// is missing or not READY) is ErrOrderIndex (orderIndexErr).
func (r *FirestoreRepo) ListEpochMessagesByTime(ctx context.Context, convID, key string, after cursor.Cursor, limit int) ([]MessageRow, error) {
	query := r.convRef(convID).Collection(messagesCollection).Where("mlsKey", "==", key).OrderBy("createdAt", firestore.Asc).OrderBy(firestore.DocumentID, firestore.Asc)
	switch {
	case after.DocID != "":
		query = query.StartAfter(after.CreatedAt, after.DocID)
	case !after.CreatedAt.IsZero():
		query = query.StartAt(after.CreatedAt, lowestMessageID)
	}
	docs, err := query.Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, orderIndexErr(err)
	}
	return messageRows(docs)
}

// orderIndexErr wraps an error of the ordered epoch query with context: a FAILED_PRECONDITION (the composite index is
// missing or not READY) also wraps ErrOrderIndex, checked on the raw Firestore error before any wrapping.
func orderIndexErr(err error) error {
	if status.Code(err) == codes.FailedPrecondition {
		return fmt.Errorf("messaging: list epoch messages by time: %w: %w", ErrOrderIndex, err)
	}
	return fmt.Errorf("messaging: list epoch messages by time: %w", err)
}

// messageRows decodes a page of message documents.
func messageRows(docs []*firestore.DocumentSnapshot) ([]MessageRow, error) {
	out := make([]MessageRow, 0, len(docs))
	for _, d := range docs {
		var m MsgDoc
		if err := d.DataTo(&m); err != nil {
			return nil, fmt.Errorf("messaging: decode message: %w", err)
		}
		out = append(out, MessageRow{ID: d.Ref.ID, MsgDoc: m})
	}
	return out, nil
}

// ListTombstones implements Repo: two equality queries on conversations/{id}/messages, state == REMOVED and state ==
// DELETED_ACCOUNT, each ordered by document id after afterID, Select("state"), Limit limit (each served by the automatic
// single-field index on state plus __name__, no composite; an `in` query with a __name__ order is not used), merged by
// mergeTombstones. At most 2 * limit documents read.
func (r *FirestoreRepo) ListTombstones(ctx context.Context, convID, afterID string, limit int) ([]TombstoneRow, bool, error) {
	var lists [2][]TombstoneRow
	for i, st := range [2]string{msgRemoved, msgDeletedAccount} {
		query := r.convRef(convID).Collection(messagesCollection).Where("state", "==", st).OrderBy(firestore.DocumentID, firestore.Asc)
		if afterID != "" {
			query = query.StartAfter(afterID)
		}
		docs, err := query.Select("state").Limit(limit).Documents(ctx).GetAll()
		if err != nil {
			return nil, false, fmt.Errorf("messaging: list tombstones: %w", err)
		}
		for _, d := range docs {
			s, _ := d.Data()["state"].(string)
			lists[i] = append(lists[i], TombstoneRow{ID: d.Ref.ID, State: s})
		}
	}
	rows, more := mergeTombstones(lists[0], lists[1], limit)
	return rows, more, nil
}

// mergeTombstones merges the two per-state pages (each ascending by id, at most limit rows) into the first limit rows by
// id. more is true when either page was full (that state may have more) or the merge was cut: then every tombstone up to
// the last returned id has been read (a full page's last id is at or after the limit-th smallest of the union), so the
// next page starts after it without a skip; rows past the cut are read again then.
func mergeTombstones(a, b []TombstoneRow, limit int) ([]TombstoneRow, bool) {
	more := len(a) >= limit || len(b) >= limit
	out := make([]TombstoneRow, 0, min(len(a)+len(b), limit))
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		var next TombstoneRow
		switch {
		case j >= len(b) || (i < len(a) && a[i].ID < b[j].ID):
			next, i = a[i], i+1
		case i >= len(a) || b[j].ID < a[i].ID:
			next, j = b[j], j+1
		default: // the same id in both (not possible: one document has one state); keep one
			next, i, j = a[i], i+1, j+1
		}
		if len(out) == limit {
			return out, true
		}
		out = append(out, next)
	}
	return out, more
}

// ListWelcomes implements Repo: users/{uid}/dmWelcomes where deviceId == deviceID ordered by document id, Limit limit (the
// automatic single-field index on deviceId, no composite). The path comes from the caller's uid, so another user's
// welcomes are never in reach.
func (r *FirestoreRepo) ListWelcomes(ctx context.Context, uid, deviceID string, limit int) ([]WelcomeRow, error) {
	docs, err := r.welcomesCol(uid).Where("deviceId", "==", deviceID).OrderBy(firestore.DocumentID, firestore.Asc).Limit(limit).Documents(ctx).GetAll()
	if err != nil {
		return nil, fmt.Errorf("messaging: list welcomes: %w", err)
	}
	out := make([]WelcomeRow, 0, len(docs))
	for _, d := range docs {
		var w WelcomeDoc
		if err := d.DataTo(&w); err != nil {
			return nil, fmt.Errorf("messaging: decode welcome: %w", err)
		}
		out = append(out, WelcomeRow{ID: d.Ref.ID, WelcomeDoc: w})
	}
	return out, nil
}

// AckWelcomes implements Repo: one batch deleting users/{uid}/dmWelcomes/{id} for each id, no read. A delete without a
// precondition of a missing document (already acknowledged, replaced, expired, another user's id) is a no-op.
func (r *FirestoreRepo) AckWelcomes(ctx context.Context, uid string, ids []string) error {
	if len(ids) == 0 {
		return nil
	}
	b := store.NewFirestoreBatch(r.client)
	for _, id := range ids {
		b.Delete(r.welcomesCol(uid).Doc(id))
	}
	if err := b.Commit(ctx); err != nil {
		return fmt.Errorf("messaging: ack welcomes: %w", err)
	}
	return nil
}

// txCommitRecord reads conversations/{id}/commits/{gen_epoch} through the transaction; nil (and a zero time) when it does
// not exist. updated is the snapshot's update time, the precondition of a leftover's overwrite (putCommitRecord).
func (r *FirestoreRepo) txCommitRecord(tx *firestore.Transaction, convID string, gen, epoch int64) (rec *CommitDoc, updated time.Time, err error) {
	snap, err := tx.Get(r.commitRef(convID, gen, epoch))
	switch status.Code(err) {
	case codes.OK:
		var c CommitDoc
		if derr := snap.DataTo(&c); derr != nil {
			return nil, time.Time{}, fmt.Errorf("messaging: decode commit record: %w", derr)
		}
		return &c, snap.UpdateTime, nil
	case codes.NotFound:
		return nil, time.Time{}, nil
	default:
		return nil, time.Time{}, fmt.Errorf("messaging: read commit record: %w", err)
	}
}

// putCommitRecord buffers the commit record doc at ref: a Create (first wins) when the transaction read no record there
// (leftover is zero); otherwise the record it read is a leftover of an earlier conversation with this id (the callers'
// rule) and is overwritten field by field with an Update carrying a LastUpdateTime precondition equal to the update time
// the transaction read, so the write still fails if anything changed that record since (a record-level guard on top of
// the transaction's own read, at no extra read). The six fields are every field a record has, so nothing of the leftover
// survives.
func (r *FirestoreRepo) putCommitRecord(b store.Batch, ref *firestore.DocumentRef, doc CommitDoc, leftover time.Time) {
	if leftover.IsZero() {
		b.Create(ref, doc)
		return
	}
	b.Update(ref, []firestore.Update{
		{Path: "data", Value: doc.Data}, {Path: "senderId", Value: doc.SenderID}, {Path: "gen", Value: doc.Gen},
		{Path: "epoch", Value: doc.Epoch}, {Path: "createdAt", Value: doc.CreatedAt}, {Path: "expireAt", Value: doc.ExpireAt},
	}, firestore.LastUpdateTime(leftover))
}
