//go:build integration

package messaging

// Encrypted sends into an existing MLS conversation (Task 3) on the emulator: what is stored, what a refusal leaves
// untouched, the replay rule across an epoch change, and the epoch check under real concurrency. mls_init does not exist
// yet (Task 4), so a test makes a conversation MLS by writing its encryption fields directly (makeConvMLSForTest).

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// makeConvMLSForTest stands in for mls_init (Task 4): it writes encryption = MLS and the pair (gen, epoch) on an existing
// conversation document, and is also how a test "commits" (moves the pair) before CommitConversation exists. It returns
// the write's commit time.
func (e *itEnv) makeConvMLSForTest(convID string, gen, epoch int64) time.Time {
	e.t.Helper()
	wr, err := e.fs.Collection("conversations").Doc(convID).Update(context.Background(), []firestore.Update{
		{Path: "encryption", Value: encMLS}, {Path: "mlsGen", Value: gen}, {Path: "mlsEpoch", Value: epoch},
	})
	if err != nil {
		e.t.Fatal(err)
	}
	return wr.UpdateTime
}

// startMLSConversation opens the alice-bob conversation with one plaintext message (mutual follows, so ACCEPTED) and
// makes it MLS at (gen, epoch). It returns the conversation id and the plaintext message's id.
func (e *itEnv) startMLSConversation(gen, epoch int64) (convID, plainID string) {
	e.t.Helper()
	e.mutual(alice, bob)
	resp := e.must(alice, toUser(skey(900), bob, "before encryption"))
	convID = resp.GetConversation().GetId()
	e.makeConvMLSForTest(convID, gen, epoch)
	e.tick(time.Second)
	return convID, resp.GetMessage().GetId()
}

// docSnap reads one document by path (relative to the database root).
func (e *itEnv) docSnap(path string) *firestore.DocumentSnapshot {
	e.t.Helper()
	snap, err := e.fs.Doc(path).Get(context.Background())
	if err != nil {
		e.t.Fatalf("read %s: %v", path, err)
	}
	return snap
}

// untouched records the update times of the conversation, both entries and the number of messages, and checks later that
// none of them changed (a refusal writes nothing).
type untouched struct {
	e     *itEnv
	conv  string
	times map[string]time.Time
	msgs  int
}

func (e *itEnv) snapshotState(convID string) untouched {
	e.t.Helper()
	u := untouched{e: e, conv: convID, times: map[string]time.Time{}, msgs: len(e.msgs(convID))}
	for _, p := range []string{"conversations/" + convID, "users/" + alice + "/dmInbox/" + convID, "users/" + bob + "/dmInbox/" + convID} {
		u.times[p] = e.docSnap(p).UpdateTime
	}
	return u
}

func (u untouched) check(t *testing.T) {
	t.Helper()
	for p, at := range u.times {
		if got := u.e.docSnap(p).UpdateTime; !got.Equal(at) {
			t.Errorf("%s was written (update time %v -> %v)", shortPath(p), at, got)
		}
	}
	if n := len(u.e.msgs(u.conv)); n != u.msgs {
		t.Errorf("messages = %d, want %d (nothing stored)", n, u.msgs)
	}
}

var itCommitment = bytes.Repeat([]byte{0xAB}, CommitmentBytes)

func encByConv(key, convID string, gen, epoch uint64, ct string) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID},
		Ciphertext: []byte(ct), ReportCommitment: itCommitment, MlsGeneration: gen, MlsEpoch: epoch,
	}
}

// encFields are the message fields only an encrypted message may carry.
var encFields = []string{"ciphertext", "commitment", "mlsGen", "mlsEpoch", "mlsKey", "ctExpireAt", "ctRemoved"}

