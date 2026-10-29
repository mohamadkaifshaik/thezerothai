//go:build integration

package messaging

import (
	"context"
	"testing"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// setEntry updates fields of uid's entry in a folder collection.
func (e *itEnv) setEntry(uid, collection, convID string, ups ...firestore.Update) {
	e.t.Helper()
	if _, err := e.fs.Collection("users").Doc(uid).Collection(collection).Doc(convID).Update(context.Background(), ups); err != nil {
		e.t.Fatal(err)
	}
}

// W7-27 on the emulator: a first page carries the caller's own unread_count and silent (3 unread, 25 reads at page 20, 55 at
// page 50), an older page and a since refresh leave them unset, and a missing entry (delete for me) is 0 and still costs the
// one read.
func TestListMessages_FirstPageUnreadOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	var msgs [][2]string
	for range 45 {
		msgs = append(msgs, [2]string{bob, "m"})
	}
	id := e.seedConversation(alice, bob, stateAccepted, base, msgs...)
	e.setEntry(alice, dmInboxCollection, id, firestore.Update{Path: "unreadCount", Value: 3}, firestore.Update{Path: "silent", Value: true})
	svc := e.msgSvc()

	first, c := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	budgettest.Assert(t, "ListMessages first page of 20 with the entry", c, budgettest.Budget{Reads: 25})
	if c.Reads() != 25 || c.Writes() != 0 {
		t.Errorf("first page reads/writes = %d/%d, want 25/0", c.Reads(), c.Writes())
	}
	if first.Conversation.GetUnreadCount() != 3 || !first.Conversation.GetSilent() {
		t.Fatalf("first page conversation = %+v, want unread_count 3 silent true", first.Conversation)
	}
	// Bob's side is untouched by alice's read: his entry has 0 unread.
	if bobFirst, _ := e.mustListMsgs(e.msgSvc(), bob, &messagingv1.ListMessagesRequest{ConversationId: id}); bobFirst.Conversation.GetUnreadCount() != 0 {
		t.Errorf("bob's unread_count = %d, want his own entry's 0", bobFirst.Conversation.GetUnreadCount())
	}

	older, c2 := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageToken: first.NextPageToken})
	budgettest.Assert(t, "ListMessages older page, no entry read", c2, budgettest.Budget{Reads: 24})
	if older.Conversation.GetUnreadCount() != 0 || older.Conversation.GetSilent() {
		t.Errorf("older page conversation = %+v, want unread_count 0 silent false", older.Conversation)
	}
	poll, c3 := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id, SinceToken: first.SinceToken})
	budgettest.Assert(t, "ListMessages poll, no entry read", c3, budgettest.Budget{Reads: 2 + int64(max(len(poll.Messages), 1))})
	if poll.Conversation != nil {
		t.Errorf("since refresh conversation = %+v, want none", poll.Conversation)
	}

	_, c50 := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageSize: 50})
	budgettest.Assert(t, "ListMessages first page of 50 with the entry", c50, budgettest.Budget{Reads: 55})

	// Delete for me removed the entry: 0 unread, not silent, and the lookup still billed its read (25, not 24).
	if _, err := e.fs.Collection("users").Doc(alice).Collection(dmInboxCollection).Doc(id).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	gone, c4 := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	budgettest.Assert(t, "ListMessages first page, entry gone", c4, budgettest.Budget{Reads: 25})
	if gone.Conversation.GetUnreadCount() != 0 || gone.Conversation.GetSilent() {
		t.Errorf("entry gone: conversation = %+v, want 0 / false", gone.Conversation)
	}
}

// The recipient of an unaccepted request has the entry in dmRequests; the first page reads that collection (one read, never
// a probe of both), and the requester reads dmInbox.
func TestListMessages_FirstPageUnreadFromRequests(t *testing.T) {
	e := newIT(t, nil)
	id := e.seedConversation(alice, bob, stateRequest, base, [2]string{alice, "hello"}, [2]string{alice, "again"})
	e.setEntry(bob, dmRequestsCollection, id, firestore.Update{Path: "unreadCount", Value: 2})
	e.setEntry(alice, dmInboxCollection, id, firestore.Update{Path: "unreadCount", Value: 7})

	recipient, c := e.mustListMsgs(e.msgSvc(), bob, &messagingv1.ListMessagesRequest{ConversationId: id})
	budgettest.Assert(t, "ListMessages first page, request recipient", c, budgettest.Budget{Reads: 1 + 1 + 2 + 1 + 1 + 1})
	if recipient.Conversation.GetUnreadCount() != 2 || recipient.Conversation.GetFolder() != messagingv1.Folder_FOLDER_REQUESTS {
		t.Errorf("recipient conversation = %+v, want unread 2 in REQUESTS", recipient.Conversation)
	}
	requester, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	if requester.Conversation.GetUnreadCount() != 7 {
		t.Errorf("requester conversation = %+v, want unread 7", requester.Conversation)
	}
}
