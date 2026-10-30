//go:build integration

package messaging

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// W7-25a integration tests: the requester's pending request reads REQUEST in their own Inbox through the requestPending flag
// on the requester's dmInbox entry (ADR-0027 note W7-25). alice is the requester, bob the recipient.

func (e *itEnv) rowState(svc *service, uid string, req *messagingv1.ListConversationsRequest, convID string) (messagingv1.ConversationState, messagingv1.Folder, bool) {
	e.t.Helper()
	resp, _ := e.mustList(svc, uid, req)
	for _, c := range resp.Conversations {
		if c.Id == convID {
			return c.State, c.Folder, true
		}
	}
	return 0, 0, false
}

// Given A sends one to three request messages, then A's INBOX row reads REQUEST in the INBOX folder on a first page and on
// a since refresh, the recipient's entry never carries the flag, and Send costs what it did (the flag rides the entry writes;
// the reads include W7-33's recipient graph read in the transaction).
func TestRequestPending_SenderRowReadsRequest(t *testing.T) {
	e := newIT(t, nil)
	svc := e.listSvc()
	id := ConversationID(alice, bob)
	for i := range 3 {
		e.tick(time.Minute)
		_, c, err := e.send(alice, toUser(skey(300+i), bob, fmt.Sprintf("request %d", i)))
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			budgettest.Assert(t, "SendMessage new conversation", c, budgettest.Budget{Reads: 4, Writes: 5})
		} else {
			budgettest.Assert(t, "SendMessage request message", c, budgettest.Budget{Reads: 2, Writes: 4})
		}
		if ent, ok := e.entry(alice, dmInboxCollection, id); !ok || !ent.RequestPending {
			t.Fatalf("after message %d alice's entry = %+v %v, want requestPending", i, ent, ok)
		}
		if bobEnt, _ := e.entry(bob, dmRequestsCollection, id); bobEnt.RequestPending {
			t.Fatal("the recipient's dmRequests entry carries requestPending")
		}
	}
	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(first.Conversations) != 1 || first.Conversations[0].State != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST ||
		first.Conversations[0].Folder != messagingv1.Folder_FOLDER_INBOX {
		t.Fatalf("first page = %+v, want one REQUEST row in INBOX", first.Conversations)
	}
	st, folder, ok := e.rowState(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken}, id)
	if !ok || st != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || folder != messagingv1.Folder_FOLDER_INBOX {
		t.Fatalf("since refresh = %v %v %v, want REQUEST in INBOX", st, folder, ok)
	}
	// The recipient's REQUESTS row is REQUEST as before.
	if st, folder, ok := e.rowState(e.listSvc(), bob, &messagingv1.ListConversationsRequest{Folder: requests}, id); !ok ||
		st != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || folder != messagingv1.Folder_FOLDER_REQUESTS {
		t.Errorf("bob's row = %v %v %v", st, folder, ok)
	}
}

// Given B accepts, then A's next INBOX since refresh returns the row as ACCEPTED.
func TestRequestPending_AcceptClearsAndMovesChangedAt(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(2)
	svc := e.listSvc()
	e.tick(time.Minute)
	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(first.Conversations) != 1 || first.Conversations[0].State != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST {
		t.Fatalf("before accept: %+v", first.Conversations)
	}
	e.tick(time.Minute)
	if _, err := e.accept(e.newService(), bob, id); err != nil {
		t.Fatal(err)
	}
	ref, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if len(ref.Conversations) != 1 || ref.Conversations[0].Id != id || ref.Conversations[0].State != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED ||
		ref.Conversations[0].Folder != messagingv1.Folder_FOLDER_INBOX {
		t.Fatalf("since refresh after accept = %+v, want the row as ACCEPTED in INBOX", ref.Conversations)
	}
}

// Given B replies instead of accepting, then the reply's write to A's entry cleared the flag: A's next refresh reads ACCEPTED.
func TestRequestPending_ReplyClears(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	svc := e.listSvc()
	e.tick(time.Minute)
	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	e.tick(time.Minute)
	if _, _, err := e.send(bob, toUser(skey(1), alice, "yes?")); err != nil {
		t.Fatal(err)
	}
	if ent, _ := e.entry(alice, dmInboxCollection, id); ent.RequestPending {
		t.Fatal("alice's flag survived the accepting reply")
	}
	st, folder, ok := e.rowState(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken}, id)
	if !ok || st != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED || folder != messagingv1.Folder_FOLDER_INBOX {
		t.Fatalf("refresh after the reply = %v %v %v", st, folder, ok)
	}
}

