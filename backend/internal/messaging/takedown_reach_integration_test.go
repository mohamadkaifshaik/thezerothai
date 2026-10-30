//go:build integration

package messaging

// A takedown, and an account erasure, reach the devices of both participants that cached the thread or the inbox
// (ADR-0027 note 2026-10-29, W7-12 B1). Each "device" is a service instance of its own plus the since tokens it holds; the
// "server" that answers after the change is another fresh instance, so no 60 s conversation cache hides the change.

import (
	"errors"
	"testing"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
)

// device is what a client keeps: the since tokens of one thread and of one inbox folder.
type device struct {
	uid          string
	thread       string
	folder       messagingv1.Folder
	inbox        string
	inboxOrder   []string
	inboxUpdated time.Time
}

// openDevice runs the first page of the thread and of the folder on a cold instance and keeps the tokens.
func (e *itEnv) openDevice(uid, convID string, folder messagingv1.Folder) device {
	e.t.Helper()
	svc := e.msgSvc()
	tr, _ := e.mustListMsgs(svc, uid, &messagingv1.ListMessagesRequest{ConversationId: convID})
	li, _ := e.mustList(svc, uid, &messagingv1.ListConversationsRequest{Folder: folder})
	d := device{uid: uid, thread: tr.GetSinceToken(), folder: folder, inbox: li.GetSinceToken()}
	for _, c := range li.GetConversations() {
		d.inboxOrder = append(d.inboxOrder, c.GetId())
		if c.GetId() == convID {
			d.inboxUpdated = c.GetUpdatedAt().AsTime()
		}
	}
	if d.thread == "" || d.inbox == "" {
		e.t.Fatalf("%s: a first page issued no since token", uid)
	}
	return d
}

func isSinceRetired(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Metadata["field"] == "since_token"
}

// wantReached asserts the device now converges: its thread poll is retired after at most 2 reads, a first page shows the
// message as removed, and its inbox since refresh returns the entry with the preview as rewritten, in the same place.
func (e *itEnv) wantTakedownReached(d device, convID, msgID string, previewRemoved bool) {
	e.t.Helper()
	svc := e.msgSvc() // answers after the change: a cold instance
	_, c, err := e.listMsgs(svc, d.uid, &messagingv1.ListMessagesRequest{ConversationId: convID, SinceToken: d.thread})
	if !isSinceRetired(err) {
		e.t.Fatalf("%s: the old thread token was not retired: %v", d.uid, err)
	}
	if c.Reads() > 2 {
		e.t.Errorf("%s: the retirement cost %d reads, want at most 2 (interceptor, conversation)", d.uid, c.Reads())
	}
	first, _ := e.mustListMsgs(svc, d.uid, &messagingv1.ListMessagesRequest{ConversationId: convID})
	var seen bool
	for _, m := range first.GetMessages() {
		if m.GetId() == msgID {
			seen = true
			if m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || m.GetText() != "" {
				e.t.Errorf("%s: first page shows %v %q, want REMOVED with no text", d.uid, m.GetState(), m.GetText())
			}
		}
	}
	if !seen {
		e.t.Errorf("%s: the first page lost the tombstone", d.uid)
	}
	// The new token works, and the cold open is the only reload: a poll with it is accepted.
	if _, _, perr := e.listMsgs(svc, d.uid, &messagingv1.ListMessagesRequest{ConversationId: convID, SinceToken: first.GetSinceToken()}); perr != nil {
		e.t.Errorf("%s: the token of the cold open is refused: %v", d.uid, perr)
	}

	ref, _ := e.mustList(svc, d.uid, &messagingv1.ListConversationsRequest{Folder: d.folder, SinceToken: d.inbox})
	if !previewRemoved {
		// The entry may come back because the sends are still inside the 5 s settle window of the device's token (the client
		// dedupes by id); what matters is that its preview is untouched by the takedown.
		for _, c := range ref.GetConversations() {
			if c.GetLastMessage().GetState() != messagingv1.MessageState_MESSAGE_STATE_VISIBLE {
				e.t.Errorf("%s: the preview of a message that was not taken down shows %v", d.uid, c.GetLastMessage().GetState())
			}
		}
		return
	}
	if len(ref.GetConversations()) != 1 || ref.GetConversations()[0].GetId() != convID {
		e.t.Fatalf("%s: inbox refresh = %d entries, want the one that changed", d.uid, len(ref.GetConversations()))
	}
	conv := ref.GetConversations()[0]
	if p := conv.GetLastMessage(); p.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || p.GetSnippet() != "" {
		e.t.Errorf("%s: refreshed preview = %v %q, want REMOVED with no snippet", d.uid, p.GetState(), p.GetSnippet())
	}
	if !conv.GetUpdatedAt().AsTime().Equal(d.inboxUpdated) {
		e.t.Errorf("%s: updated_at moved from %v to %v: the inbox order must not change", d.uid, d.inboxUpdated, conv.GetUpdatedAt().AsTime())
	}
	fresh, _ := e.mustList(svc, d.uid, &messagingv1.ListConversationsRequest{Folder: d.folder})
	if got := respIDs(fresh); len(got) != len(d.inboxOrder) || (len(got) > 0 && got[0] != d.inboxOrder[0]) {
		e.t.Errorf("%s: inbox order %v, was %v", d.uid, got, d.inboxOrder)
	}
}

