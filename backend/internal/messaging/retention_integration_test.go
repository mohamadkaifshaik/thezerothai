//go:build integration

package messaging

// The ciphertext retention sweep (retention.go) on the emulator. The emulator enforces no index, so the collection-group
// query runs here without the COLLECTION_GROUP index on messages.ctExpireAt; that index is pinned only by
// internal/firestoreindexes (messaging_e2ee_test.go) and exists on a real project once the owner deploys it.

import (
	"context"
	"fmt"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// ctExpireAtOf is the stored ctExpireAt of one message.
func (e *itEnv) ctExpireAtOf(convID, msgID string) time.Time {
	e.t.Helper()
	at, ok := e.rawMsgs(convID)[msgID]["ctExpireAt"].(time.Time)
	if !ok {
		e.t.Fatalf("message %s has no ctExpireAt", msgID[:8])
	}
	return at
}

func (e *itEnv) sweep(now time.Time, limit int) CiphertextSweepResult {
	e.t.Helper()
	res, err := e.repo.SweepCiphertext(context.Background(), now, limit)
	if err != nil {
		e.t.Fatalf("SweepCiphertext: %v", err)
	}
	return res
}

// A message whose 30 days are up (ctExpireAt == now exactly, the boundary) loses its ciphertext, commitment and ctExpireAt
// and gets ctRemoved, and keeps its id, state VISIBLE, sender, createdAt, pair and mlsKey; ListEpochMessages still returns
// it, as ciphertext_removed with no bytes. A younger one is untouched; plaintext messages (no ctExpireAt at all, whether sent
// or written raw) are never touched; the conversation, its rev and the entries are not written. A second run finds nothing.
func TestSweepCiphertext_BlanksAfter30Days(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	convID := e.initMLS() // alice's init message at (1, 1)
	old := e.must(bob, encTo(skey(2), convID, true, 1, 1, "bob old")).GetMessage().GetId()
	e.tick(time.Hour)
	young := e.must(alice, encTo(skey(3), convID, true, 1, 1, "alice young")).GetMessage().GetId()

	e.addUser("uid-carol", "carol", false)
	e.mutual(alice, "uid-carol")
	plain := e.must(alice, toUser(skey(4), "uid-carol", "plain words"))
	plainConv := plain.GetConversation().GetId()
	rawPlain := plainConv[:31] + "0"
	if _, err := e.fs.Collection("conversations").Doc(plainConv).Collection("messages").Doc(rawPlain).Set(ctx,
		MsgDoc{SenderID: alice, Text: "raw", State: msgVisible, RequestHash: "h", CreatedAt: base}); err != nil {
		t.Fatal(err)
	}
	plainBefore := e.rawMsgs(plainConv)
	for id, d := range plainBefore {
		if _, has := d["ctExpireAt"]; has {
			t.Fatalf("plaintext message %s stores ctExpireAt", id[:8])
		}
	}
	convBefore := e.docsIn("conversations")
	entriesBefore := []map[string]map[string]any{e.docsIn("users/" + alice + "/dmInbox"), e.docsIn("users/" + bob + "/dmInbox")}
	youngBefore := e.rawMsgs(convID)[young]
	oldBefore := e.rawMsgs(convID)[old]

	now := e.ctExpireAtOf(convID, old)
	if want := oldBefore["createdAt"].(time.Time).Add(CiphertextRetention); !now.Equal(want) {
		t.Fatalf("ctExpireAt %v, want createdAt + 30 days %v", now, want)
	}
	res := e.sweep(now, CiphertextSweepPage)
	if want := (CiphertextSweepResult{Due: 2, Swept: 2}); res != want { // the init message and old
		t.Fatalf("sweep = %+v, want %+v", res, want)
	}

	after := e.rawMsgs(convID)
	for id, d := range after {
		if id == young {
			continue
		}
		wantTombstoneBytes(t, id[:8], d)
		if d["state"] != msgVisible || d["mlsKey"] != "1:1" {
			t.Errorf("swept message %s: state %v mlsKey %v", id[:8], d["state"], d["mlsKey"])
		}
	}
	o := after[old]
	if o["senderId"] != bob || !o["createdAt"].(time.Time).Equal(oldBefore["createdAt"].(time.Time)) || o["mlsGen"] != oldBefore["mlsGen"] || o["mlsEpoch"] != oldBefore["mlsEpoch"] || o["requestHash"] != oldBefore["requestHash"] {
		t.Errorf("old message kept fields changed: %v -> %v", oldBefore, o)
	}
	if !reflect.DeepEqual(after[young], youngBefore) {
		t.Errorf("young message touched: %v -> %v", youngBefore, after[young])
	}
	if !reflect.DeepEqual(e.rawMsgs(plainConv), plainBefore) {
		t.Error("a plaintext message was touched")
	}
	if !reflect.DeepEqual(e.docsIn("conversations"), convBefore) {
		t.Error("a conversation document was written")
	}
	if got := []map[string]map[string]any{e.docsIn("users/" + alice + "/dmInbox"), e.docsIn("users/" + bob + "/dmInbox")}; !reflect.DeepEqual(got, entriesBefore) {
		t.Error("an inbox entry was written")
	}

	em, err := e.svc.ListEpochMessages(ctx, alice, &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: 1, MlsEpoch: 1})
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, m := range em.GetMessages() {
		seen[m.GetId()] = true
		swept := m.GetId() != young
		if m.GetState() != messagingv1.MessageState_MESSAGE_STATE_VISIBLE || m.GetCiphertextRemoved() != swept || (len(m.GetCiphertext()) == 0) != swept || (len(m.GetReportCommitment()) == 0) != swept {
			t.Errorf("epoch message %s (swept %v) = state %v removed %v ct %d commitment %d", m.GetId()[:8], swept, m.GetState(), m.GetCiphertextRemoved(), len(m.GetCiphertext()), len(m.GetReportCommitment()))
		}
	}
	if len(seen) != 3 || !seen[old] || !seen[young] {
		t.Errorf("epoch (1, 1) lists %d messages, want the 2 swept and the young one", len(seen))
	}

	if res := e.sweep(now, CiphertextSweepPage); res != (CiphertextSweepResult{}) {
		t.Errorf("second run = %+v, want nothing due", res)
	}
	// One microsecond before the young message's boundary it is still kept; at it, it goes.
	yAt := e.ctExpireAtOf(convID, young)
	if res := e.sweep(yAt.Add(-time.Microsecond), CiphertextSweepPage); res.Due != 0 {
		t.Errorf("before the boundary: %+v", res)
	}
	if res := e.sweep(yAt, CiphertextSweepPage); res.Swept != 1 {
		t.Errorf("at the boundary: %+v", res)
	}
}

