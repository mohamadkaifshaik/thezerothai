package messaging

import (
	"fmt"
	"time"

	"cloud.google.com/go/firestore"

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
// record (initGen, initEpoch) with Create (first wins; an existing record fails the commit) and the welcomes for the
// (initGen, initEpoch) commit.
func (r *FirestoreRepo) putInit(b store.Batch, p SendParams, earlier []*firestore.DocumentRef, now time.Time) {
	in := p.Enc.Init
	b.Create(r.commitRef(p.ConvID, initGen, initEpoch), CommitDoc{
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