// Takedown of the last message: both participants' devices converge.
func TestTakedownReach_LastMessageReachesBothParticipants(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	devs := []device{e.openDevice(alice, convID, messagingv1.Folder_FOLDER_INBOX), e.openDevice(bob, convID, messagingv1.Folder_FOLDER_INBOX)}
	if _, _, err := e.takedown(convID, m2, false); err != nil {
		t.Fatal(err)
	}
	for _, d := range devs {
		e.wantTakedownReached(d, convID, m2, true)
	}
}

// A request conversation: the recipient's entry is in REQUESTS, and the Requests since refresh shows the removal; the
// requester's Inbox does too.
func TestTakedownReach_RequestConversation(t *testing.T) {
	e := newIT(t, nil)
	convID := e.request(2)
	last := e.msgsOrdered(convID)[1]
	recipient := e.openDevice(bob, convID, messagingv1.Folder_FOLDER_REQUESTS)
	requester := e.openDevice(alice, convID, messagingv1.Folder_FOLDER_INBOX)
	if _, _, err := e.takedown(convID, last, false); err != nil {
		t.Fatal(err)
	}
	e.wantTakedownReached(recipient, convID, last, true)
	e.wantTakedownReached(requester, convID, last, true)
}

// A removed message that is not the preview: the inbox entry does not change (no inbox row to refresh), the thread token is
// still retired because the thread shows the text.
func TestTakedownReach_NotTheLastMessage(t *testing.T) {
	e := newIT(t, nil)
	convID, m1, _ := twoMessages(t, e)
	devs := []device{e.openDevice(alice, convID, messagingv1.Folder_FOLDER_INBOX), e.openDevice(bob, convID, messagingv1.Folder_FOLDER_INBOX)}
	before, _ := e.entry(alice, dmInboxCollection, convID)
	res, c, err := e.takedown(convID, m1, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Entries != 0 || !res.Wrote {
		t.Fatalf("result = %+v", res)
	}
	conv, _ := e.conv(convID)
	if conv.Rev != 1 {
		t.Errorf("rev = %d, want 1: the revision is bumped even when no preview shows the message", conv.Rev)
	}
	wantBudget(t, "takedown not last", c, 4, 2)
	if after, _ := e.entry(alice, dmInboxCollection, convID); !after.ChangedAt.Equal(before.ChangedAt) {
		t.Errorf("changedAt moved from %v to %v for a message that is not the preview", before.ChangedAt, after.ChangedAt)
	}
	for _, d := range devs {
		e.wantTakedownReached(d, convID, m1, false)
	}
}

// The written fields and budget of one takedown: removedAt, rev +1 once (a repeat does not bump it), updatedAt strictly later,
// changedAt (server time) on the rewritten previews, lastMessageAt untouched; a dry run changes nothing.
func TestTakedownReach_WritesAndBudget(t *testing.T) {
	e := newIT(t, nil)
	e.tick(-time.Hour) // the sends are stamped an hour before the takedown's server time
	convID, _, m2 := twoMessages(t, e)
	convBefore, _ := e.conv(convID)
	entryBefore, _ := e.entry(alice, dmInboxCollection, convID)

	if _, c, err := e.takedown(convID, m2, true); err != nil {
		t.Fatal(err)
	} else {
		wantBudget(t, "dry run", c, 4, 0)
	}
	if conv, _ := e.conv(convID); conv.Rev != 0 || e.msgs(convID)[m2].State != msgVisible {
		t.Fatalf("a dry run wrote: rev %d, state %s", conv.Rev, e.msgs(convID)[m2].State)
	}

	_, c, err := e.takedown(convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	wantBudget(t, "takedown", c, 4, 4)
	conv, _ := e.conv(convID)
	if conv.Rev != 1 || !conv.UpdatedAt.After(convBefore.UpdatedAt) {
		t.Errorf("conversation rev %d updatedAt %v (was %v), want rev 1 and a later updatedAt", conv.Rev, conv.UpdatedAt, convBefore.UpdatedAt)
	}
	if msg := e.msgs(convID)[m2]; msg.RemovedAt.IsZero() || msg.State != msgRemoved || msg.Text != "" {
		t.Errorf("message = %+v, want REMOVED with removedAt set", msg)
	}
	for _, uid := range []string{alice, bob} {
		ent, _ := e.entry(uid, dmInboxCollection, convID)
		if !ent.ChangedAt.After(entryBefore.ChangedAt) || !ent.LastMessageAt.Equal(entryBefore.LastMessageAt) {
			t.Errorf("%s: changedAt %v (was %v), lastMessageAt %v (was %v): changedAt must move, lastMessageAt must not", uid, ent.ChangedAt, entryBefore.ChangedAt, ent.LastMessageAt, entryBefore.LastMessageAt)
		}
	}

	_, c, err = e.takedown(convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	wantBudget(t, "repeat", c, 1, 0)
	if conv, _ := e.conv(convID); conv.Rev != 1 {
		t.Errorf("a repeat bumped rev to %d", conv.Rev)
	}
}

// The takedown stamps conversations.updatedAt from the transaction's own (server) read time, never from the operator's clock:
// updatedAt is the floor of Accept's changedAt, Delete's clearedAt and, through stampAfterClear, of every later send. A laptop
// whose clock runs 10 minutes ahead must not push any of them into the future: a delete after the takedown, then a reply at
// real time, still shows up in the other participant's inbox since refresh and in the thread.
func TestTakedownReach_OperatorClockAheadDoesNotPoisonLaterStamps(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	e.repo.now = func() time.Time { return time.Now().Add(10 * time.Minute) } // the operator's laptop
	alice1 := e.openDevice(alice, convID, messagingv1.Folder_FOLDER_INBOX)
	if _, _, err := e.takedown(convID, m2, false); err != nil {
		t.Fatal(err)
	}
	ceiling := time.Now().Add(time.Minute) // generous: server time plus the test's own fake-clock lead
	conv, _ := e.conv(convID)
	if conv.UpdatedAt.After(ceiling) {
		t.Fatalf("conversation updatedAt = %v is in the future (ceiling %v): the takedown used the operator's clock", conv.UpdatedAt, ceiling)
	}

	svc := e.newService()
	if _, err := e.del(svc, alice, convID); err != nil {
		t.Fatal(err)
	}
	conv, _ = e.conv(convID)
	if cleared := conv.ClearedAt[alice]; cleared.After(ceiling) {
		t.Fatalf("clearedAt = %v is in the future (ceiling %v)", cleared, ceiling)
	}

	e.tick(time.Second)
	reply := e.must(bob, toUser(skey(7), alice, "reply after the delete")).GetMessage().GetId()
	if created := e.msgs(convID)[reply].CreatedAt; created.After(ceiling) {
		t.Fatalf("the reply is stamped %v, in the future (ceiling %v)", created, ceiling)
	}
	// alice's device: the inbox since refresh returns the conversation with the reply, and the thread shows the reply.
	ref, _ := e.mustList(e.msgSvc(), alice, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: alice1.inbox})
	if len(ref.GetConversations()) != 1 || ref.GetConversations()[0].GetLastMessage().GetSnippet() != "reply after the delete" {
		t.Fatalf("alice's inbox refresh = %v, want the conversation previewing the reply", respIDs(ref))
	}
	first, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: convID})
	if len(first.GetMessages()) != 1 || first.GetMessages()[0].GetId() != reply {
		t.Errorf("alice's thread = %d messages, want only the reply after her delete", len(first.GetMessages()))
	}
}