// A message taken down before the sweep is not due (the takedown deleted its ctExpireAt); one taken down between the query
// and the update is not rewritten: the precondition fails, it is counted as skipped and stays REMOVED, and the next run
// does not see it again.
func TestSweepCiphertext_TakenDownIsSkipped(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	convID := e.initMLS()
	before := e.must(bob, encTo(skey(2), convID, true, 1, 1, "taken down first")).GetMessage().GetId()
	during := e.must(bob, encTo(skey(3), convID, true, 1, 1, "taken down during")).GetMessage().GetId()
	now := e.ctExpireAtOf(convID, during)
	if _, err := e.repo.TakedownMessage(ctx, convID, before, false); err != nil {
		t.Fatal(err)
	}
	e.repo.hooks = &raceHooks{afterCiphertextSweepRead: func() {
		if _, err := e.repo.TakedownMessage(ctx, convID, during, false); err != nil {
			t.Error(err)
		}
	}}
	if res := e.sweep(now, CiphertextSweepPage); res != (CiphertextSweepResult{Due: 2, Swept: 1, Skipped: 1}) { // init swept, during skipped
		t.Fatalf("sweep = %+v", res)
	}
	e.repo.hooks = nil
	msgs := e.rawMsgs(convID)
	for _, id := range []string{before, during} {
		if msgs[id]["state"] != msgRemoved {
			t.Errorf("taken-down message %s state %v, want REMOVED kept", id[:8], msgs[id]["state"])
		}
		wantTombstoneBytes(t, id[:8], msgs[id])
	}
	if res := e.sweep(now, CiphertextSweepPage); res != (CiphertextSweepResult{}) {
		t.Errorf("next run = %+v, want nothing due", res)
	}
}

