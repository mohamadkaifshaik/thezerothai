package messaging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// The MLS documents of a conversation: the commit records (conversations/{id}/commits) and the per-device welcomes
// (users/{uid}/dmWelcomes). Every writer of either (mls_init in the send transaction; later a commit and a reset) also
// writes the conversation document it read in the same transaction, so two writers for one conversation are serialised
// by Firestore and the "one welcome per (conversation, device)" lookup below cannot race another writer.

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
// The record is written with Set, not Create. An init only runs on a conversation that is missing or NONE (encGate), and
// encryption is one-way, so in this incarnation of the conversation no (1, 0) record can exist: one that does is left over
// from an earlier conversation with the same id (both participants erased, the tree deleted without its commits, the pair
// meeting again), and a Create would fail on it forever (AlreadyExists, then "busy" on every retry). The first-wins guard
// of two racing inits is the conversation document both read and write (or both Create) in their transactions.
func (r *FirestoreRepo) putInit(b store.Batch, p SendParams, earlier []*firestore.DocumentRef, now time.Time) {
	in := p.Enc.Init
	b.Set(r.commitRef(p.ConvID, initGen, initEpoch), CommitDoc{
		Data: in.Commit, SenderID: p.UID, Gen: initGen, Epoch: initEpoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention),
	})
	r.putWelcomes(b, p.ConvID, initGen, initEpoch, in.Welcome, in.Targets, earlier, now)
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
// conversation with the same id and is replaced with Set. Every accepted commit writes the conversation document it read,
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
	rec, err := r.txCommitRecord(tx, p.ConvID, gen, epoch)
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
	updatedAt := notBefore(now, conv.UpdatedAt) // only moves forward (putConv)
	b := store.NewFirestoreTxBatch(tx)
	b.Update(r.convRef(p.ConvID), []firestore.Update{
		{Path: "mlsGen", Value: nextGen}, {Path: "mlsEpoch", Value: nextEpoch}, {Path: "updatedAt", Value: updatedAt},
	})
	doc := CommitDoc{Data: p.Commit, SenderID: p.UID, Gen: gen, Epoch: epoch, CreatedAt: now, ExpireAt: now.Add(CommitRetention)}
	if rec != nil {
		b.Set(r.commitRef(p.ConvID, gen, epoch), doc) // a leftover of an earlier conversation with this id (see Commit)
	} else {
		b.Create(r.commitRef(p.ConvID, gen, epoch), doc)
	}
	r.putWelcomes(b, p.ConvID, gen, epoch, p.Welcome, targets, earlier, now)
	if berr := b.Err(); berr != nil {
		return res, berr
	}
	res.Conv.MlsGen, res.Conv.MlsEpoch, res.Conv.UpdatedAt = nextGen, nextEpoch, updatedAt
	return res, nil
}

// txCommitRecord reads conversations/{id}/commits/{gen_epoch} through the transaction; nil when it does not exist.
func (r *FirestoreRepo) txCommitRecord(tx *firestore.Transaction, convID string, gen, epoch int64) (*CommitDoc, error) {
	snap, err := tx.Get(r.commitRef(convID, gen, epoch))
	switch status.Code(err) {
	case codes.OK:
		var c CommitDoc
		if derr := snap.DataTo(&c); derr != nil {
			return nil, fmt.Errorf("messaging: decode commit record: %w", derr)
		}
		return &c, nil
	case codes.NotFound:
		return nil, nil
	default:
		return nil, fmt.Errorf("messaging: read commit record: %w", err)
	}
}