// Two service instances, one of them with a stale 60 s copy of the conversation: a pre-takedown token is accepted by the stale
// one until its copy expires (simulated by dropping it) and refused by a fresh one; a token of the new revision is accepted by
// the stale one, which drops its copy and re-seals the higher revision; after the one cold open the instances alternate
// without another reload.
func TestTakedownReach_TwoInstances(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	stale := e.msgSvc()
	first, _ := e.mustListMsgs(stale, alice, &messagingv1.ListMessagesRequest{ConversationId: convID}) // caches rev 0
	old := first.GetSinceToken()
	if _, _, err := e.takedown(convID, m2, false); err != nil {
		t.Fatal(err)
	}
	fresh := e.msgSvc()
	poll := func(svc *service, tok string) (*messagingv1.ListMessagesResponse, error) {
		resp, _, err := e.listMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: convID, SinceToken: tok})
		return resp, err
	}
	if _, err := poll(fresh, old); !isSinceRetired(err) {
		t.Fatalf("a fresh instance accepted the pre-takedown token: %v", err)
	}
	if _, err := poll(stale, old); err != nil {
		t.Fatalf("the stale instance (copy younger than 60 s) refused the pre-takedown token: %v", err)
	}
	stale.convs.Delete(convID) // its copy expires
	if _, err := poll(stale, old); !isSinceRetired(err) {
		t.Fatalf("after its copy expired the instance accepted the pre-takedown token: %v", err)
	}

	// The cold open on a fresh instance seals rev 1.
	cold, _ := e.mustListMsgs(fresh, alice, &messagingv1.ListMessagesRequest{ConversationId: convID})
	if _, rev, err := cursor.DecodeRevAtTTL(testCursorKey, messagesSinceBinding(alice, convID), cold.GetSinceToken(), e.now(), RefreshTokenTTL); err != nil || rev != 1 {
		t.Fatalf("cold open token rev = %d (%v), want 1", rev, err)
	}
	// A stale instance (copy at rev 0) receives that token: accepted, copy dropped, rev 1 re-sealed.
	stale2 := e.msgSvc()
	stale2.convs.Set(convID, ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted, UpdatedAt: time.Now().Add(-time.Hour)}) // rev 0
	resp, err := poll(stale2, cold.GetSinceToken())
	if err != nil {
		t.Fatalf("a newer-rev token was refused by a stale instance: %v", err)
	}
	if _, rev, derr := cursor.DecodeRevAtTTL(testCursorKey, messagesSinceBinding(alice, convID), resp.GetSinceToken(), e.now(), RefreshTokenTTL); derr != nil || rev != 1 {
		t.Errorf("re-sealed rev = %d (%v), want 1 (never backwards)", rev, derr)
	}
	if _, ok := stale2.convs.Get(convID); ok {
		t.Error("the stale copy was kept")
	}
	// Alternating polls need no further cold open.
	tok := resp.GetSinceToken()
	for i, svc := range []*service{fresh, stale2, stale, fresh, stale} {
		r, perr := poll(svc, tok)
		if perr != nil {
			t.Fatalf("poll %d on alternating instances was refused: %v", i, perr)
		}
		tok = r.GetSinceToken()
	}
}