// A message changed between the query and the update (any write moves its update time) or deleted meanwhile is skipped and
// counted; the changed one keeps its ciphertext and ctExpireAt and the next run sweeps it; the deleted one is not recreated.
// A page in which every hit was skipped returns Swept 0 (the step then stops for the day).
func TestSweepCiphertext_ChangedBetweenQueryAndUpdate(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	convID := e.initMLS()
	initID := ""
	for id := range e.rawMsgs(convID) {
		initID = id
	}
	gone := e.must(bob, encTo(skey(2), convID, true, 1, 1, "deleted meanwhile")).GetMessage().GetId()
	now := e.ctExpireAtOf(convID, gone)
	msgRef := func(id string) *firestore.DocumentRef {
		return e.fs.Collection("conversations").Doc(convID).Collection("messages").Doc(id)
	}
	e.repo.hooks = &raceHooks{afterCiphertextSweepRead: func() {
		if _, err := msgRef(initID).Update(ctx, []firestore.Update{{Path: "requestHash", Value: "rewritten"}}); err != nil {
			t.Error(err)
		}
		if _, err := msgRef(gone).Delete(ctx); err != nil {
			t.Error(err)
		}
	}}
	if res := e.sweep(now, CiphertextSweepPage); res != (CiphertextSweepResult{Due: 2, Skipped: 2}) {
		t.Fatalf("sweep = %+v, want both skipped", res)
	}
	e.repo.hooks = nil
	msgs := e.rawMsgs(convID)
	if _, ok := msgs[gone]; ok {
		t.Error("the deleted message was recreated")
	}
	if d := msgs[initID]; len(d["ciphertext"].([]byte)) == 0 || d["ctExpireAt"] == nil || d["ctRemoved"] != nil || d["requestHash"] != "rewritten" {
		t.Errorf("the changed message = %v, want its bytes and ctExpireAt kept, the other write kept", d)
	}
	if res := e.sweep(now, CiphertextSweepPage); res != (CiphertextSweepResult{Due: 1, Swept: 1}) {
		t.Fatalf("next run = %+v, want the changed message swept", res)
	}
	wantTombstoneBytes(t, initID[:8], e.rawMsgs(convID)[initID])
}

// The query is a collection group (every conversation), oldest first, at most limit per call: a backlog drains page by page,
// each call continues where the last stopped, More says a page was full, and what is not yet due stays.
func TestSweepCiphertext_LimitAndContinuation(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	convs := []string{ConversationID(alice, bob), ConversationID(alice, "uid-dave")}
	now := base.Add(CiphertextRetention)
	type seeded struct {
		conv, id string
		at       time.Time
	}
	var due, notDue []seeded
	bw := e.fs.BulkWriter(ctx)
	var jobs []*firestore.BulkWriterJob
	for i := range 9 {
		s := seeded{conv: convs[i%2], id: fmt.Sprintf("%032x", 0x100+i), at: now.Add(time.Duration(i-6) * time.Minute)} // 7 due (i <= 6), 2 not
		m := MsgDoc{SenderID: bob, State: msgVisible, RequestHash: "h", CreatedAt: s.at.Add(-CiphertextRetention), Ciphertext: []byte("x"), Commitment: itCommitment, MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1", CtExpireAt: s.at}
		j, err := bw.Set(e.fs.Collection("conversations").Doc(s.conv).Collection("messages").Doc(s.id), m)
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, j)
		if i <= 6 {
			due = append(due, s)
		} else {
			notDue = append(notDue, s)
		}
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatal(err)
		}
	}
	swept := func() map[string]bool {
		out := map[string]bool{}
		for _, c := range convs {
			for id, d := range e.rawMsgs(c) {
				if d["ctRemoved"] == true {
					out[id] = true
				}
			}
		}
		return out
	}
	for i, want := range []CiphertextSweepResult{{Due: 3, Swept: 3, More: true}, {Due: 3, Swept: 3, More: true}, {Due: 1, Swept: 1}, {}} {
		if res := e.sweep(now, 3); res != want {
			t.Fatalf("call %d = %+v, want %+v", i+1, res, want)
		}
		got := swept()
		// Oldest first: after call k exactly the min(3k, 7) oldest due messages are blanked.
		for j, s := range due {
			if got[s.id] != (j < min(3*(i+1), len(due))) {
				t.Errorf("after call %d message %d swept = %v", i+1, j, got[s.id])
			}
		}
		for _, s := range notDue {
			if got[s.id] {
				t.Errorf("a message not yet due was swept after call %d", i+1)
			}
		}
	}
	if res := e.sweep(now, 0); res != (CiphertextSweepResult{}) {
		t.Errorf("limit 0 = %+v, want nothing (never an unbounded query)", res)
	}
}