// An encrypted send stores exactly the encrypted fields, an empty encrypted preview on both entries, counts as unread and
// pushes as usual, and does not write the conversation document. The plaintext message sent before has none of the
// encrypted fields at all, and its preview said encrypted = false.
func TestSendEnc_StoresAndReadsBackExactFields(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	first := e.must(alice, toUser(skey(1), bob, "plain first"))
	convID := first.GetConversation().GetId()
	plain := e.docSnap("conversations/" + convID + "/messages/" + first.GetMessage().GetId()).Data()
	for _, f := range encFields {
		if _, ok := plain[f]; ok {
			t.Errorf("plaintext message carries %q", f)
		}
	}
	if _, ok := plain["sharedPostId"]; ok {
		t.Error("plaintext message without a post carries sharedPostId")
	}
	if last, _ := e.entry(bob, dmInboxCollection, convID); last.Last.Encrypted || last.Last.Snippet != "plain first" {
		t.Errorf("plaintext preview = %+v", last.Last)
	}
	rawLast := e.docSnap("users/" + bob + "/dmInbox/" + convID).Data()["last"].(map[string]any)
	if v, ok := rawLast["encrypted"]; !ok || v != false {
		t.Errorf("plaintext entry last.encrypted = %v (present %v), want false written", v, ok)
	}

	e.makeConvMLSForTest(convID, 2, 4)
	convBefore := e.docSnap("conversations/" + convID).UpdateTime
	e.tick(time.Second)
	resp := e.must(alice, encByConv(skey(2), convID, 2, 4, "sealed bytes"))

	msgID := resp.GetMessage().GetId()
	snap := e.docSnap("conversations/" + convID + "/messages/" + msgID)
	raw := snap.Data()
	var m MsgDoc
	if err := snap.DataTo(&m); err != nil {
		t.Fatal(err)
	}
	if m.Text != "" || string(m.Ciphertext) != "sealed bytes" || !bytes.Equal(m.Commitment, itCommitment) || m.MlsGen != 2 || m.MlsEpoch != 4 ||
		m.MlsKey != "2:4" || m.CtRemoved || m.SharedPostID != "" || m.State != msgVisible || m.SenderID != alice {
		t.Errorf("stored message = %+v", m)
	}
	if want := m.CreatedAt.Add(CiphertextRetention); !m.CtExpireAt.Equal(want) {
		t.Errorf("ctExpireAt = %v, want createdAt + 30 days = %v", m.CtExpireAt, want)
	}
	if want := encRequestHash(convID, 2, 4, []byte("sealed bytes"), itCommitment); m.RequestHash != want {
		t.Errorf("requestHash = %q, want %q", m.RequestHash, want)
	}
	for _, f := range []string{"sharedPostId", "ctRemoved", "removedAt"} {
		if _, ok := raw[f]; ok {
			t.Errorf("encrypted message carries %q", f)
		}
	}
	for _, uid := range []string{alice, bob} {
		ent, _ := e.entry(uid, dmInboxCollection, convID)
		if ent.Last.Snippet != "" || !ent.Last.Encrypted || ent.Last.SharedPost || ent.Last.MessageID != msgID {
			t.Errorf("%s preview = %+v, want empty and encrypted", uid, ent.Last)
		}
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 2 {
		t.Errorf("bob unread = %d, want 2", ent.UnreadCount)
	}
	if n := len(e.events.got); n != 2 {
		t.Errorf("events = %d, want 2 (one per accepted message)", n)
	}
	if after := e.docSnap("conversations/" + convID).UpdateTime; !after.Equal(convBefore) {
		t.Errorf("an ordinary encrypted send wrote the conversation (update time %v -> %v)", convBefore, after)
	}
	if c := resp.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 2 || c.GetMlsEpoch() != 4 {
		t.Errorf("answered conversation = %v (%d, %d)", c.GetEncryption(), c.GetMlsGeneration(), c.GetMlsEpoch())
	}
	if rm := resp.GetMessage(); string(rm.GetCiphertext()) != "sealed bytes" || !bytes.Equal(rm.GetReportCommitment(), itCommitment) || rm.GetMlsGeneration() != 2 || rm.GetMlsEpoch() != 4 {
		t.Errorf("answered message = %v", rm)
	}
}

// A plaintext send into an MLS conversation is ENCRYPTION_REQUIRED and writes nothing: no message, both entries and the
// unread count untouched, the conversation untouched. Addressed by recipient it names the conversation.
func TestSendEnc_PlaintextIntoMLSWritesNothing(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 1)
	before := e.snapshotState(convID)
	events := len(e.events.got)

	_, err := e.send(alice, toUser(skey(10), bob, "plaintext again"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID})
	_, err = e.send(bob, toConv(skey(11), convID, "plaintext reply"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, nil)
	if _, _, meta := reasonOf(t, err); meta["conversation_id"] != "" {
		t.Errorf("a send by conversation id got metadata conversation_id")
	}
	before.check(t)
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 1 {
		t.Errorf("bob unread = %d, want 1 (unchanged)", ent.UnreadCount)
	}
	if len(e.events.got) != events {
		t.Error("a refused send pushed")
	}
}

// An encrypted send on another pair is STALE_EPOCH with the current pair and writes nothing; the key is not consumed, so
// a NEW key on the current pair is then accepted.
func TestSendEnc_StaleEpochWritesNothing(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(3, 9)
	before := e.snapshotState(convID)
	for _, pair := range [][2]uint64{{3, 8}, {3, 10}, {2, 9}} {
		_, err := e.send(alice, encByConv(skey(20), convID, pair[0], pair[1], "ct"))
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "3", "epoch": "9"})
	}
	req := encByConv(skey(21), convID, 3, 8, "ct")
	req.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: bob}
	_, err := e.send(alice, req)
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "3", "epoch": "9", "conversation_id": convID})
	before.check(t)
	if _, err := e.send(alice, encByConv(skey(20), convID, 3, 9, "re-encrypted")); err != nil {
		t.Fatalf("the key refused with STALE_EPOCH was consumed: %v", err)
	}
}