// Tokens issued before this change: a thread token of the plain format on a conversation with no revision is accepted; an inbox
// since token of the earlier kind is VALIDATION and costs no read beyond the interceptor's.
func TestTakedownReach_LegacyTokens(t *testing.T) {
	e := newIT(t, nil)
	convID, _, _ := twoMessages(t, e)
	svc := e.msgSvc()
	legacyThread := cursor.EncodeAt(testCursorKey, messagesSinceBinding(alice, convID), cursor.Cursor{CreatedAt: e.now().Add(-time.Minute), DocID: "-"}, e.now())
	if _, _, err := e.listMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: convID, SinceToken: legacyThread}); err != nil {
		t.Errorf("a legacy thread token on a conversation with no rev: %v", err)
	}
	legacyInbox := cursor.EncodeAt(testCursorKey, "messaging|conversations|since|"+alice+"|"+dmInboxCollection, cursor.Cursor{CreatedAt: e.now().Add(-time.Minute), DocID: "-"}, e.now())
	_, c, err := e.list(svc, alice, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: legacyInbox})
	if !isSinceRetired(err) || c.Reads() != 1 {
		t.Errorf("legacy inbox token: err %v, reads %d, want VALIDATION since_token with only the interceptor's read", err, c.Reads())
	}
}

// Every send writes changedAt equal to lastMessageAt on both entries, without a read or write more (send budgets are asserted
// by the send tests).
func TestTakedownReach_SendWritesChangedAt(t *testing.T) {
	e := newIT(t, nil)
	convID, _, _ := twoMessages(t, e)
	for _, uid := range []string{alice, bob} {
		ent, _ := e.entry(uid, dmInboxCollection, convID)
		if ent.ChangedAt.IsZero() || !ent.ChangedAt.Equal(ent.LastMessageAt) {
			t.Errorf("%s: changedAt %v, lastMessageAt %v, want equal", uid, ent.ChangedAt, ent.LastMessageAt)
		}
	}
}

