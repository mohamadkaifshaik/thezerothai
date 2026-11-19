//go:build integration

package messaging

// Takedown, the account eraser and the export on end-to-end encrypted conversations (E2EE plan 3 Task 8), on the
// emulator: tombstones lose ciphertext, commitment and ctExpireAt and keep their pair and mlsKey; the deleted user's
// commit records name DeletedUID; the user's welcomes go; both participants gone removes the commit records with the
// tree; the pages hold at most 500 documents.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// e2eeHistory builds an encrypted alice-bob conversation over the service and returns its id:
//
//	alice: mls_init welcoming devBob1 and devAlice2 -> record (1, 0) by alice, a welcome in each inbox, (1, 1)
//	bob: an encrypted message at (1, 1); a commit on (1, 1) -> record (1, 1) by bob, (1, 2)
//	alice: a commit on (1, 2) -> record (1, 2) by alice, (1, 3)
//	bob: a reset of generation 1 welcoming devAlice1 -> record (2, 0) by bob, a second welcome for alice, (2, 1)
//	alice, then bob: an encrypted message at (2, 1)
func (e *itEnv) e2eeHistory() string {
	e.t.Helper()
	convID := e.initMLS()
	e.must(bob, encTo(skey(2), convID, true, 1, 1, "bob 1:1"))
	e.tick(time.Second)
	e.mustCommitIT(e.svc, bob, commitReq(ckey(1), convID, 1, 1, "b11"))
	e.mustCommitIT(e.svc, alice, commitReq(ckey(2), convID, 1, 2, "a12"))
	e.mustCommitIT(e.svc, bob, resetReq(ckey(3), convID, 1, "r1", devAlice1))
	e.tick(time.Second)
	e.must(alice, encTo(skey(3), convID, true, 2, 1, "alice 2:1"))
	e.tick(time.Second)
	e.must(bob, encTo(skey(4), convID, true, 2, 1, "bob 2:1"))
	return convID
}

// rawMsgs returns the stored fields of every message of the conversation, by id.
func (e *itEnv) rawMsgs(convID string) map[string]map[string]any {
	e.t.Helper()
	return e.docsIn("conversations/" + convID + "/messages")
}

// commitSenders maps each commit record id of the conversation to its senderId.
func (e *itEnv) commitSenders(convID string) map[string]string {
	e.t.Helper()
	out := map[string]string{}
	for id, d := range e.docsIn("conversations/" + convID + "/" + commitsCollection) {
		out[id] = fmt.Sprint(d["senderId"])
	}
	return out
}

func (e *itEnv) welcomeCount(uid string) int {
	e.t.Helper()
	return len(e.docsIn("users/" + uid + "/" + dmWelcomesCollection))
}

// wantTombstoneBytes checks one encrypted tombstone: no ciphertext, commitment or ctExpireAt field at all, ctRemoved true,
// the pair and mlsKey kept.
func wantTombstoneBytes(t *testing.T, id string, d map[string]any) {
	t.Helper()
	for _, f := range []string{"ciphertext", "commitment", "ctExpireAt"} {
		if _, has := d[f]; has {
			t.Errorf("message %s kept %s", id, f)
		}
	}
	if d["ctRemoved"] != true || d["mlsKey"] == nil || d["mlsGen"] == nil || d["mlsEpoch"] == nil {
		t.Errorf("message %s: ctRemoved %v mlsKey %v mlsGen %v mlsEpoch %v", id, d["ctRemoved"], d["mlsKey"], d["mlsGen"], d["mlsEpoch"])
	}
}