// Encrypted without mls_init into a plaintext conversation, or opening a new one: VALIDATION ciphertext, writing nothing.
// With the new-conversation quota spent, the existing LIMIT_REACHED dm_new_daily answers first.
func TestSendEnc_IntoPlaintextOrNewIsValidation(t *testing.T) {
	t.Run("new conversation", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		req := encByConv(skey(30), ConversationID(alice, bob), 1, 1, "ct")
		req.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: bob}
		_, err := e.send(alice, req)
		wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "ciphertext"})
		if docs := e.treeDocs(ConversationID(alice, bob)); len(docs) != 0 {
			t.Errorf("documents written: %v", docs)
		}
		if _, ok := e.entry(alice, dmInboxCollection, ConversationID(alice, bob)); ok {
			t.Error("an entry was written")
		}
		if n := e.dmNew(alice); n != 0 {
			t.Errorf("dmNew = %d, want 0", n)
		}
	})
	t.Run("quota spent answers first", func(t *testing.T) {
		e := newIT(t, func(e *itEnv) { e.limits.DMNewPerDay = 0 })
		e.mutual(alice, bob)
		req := encByConv(skey(31), ConversationID(alice, bob), 1, 1, "ct")
		req.Target = &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: bob}
		_, err := e.send(alice, req)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "dm_new_daily"})
	})
	t.Run("existing plaintext conversation", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		convID := e.must(alice, toUser(skey(32), bob, "plain")).GetConversation().GetId()
		before := e.snapshotState(convID)
		_, err := e.send(alice, encByConv(skey(33), convID, 1, 1, "ct"))
		wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "ciphertext"})
		before.check(t)
	})
}