// The eraser: after the sender deletes the account, the surviving peer's cached thread token is retired and the first page
// shows the DELETED_ACCOUNT tombstones and the "Deleted account" header; the inbox since refresh returns the rewritten entry.
// A rerun of the step does not bump the revision again once the conversation no longer lists the erased account.
func TestTakedownReach_EraserReachesThePeer(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(bob, toUser(skey(1), alice, "from bob"))
	e.tick(time.Second)
	last := e.must(alice, toUser(skey(2), bob, "from alice, the last message")).GetMessage().GetId()
	convID := ConversationID(alice, bob)
	d := e.openDevice(bob, convID, messagingv1.Folder_FOLDER_INBOX)

	e.runEraserFor(alice)
	conv, _ := e.conv(convID)
	if conv.Rev != 1 {
		t.Fatalf("rev after the erasure = %d, want 1", conv.Rev)
	}
	svc := e.msgSvc()
	if _, _, err := e.listMsgs(svc, bob, &messagingv1.ListMessagesRequest{ConversationId: convID, SinceToken: d.thread}); !isSinceRetired(err) {
		t.Fatalf("bob's cached thread token survived the erasure: %v", err)
	}
	first, _ := e.mustListMsgs(svc, bob, &messagingv1.ListMessagesRequest{ConversationId: convID})
	var tomb bool
	for _, m := range first.GetMessages() {
		if m.GetId() == last {
			tomb = m.GetState() == messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT && m.GetText() == ""
		}
	}
	if !tomb || first.GetConversation().GetPeer().GetDisplayName() != DeletedAccountName {
		t.Errorf("first page: tombstone %v, header %q", tomb, first.GetConversation().GetPeer().GetDisplayName())
	}
	ref, _ := e.mustList(svc, bob, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: d.inbox})
	if len(ref.GetConversations()) != 1 {
		t.Fatalf("inbox refresh = %d entries, want the rewritten one", len(ref.GetConversations()))
	}
	c := ref.GetConversations()[0]
	if c.GetPeer().GetDisplayName() != DeletedAccountName || c.GetLastMessage().GetState() != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT {
		t.Errorf("refreshed entry = peer %q preview %v", c.GetPeer().GetDisplayName(), c.GetLastMessage().GetState())
	}
	e.runEraserFor(alice)
	if again, _ := e.conv(convID); again.Rev != 1 {
		t.Errorf("a rerun of the step bumped rev to %d", again.Rev)
	}
}