// One participant erased: alice's messages are tombstones without their bytes, bob's intact; alice's commit records name
// DeletedUID, bob's keep his uid; alice's welcomes are gone, bob's (from alice's init) stays; no document holds alice's
// uid; bob still lists commits (from_self right) and epoch messages. Then bob's erasure removes the whole tree, commit
// records included.
func TestEraser_EncryptedConversation(t *testing.T) {
	e := newIT(t, nil)
	convID := e.e2eeHistory()
	if n := e.welcomeCount(alice); n != 2 {
		t.Fatalf("alice has %d welcomes before the erasure, want 2", n)
	}
	e.runEraserFor(alice)

	for full, d := range e.rawMsgs(convID) {
		id := full[:8]
		switch d["senderId"] {
		case DeletedUID:
			if d["state"] != msgDeletedAccount || d["text"] != "" {
				t.Errorf("alice's message %s: state %v text %q", id, d["state"], d["text"])
			}
			wantTombstoneBytes(t, id, d)
		case bob:
			if _, has := d["ctRemoved"]; has || d["state"] != msgVisible || len(d["ciphertext"].([]byte)) == 0 || len(d["commitment"].([]byte)) == 0 {
				t.Errorf("bob's message %s was touched: %v", id, d)
			}
		default:
			t.Errorf("message %s from %v", id, d["senderId"])
		}
	}
	if got, want := e.commitSenders(convID), map[string]string{
		commitDocID(1, 0): DeletedUID, commitDocID(1, 1): bob, commitDocID(1, 2): DeletedUID, commitDocID(2, 0): bob,
	}; !mapsEqual(got, want) {
		t.Errorf("commit senders = %v, want %v", got, want)
	}
	if n := e.welcomeCount(alice); n != 0 {
		t.Errorf("alice kept %d welcomes", n)
	}
	if n := e.welcomeCount(bob); n != 1 {
		t.Errorf("bob has %d welcomes, want his welcome from alice's init kept (it names no uid of alice)", n)
	}
	if hits := e.uidHits(alice); len(hits) > 0 {
		t.Errorf("alice's uid survives in %v", hits)
	}

	// The survivor: every commit, from_self on his own only, at the current pair; each epoch's set still complete.
	resp := e.listCommitsOn(e.svc, bob, convID, 0, 0, 0)
	var got []string
	for _, c := range resp.GetCommits() {
		got = append(got, fmt.Sprintf("%d:%d %v", c.GetMlsGeneration(), c.GetMlsEpoch(), c.GetFromSelf()))
	}
	if want := []string{"1:0 false", "1:1 true", "1:2 false", "2:0 true"}; !slices.Equal(got, want) || resp.GetMlsGeneration() != 2 || resp.GetMlsEpoch() != 1 {
		t.Errorf("bob's commits = %v at (%d, %d), want %v at (2, 1)", got, resp.GetMlsGeneration(), resp.GetMlsEpoch(), want)
	}
	for _, p := range [][2]uint64{{1, 1}, {2, 1}} {
		em, err := e.svc.ListEpochMessages(context.Background(), bob, &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: p[0], MlsEpoch: p[1]})
		if err != nil {
			t.Fatalf("epoch %v: %v", p, err)
		}
		var rows []string
		for _, m := range em.GetMessages() {
			rows = append(rows, fmt.Sprintf("%v %v %v %d", m.GetFromSelf(), m.GetState(), m.GetCiphertextRemoved(), len(m.GetCiphertext())))
		}
		slices.Sort(rows)
		ct := len("bob 1:1")
		if want := []string{"false MESSAGE_STATE_DELETED_ACCOUNT true 0", fmt.Sprintf("true MESSAGE_STATE_VISIBLE false %d", ct)}; !slices.Equal(rows, want) {
			t.Errorf("epoch %v = %v, want %v", p, rows, want)
		}
	}

	e.runEraserFor(bob)
	if left := e.treeDocs(convID); len(left) != 0 {
		t.Errorf("documents left under the conversation after both erasures: %v", left)
	}
	if n := e.welcomeCount(bob); n != 0 {
		t.Errorf("bob kept %d welcomes", n)
	}
	if hits := e.uidHits(bob); len(hits) > 0 {
		t.Errorf("bob's uid survives in %v", hits)
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// More than 500 commit records and welcomes: the senderId rewrite and the welcomes delete take several calls of at most
// 500 each, and the tree delete removes 500 children per call, messages first, then the commit records, then the
// document.
func TestEraser_CommitRecordsAndWelcomesInPages(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	convID := ConversationID(alice, bob)
	doc := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, CreatedAt: base, UpdatedAt: base,
		Encryption: encMLS, MlsGen: 1, MlsEpoch: 1_000}
	if _, err := e.fs.Collection("conversations").Doc(convID).Set(ctx, doc); err != nil {
		t.Fatal(err)
	}
	const records, welcomes, msgs = 620, 530, 30
	bw := e.fs.BulkWriter(ctx)
	var jobs []*firestore.BulkWriterJob
	add := func(ref *firestore.DocumentRef, data any) {
		j, err := bw.Set(ref, data)
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, j)
	}
	for i := range records {
		sender := alice
		if i%10 == 9 {
			sender = bob // 62 of bob's, spread through the ids
		}
		add(e.repo.commitRef(convID, 1, int64(i)), CommitDoc{Data: []byte("c"), SenderID: sender, Gen: 1, Epoch: int64(i), CreatedAt: base, ExpireAt: base.Add(CommitRetention)})
	}
	for i := range welcomes {
		add(e.repo.welcomesCol(alice).Doc(fmt.Sprintf("%032x", i)), WelcomeDoc{DeviceID: devAlice1, ConvID: convID, Gen: 1, Epoch: int64(i), Data: []byte("w"), CreatedAt: base, ExpireAt: base.Add(WelcomeRetention)})
	}
	for i := range msgs {
		add(e.fs.Collection("conversations").Doc(convID).Collection("messages").Doc(fmt.Sprintf("%032x", i)),
			MsgDoc{SenderID: bob, State: msgVisible, RequestHash: "h", CreatedAt: base.Add(time.Duration(i) * time.Second), Ciphertext: []byte("x"), Commitment: itCommitment, MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1", CtExpireAt: base.Add(CiphertextRetention)})
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatal(err)
		}
	}

	er := NewEraser(e.repo, discardLog())
	run := func(uid string) (calls int, maxCommitStep, maxWelcomeStep int, final Checkpoint) {
		var cp []byte
		var prev Checkpoint
		for calls < 100 {
			next, done, err := er.PurgeUser(ctx, uid, cp)
			calls++
			if err != nil {
				t.Fatalf("PurgeUser call %d: %v", calls, err)
			}
			var step Checkpoint
			if err := json.Unmarshal(next, &step); err != nil {
				t.Fatal(err)
			}
			maxCommitStep = max(maxCommitStep, step.CommitsRewritten-prev.CommitsRewritten)
			maxWelcomeStep = max(maxWelcomeStep, step.WelcomesDeleted-prev.WelcomesDeleted)
			prev, cp = step, next
			if done {
				return calls, maxCommitStep, maxWelcomeStep, step
			}
		}
		t.Fatal("the eraser did not finish")
		return
	}
	_, maxC, maxW, cp := run(alice)
	ownRecords := records - records/10
	if cp.CommitsRewritten != ownRecords || cp.WelcomesDeleted != welcomes || maxC != lifecyclePage || maxW != lifecyclePage {
		t.Errorf("alice: rewritten %d (max %d per call), welcomes %d (max %d per call); want %d and %d, 500 per call",
			cp.CommitsRewritten, maxC, cp.WelcomesDeleted, maxW, ownRecords, welcomes)
	}
	bobs := 0
	for _, s := range e.commitSenders(convID) {
		switch s {
		case DeletedUID:
		case bob:
			bobs++
		default:
			t.Fatalf("a commit record still names %q", s)
		}
	}
	if bobs != records/10 || e.welcomeCount(alice) != 0 {
		t.Errorf("bob's records %d (want %d), alice's welcomes left %d", bobs, records/10, e.welcomeCount(alice))
	}

	// bob next: the tree goes, 650 children in two calls (30 messages + 470 records, then 150 records) and the document.
	calls, _, _, _ := run(bob)
	if left := e.treeDocs(convID); len(left) != 0 {
		t.Errorf("%d documents left under the conversation", len(left))
	}
	// next+mark, entry, tree x2, next, welcomes.
	if calls != 6 {
		t.Errorf("bob's erasure took %d calls, want 6", calls)
	}
}