// Given A deleted the conversation for themselves before B accepts, then Accept succeeds with 4 reads, 2 writes and 1 delete
// and A has no dmInbox entry afterwards (no ghost doc).
func TestRequestPending_AcceptAfterRequesterDeleted(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	if _, err := e.del(e.newService(), alice, id); err != nil {
		t.Fatal(err)
	}
	if _, ok := e.entry(alice, dmInboxCollection, id); ok {
		t.Fatal("setup: alice's entry survived her delete")
	}
	e.tick(time.Minute)
	c, err := e.accept(e.newService(), bob, id)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "AcceptMessageRequest, requester deleted", c, budgettest.Budget{Reads: 4, Writes: 2, Deletes: 1})
	if _, ok := e.entry(alice, dmInboxCollection, id); ok {
		t.Error("Accept created a ghost dmInbox entry for the requester")
	}
	if conv, _ := e.conv(id); conv.State != stateAccepted {
		t.Errorf("conversation state = %q", conv.State)
	}
}

// Given B deletes the request, then A's row still reads REQUEST and A's cap still applies.
func TestRequestPending_RecipientDeleteKeepsRequest(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(3)
	if _, err := e.del(e.newService(), bob, id); err != nil {
		t.Fatal(err)
	}
	st, folder, ok := e.rowState(e.listSvc(), alice, &messagingv1.ListConversationsRequest{Folder: inbox}, id)
	if !ok || st != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || folder != messagingv1.Folder_FOLDER_INBOX {
		t.Fatalf("alice's row = %v %v %v, want REQUEST in INBOX", st, folder, ok)
	}
	e.tick(time.Minute)
	if _, _, err := e.send(alice, toUser(skey(900), bob, "again")); err == nil {
		t.Error("the cap did not apply after the recipient deleted the request")
	}
}

// Given the mutual path, then no flag is written and the row reads ACCEPTED. Given an entry without the field (written before
// W7-25a), then it reads ACCEPTED as before.
func TestRequestPending_MutualAndLegacyReadAccepted(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(alice, toUser(skey(1), bob, "hi"))
	id := ConversationID(alice, bob)
	if ent, _ := e.entry(alice, dmInboxCollection, id); ent.RequestPending {
		t.Error("a mutual-path send set requestPending")
	}
	if st, _, ok := e.rowState(e.listSvc(), alice, &messagingv1.ListConversationsRequest{Folder: inbox}, id); !ok || st != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED {
		t.Errorf("mutual row = %v %v", st, ok)
	}

	l := newIT(t, nil)
	legacy := l.seedConversation(alice, bob, stateRequest, base, [2]string{alice, "hello"})
	ent, _ := l.entry(alice, dmInboxCollection, legacy)
	if !ent.RequestPending {
		t.Fatal("setup: the seeded requester entry has no flag")
	}
	ent.RequestPending = false // the entry as an older build wrote it
	if _, err := l.fs.Collection("users").Doc(alice).Collection(dmInboxCollection).Doc(legacy).Set(context.Background(), ent); err != nil {
		t.Fatal(err)
	}
	if st, _, ok := l.rowState(l.listSvc(), alice, &messagingv1.ListConversationsRequest{Folder: inbox}, legacy); !ok || st != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED {
		t.Errorf("legacy row = %v %v, want ACCEPTED", st, ok)
	}
}

// Given an Accept racing the requester's third message, then whichever order wins ends with the flag cleared, an ACCEPTED
// conversation, and a request count of 2 (the send came second) or 3 (the send came first).
func TestRequestPending_AcceptRacesThirdMessage(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(2)
	e.tick(time.Minute)
	var wg sync.WaitGroup
	var acceptErr, sendErr error
	wg.Add(2)
	go func() { defer wg.Done(); _, acceptErr = e.accept(e.newService(), bob, id) }()
	go func() {
		defer wg.Done()
		_, _, sendErr = e.sendOn(e.newService(), alice, toUser(skey(777), bob, "third"))
	}()
	wg.Wait()
	if acceptErr != nil || sendErr != nil {
		t.Fatalf("accept: %v, send: %v", acceptErr, sendErr)
	}
	ent, ok := e.entry(alice, dmInboxCollection, id)
	if !ok || ent.RequestPending {
		t.Errorf("alice's entry = %+v %v, want no requestPending", ent, ok)
	}
	conv, _ := e.conv(id)
	if conv.State != stateAccepted || (conv.RequestCount != 2 && conv.RequestCount != 3) {
		t.Errorf("conversation = %+v", conv)
	}
}