// A replay wins over STALE_EPOCH and ENCRYPTION_REQUIRED: the identical request after the epoch advanced returns the
// stored message and writes nothing (no unread increment, no push); the same key with other bytes, another commitment or
// another pair is VALIDATION idempotency_key. A plaintext message sent before the conversation became encrypted replays
// too.
func TestSendEnc_ReplayAfterTheEpochAdvanced(t *testing.T) {
	e := newIT(t, nil)
	convID, plainID := e.startMLSConversation(1, 1)
	first := e.must(alice, encByConv(skey(40), convID, 1, 1, "sealed"))
	e.makeConvMLSForTest(convID, 1, 2)
	e.tick(time.Minute)
	before := e.snapshotState(convID)
	events := len(e.events.got)

	again, err := e.send(alice, encByConv(skey(40), convID, 1, 1, "sealed"))
	if err != nil {
		t.Fatalf("identical retry after the epoch advanced: %v", err)
	}
	if again.GetMessage().GetId() != first.GetMessage().GetId() || !again.GetMessage().GetCreatedAt().AsTime().Equal(first.GetMessage().GetCreatedAt().AsTime()) ||
		string(again.GetMessage().GetCiphertext()) != "sealed" || again.GetMessage().GetMlsEpoch() != 1 {
		t.Errorf("replay answered %v, want the stored message %v", again.GetMessage(), first.GetMessage())
	}
	if again.GetConversation().GetMlsEpoch() != 2 {
		t.Errorf("replay conversation epoch = %d, want the current 2", again.GetConversation().GetMlsEpoch())
	}
	// The plaintext message sent before encryption started replays too (a replay wins over ENCRYPTION_REQUIRED).
	if p, err := e.send(alice, toUser(skey(900), bob, "before encryption")); err != nil || p.GetMessage().GetId() != plainID {
		t.Errorf("plaintext replay into the MLS conversation = %v, %v", p.GetMessage().GetId(), err)
	}

	otherCommit := encByConv(skey(40), convID, 1, 1, "sealed")
	otherCommit.ReportCommitment = bytes.Repeat([]byte{0x01}, CommitmentBytes)
	for name, req := range map[string]*messagingv1.SendMessageRequest{
		"other ciphertext":    encByConv(skey(40), convID, 1, 1, "unsealed"),
		"other commitment":    otherCommit,
		"other pair":          encByConv(skey(40), convID, 1, 2, "sealed"),
		"plaintext, same key": toConv(skey(40), convID, "hi"),
	} {
		_, err := e.send(alice, req)
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if code, reason, meta := reasonOf(t, err); code != connect.CodeInvalidArgument || reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || meta["field"] != "idempotency_key" {
			t.Errorf("%s: %v %v %v, want VALIDATION idempotency_key", name, code, reason, meta)
		}
	}
	before.check(t)
	if len(e.events.got) != events {
		t.Errorf("replays pushed %d events", len(e.events.got)-events)
	}
	// Same epoch, identical retry: the commit-time AlreadyExists replay, unchanged for encrypted messages.
	second := e.must(alice, encByConv(skey(41), convID, 1, 2, "next"))
	if r := e.must(alice, encByConv(skey(41), convID, 1, 2, "next")); r.GetMessage().GetId() != second.GetMessage().GetId() {
		t.Errorf("same-epoch replay answered another message")
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != 3 {
		t.Errorf("bob unread = %d, want 3 (plain, sealed, next)", ent.UnreadCount)
	}
}

// N concurrent encrypted sends on the current pair, each on its own instance, all land (a busy racer is retried with its
// key, as a client does): N messages, N unread increments, and the conversation document is never written.
func TestSendEnc_ConcurrentSendsOnTheCurrentEpoch(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 5)
	convBefore := e.docSnap("conversations/" + convID).UpdateTime
	const racers = 8
	reqs := make([]*messagingv1.SendMessageRequest, racers)
	for i := range reqs {
		reqs[i] = encByConv(skey(500+i), convID, 1, 5, fmt.Sprintf("sealed %d", i))
	}
	_, errs := e.raceSends(alice, reqs)
	for i, err := range errs {
		switch outcome(err) {
		case "ok":
		case "busy":
			if _, rerr := e.send(alice, reqs[i]); rerr != nil {
				t.Errorf("racer %d same-key retry: %v", i, rerr)
			}
		default:
			t.Errorf("racer %d: %v", i, err)
		}
	}
	msgs := e.msgs(convID)
	enc := 0
	for _, m := range msgs {
		if m.MlsGen == 1 && m.MlsEpoch == 5 {
			enc++
		}
	}
	if enc != racers {
		t.Errorf("encrypted messages = %d, want %d", enc, racers)
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.UnreadCount != racers+1 {
		t.Errorf("bob unread = %d, want %d (a lost or doubled increment)", ent.UnreadCount, racers+1)
	}
	if after := e.docSnap("conversations/" + convID).UpdateTime; !after.Equal(convBefore) {
		t.Error("concurrent encrypted sends wrote the conversation document")
	}
}

// signalTxSocial is the real in-transaction graph reader that first calls fire: the send transaction calls it right after
// it read the conversation, so a test can start a competing write at that exact point without sleeping.
type signalTxSocial struct {
	graph.TxReader
	fire func()
}

func (s signalTxSocial) SnapshotInTx(ctx context.Context, tx *firestore.Transaction, uid string) (graph.Snapshot, error) {
	s.fire()
	return s.TxReader.SnapshotInTx(ctx, tx, uid)
}

// A send racing a direct move of the conversation's epoch (what a commit does) either commits in the old epoch BEFORE the
// move, or answers STALE_EPOCH with the new pair and stores nothing: never a message stored in an epoch that was no longer
// current when it committed. This holds because sendTx reads the conversation inside the transaction, so the move
// conflicts with it. Real goroutines, several rounds: on even rounds both are released together (the move usually wins:
// the send does its profile reads first); on odd rounds the move is released from inside the send transaction, after
// its conversation read and before its commit, the window the in-transaction read must protect.
func TestSendEnc_SendRacingAnEpochMove(t *testing.T) {
	e := newIT(t, nil)
	convID, _ := e.startMLSConversation(1, 1)
	ctx := context.Background()
	var inTx atomic.Pointer[func()]
	noop := func() {}
	inTx.Store(&noop)
	base := e.txSocial
	e.txSocial = signalTxSocial{TxReader: base, fire: func() { (*inTx.Load())() }}
	svc := e.newService()
	e.txSocial = base
	tally := map[string]int{}
	for round := range 8 {
		epoch := int64(1 + round)
		req := encByConv(skey(600+round), convID, 1, uint64(epoch), fmt.Sprintf("round %d", round))
		var (
			wg      sync.WaitGroup
			sendErr error
			moveAt  time.Time
			moveErr error
		)
		start, moveGo := make(chan struct{}), make(chan struct{})
		var once sync.Once
		release := func() { once.Do(func() { close(moveGo) }) }
		if round%2 == 1 {
			inTx.Store(&release)
		} else {
			inTx.Store(&noop)
		}
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, sendErr = e.sendOn(svc, alice, req)
			release() // the send ended without reaching its transaction body: let the move run anyway
		}()
		go func() {
			defer wg.Done()
			<-moveGo
			wr, err := e.fs.Collection("conversations").Doc(convID).Update(ctx, []firestore.Update{{Path: "mlsEpoch", Value: epoch + 1}})
			if err == nil {
				moveAt = wr.UpdateTime
			}
			moveErr = err
		}()
		if round%2 == 0 {
			release()
		}
		close(start)
		wg.Wait()
		if moveErr != nil {
			t.Fatalf("round %d: epoch move: %v", round, moveErr)
		}
		// A busy racer may or may not have committed: the same-key retry tells (a replay of a committed message, or
		// STALE_EPOCH now that the epoch moved).
		if outcome(sendErr) == "busy" {
			_, sendErr = e.sendOn(svc, alice, req)
		}
		msgPath := "conversations/" + convID + "/messages/" + MessageID(alice, req.GetIdempotencyKey())
		snap, gerr := e.fs.Doc(msgPath).Get(ctx)
		stored := gerr == nil && snap.Exists()
		if sendErr == nil {
			tally["ok"]++
			if !stored {
				t.Fatalf("round %d: ok but no message stored", round)
			}
			var m MsgDoc
			if err := snap.DataTo(&m); err != nil {
				t.Fatal(err)
			}
			if m.MlsEpoch != epoch {
				t.Errorf("round %d: stored epoch %d, want %d", round, m.MlsEpoch, epoch)
			}
			if !snap.CreateTime.Before(moveAt) {
				t.Errorf("round %d: message committed at %v, not before the epoch move at %v", round, snap.CreateTime, moveAt)
			}
		} else {
			tally["stale"]++
			wantAPI(t, sendErr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH,
				map[string]string{"generation": "1", "epoch": fmt.Sprint(epoch + 1)})
			if stored {
				t.Errorf("round %d: STALE_EPOCH but a message was stored", round)
			}
		}
	}
	t.Logf("outcomes: %v", tally)
}