// A moderator takedown of an encrypted message: REMOVED, its ciphertext, commitment and ctExpireAt deleted (fields, not
// a rewrite), ctRemoved, the pair and mlsKey kept, rev +1 as for plaintext; the entry previews keep last.encrypted; the
// commit records and welcomes are untouched; ListEpochMessages still returns it, as a tombstone.
func TestTakedown_EncryptedMessage(t *testing.T) {
	e := newIT(t, nil)
	convID := e.initMLS()
	sent := e.must(bob, encTo(skey(2), convID, true, 1, 1, "bob says"))
	msgID := sent.GetMessage().GetId()
	before, _ := e.conv(convID)
	commitsBefore, welcomesBefore := e.commitSenders(convID), e.welcomeCount(bob)+e.welcomeCount(alice)

	res, err := e.repo.TakedownMessage(context.Background(), convID, msgID, false)
	if err != nil || !res.Wrote || res.After != msgRemoved {
		t.Fatalf("takedown = %+v, %v", res, err)
	}
	d := e.rawMsgs(convID)[msgID]
	if d["state"] != msgRemoved || d["text"] != "" || d["senderId"] != bob || d["mlsKey"] != "1:1" {
		t.Errorf("taken-down message = %v", d)
	}
	wantTombstoneBytes(t, msgID[:8], d)
	after, _ := e.conv(convID)
	if after.Rev != before.Rev+1 {
		t.Errorf("rev %d -> %d, want +1", before.Rev, after.Rev)
	}
	for _, uid := range []string{alice, bob} {
		ent, ok := e.entry(uid, dmInboxCollection, convID)
		if !ok || ent.Last.State != msgRemoved || ent.Last.Snippet != removedSnippet || !ent.Last.Encrypted {
			t.Errorf("%s's preview = %+v, %v; want REMOVED, the removed snippet, encrypted kept", uid, ent.Last, ok)
		}
	}
	if !mapsEqual(e.commitSenders(convID), commitsBefore) || e.welcomeCount(bob)+e.welcomeCount(alice) != welcomesBefore {
		t.Error("the takedown touched commit records or welcomes")
	}
	em, err := e.svc.ListEpochMessages(context.Background(), alice, &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: 1, MlsEpoch: 1})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, m := range em.GetMessages() {
		if m.GetId() == msgID {
			found = true
			if m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || !m.GetCiphertextRemoved() || len(m.GetCiphertext()) != 0 || len(m.GetReportCommitment()) != 0 {
				t.Errorf("the tombstone in its epoch = %v", m)
			}
		}
	}
	if !found {
		t.Error("the taken-down message left its epoch's completeness set")
	}
	// A plaintext takedown writes none of the encrypted fields.
	e.addUser("uid-carol", "carol", false)
	e.mutual(alice, "uid-carol")
	plain := e.must(alice, toUser(skey(50), "uid-carol", "plain words"))
	if _, err := e.repo.TakedownMessage(context.Background(), plain.GetConversation().GetId(), plain.GetMessage().GetId(), false); err != nil {
		t.Fatal(err)
	}
	pd := e.rawMsgs(plain.GetConversation().GetId())[plain.GetMessage().GetId()]
	if pd["state"] != msgRemoved {
		t.Errorf("the plaintext message was not taken down: %v", pd)
	}
	for _, f := range []string{"ctRemoved", "mlsKey", "mlsGen", "ciphertext"} {
		if _, has := pd[f]; has {
			t.Errorf("a plaintext takedown wrote %s", f)
		}
	}
}

// The export of an encrypted conversation: no ciphertext, text or post id, the note after the conversations.
func TestExport_EncryptedConversation(t *testing.T) {
	e := newIT(t, nil)
	convID := e.e2eeHistory()
	var buf bytes.Buffer
	if err := NewExporter(e.repo, e.profs, e.social).ExportUser(context.Background(), alice, &buf); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	for _, forbidden := range []string{"bob 1:1", "alice 2:1", "ciphertext", "commitment", "welcome", "commit:", convID} {
		if strings.Contains(out, forbidden) {
			t.Errorf("the export contains %q", forbidden)
		}
	}
	if !strings.HasPrefix(out, `{"conversations":[`) || !strings.HasSuffix(out, `],"note":"`+exportNote+`"}`+"\n") || strings.Count(out, `"encrypted":true`) != 4 {
		t.Errorf("export = %s", out)
	}
}