// Accept: the accepter's other device holds an INBOX since token from before; the conversation shows up in its next INBOX
// refresh. Accept's budget stays 3 / 2 / 1; an already accepted replay writes nothing and does not move changedAt.
func TestTakedownReach_AcceptReachesTheOtherDevice(t *testing.T) {
	e := newIT(t, nil)
	convID := e.request(2)
	other := e.openDevice(bob, convID, messagingv1.Folder_FOLDER_INBOX) // bob's second device: the request is not in its INBOX
	if len(other.inboxOrder) != 0 {
		t.Fatalf("setup: the inbox already lists %v", other.inboxOrder)
	}
	e.tick(time.Minute)
	c, err := e.accept(e.newService(), bob, convID)
	if err != nil {
		t.Fatal(err)
	}
	if c.Reads() != 4 || c.Writes() != 3 || c.Deletes() != 1 {
		t.Errorf("accept reads/writes/deletes = %d/%d/%d, want 4/3/1", c.Reads(), c.Writes(), c.Deletes())
	}
	ref, _ := e.mustList(e.msgSvc(), bob, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: other.inbox})
	if got := respIDs(ref); len(got) != 1 || got[0] != convID {
		t.Fatalf("the other device's INBOX refresh = %v, want the accepted conversation", got)
	}
	moved, _ := e.entry(bob, dmInboxCollection, convID)
	e.tick(time.Minute)
	c, err = e.accept(e.newService(), bob, convID)
	if err != nil || c.Writes() != 0 {
		t.Fatalf("replay: err %v writes %d, want success with 0 writes", err, c.Writes())
	}
	if again, _ := e.entry(bob, dmInboxCollection, convID); !again.ChangedAt.Equal(moved.ChangedAt) {
		t.Errorf("an already accepted replay moved changedAt: %v -> %v", moved.ChangedAt, again.ChangedAt)
	}
}

// msgsOrdered returns the conversation's message ids oldest first.
func (e *itEnv) msgsOrdered(convID string) []string {
	e.t.Helper()
	m := e.msgs(convID)
	ids := make([]string, 0, len(m))
	for id := range m {
		ids = append(ids, id)
	}
	for i := range ids {
		for j := i + 1; j < len(ids); j++ {
			if m[ids[j]].CreatedAt.Before(m[ids[i]].CreatedAt) {
				ids[i], ids[j] = ids[j], ids[i]
			}
		}
	}
	return ids
}

// wantBudget asserts exact reads and writes of a counter (the takedown budgets of the RPC doc comment).
func wantBudget(t *testing.T, label string, c *budget.Counter, reads, writes int64) {
	t.Helper()
	if c.Reads() != reads || c.Writes() != writes {
		t.Errorf("%s: reads/writes = %d/%d, want %d/%d", label, c.Reads(), c.Writes(), reads, writes)
	}
}
