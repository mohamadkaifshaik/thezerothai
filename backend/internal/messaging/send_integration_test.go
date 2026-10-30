//go:build integration

package messaging

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func skey(n int) string { return fmt.Sprintf("send-key-%08d", n) }

// ADR-0027 "Cost impact" per RPC, minus the account-status interceptor's read, which the Connect chain adds (the
// apiserver chain tests assert the full 5 / 7). Here only the repo's own reads count: the directory and graph are fakes.

// Mutual follows: the message lands in B's dmInbox with unreadCount 1 and one `message` event leaves; 3 writes.
func TestSend_MutualGoesToInboxWithOneEvent(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	resp, c, err := e.send(alice, toUser(skey(1), bob, "hello bob"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage new+mutual", c, budgettest.Budget{Reads: 4, Writes: 5})
	convID := ConversationID(alice, bob)
	if c.Reads() != 4 || c.Writes() != 5 || c.Deletes() != 0 {
		t.Errorf("new conversation reads/writes/deletes = %d/%d/%d, want 4/5/0 (conversation, recipient graph, recipient users, quotas / message, conversation, 2 entries, quotas)", c.Reads(), c.Writes(), c.Deletes())
	}
	conv, ok := e.conv(convID)
	if !ok || conv.State != stateAccepted || len(conv.Participants) != 2 {
		t.Fatalf("conversation = %+v, %v", conv, ok)
	}
	in, ok := e.entry(bob, "dmInbox", convID)
	if !ok || in.UnreadCount != 1 || in.PeerID != alice || in.Peer.Handle != "alice" || in.Last.FromSelf || in.Last.Snippet != "hello bob" {
		t.Errorf("bob's dmInbox entry = %+v, %v", in, ok)
	}
	if _, ok := e.entry(bob, "dmRequests", convID); ok {
		t.Error("an accepted conversation must not create a request entry")
	}
	own, ok := e.entry(alice, "dmInbox", convID)
	if !ok || own.UnreadCount != 0 || !own.Last.FromSelf || own.PeerID != bob {
		t.Errorf("alice's dmInbox entry = %+v, %v", own, ok)
	}
	if len(e.events.got) != 1 || e.events.got[0].RecipientUID != bob || e.events.got[0].ConversationID != convID {
		t.Errorf("events = %+v, want one message event to bob", e.events.got)
	}
	if got := e.dmNew(alice); got != 1 {
		t.Errorf("quotas.dmNew = %d, want 1", got)
	}
	if resp.GetConversation().GetState() != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED || resp.GetMessage().GetFromSelf() != true {
		t.Errorf("response = %v", resp)
	}

	// A second message in the accepted conversation: 3 writes, 1 read, no conversation write, unread 2.
	e.tick(time.Second)
	_, c2, err := e.send(alice, toUser(skey(2), bob, "again"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage accepted", c2, budgettest.Budget{Reads: 2, Writes: 3})
	if c2.Reads() != 2 || c2.Writes() != 3 || c2.Deletes() != 0 {
		t.Errorf("accepted reads/writes/deletes = %d/%d/%d, want 2/3/0 (conversation, recipient graph)", c2.Reads(), c2.Writes(), c2.Deletes())
	}
	if in, _ := e.entry(bob, "dmInbox", convID); in.UnreadCount != 2 || in.Last.Snippet != "again" {
		t.Errorf("bob's entry after the second message = %+v", in)
	}
	if len(e.events.got) != 2 {
		t.Errorf("events = %d, want 2", len(e.events.got))
	}
}

// Non-mutuals: B's entry is in dmRequests (unread 1), no event, a REQUEST conversation (4 writes from the 2nd message).
func TestSend_RequestPathAndTheFourthMessage(t *testing.T) {
	e := newIT(t, nil)
	convID := ConversationID(alice, bob)
	for i := 1; i <= 3; i++ {
		e.tick(time.Second)
		_, c, err := e.send(alice, toUser(skey(i), bob, fmt.Sprintf("request message %d", i)))
		if err != nil {
			t.Fatalf("request message %d: %v", i, err)
		}
		if i == 1 {
			budgettest.Assert(t, "SendMessage new+request", c, budgettest.Budget{Reads: 4, Writes: 5})
		} else {
			budgettest.Assert(t, "SendMessage request", c, budgettest.Budget{Reads: 2, Writes: 4})
			if c.Writes() != 4 {
				t.Errorf("request message %d writes = %d, want 4 (message, 2 entries, requestCount)", i, c.Writes())
			}
		}
	}
	conv, _ := e.conv(convID)
	if conv.State != stateRequest || conv.RequestCount != 3 || conv.RequestFrom != alice || conv.RequestTo != bob {
		t.Fatalf("conversation = %+v", conv)
	}
	req, ok := e.entry(bob, "dmRequests", convID)
	if !ok || req.UnreadCount != 3 || req.Last.Snippet != "request message 3" {
		t.Errorf("bob's dmRequests entry = %+v, %v", req, ok)
	}
	if _, ok := e.entry(bob, "dmInbox", convID); ok {
		t.Error("a request must not appear in the recipient's Inbox")
	}
	if own, ok := e.entry(alice, "dmInbox", convID); !ok || own.PeerID != bob {
		t.Errorf("the requester sees the conversation in her own Inbox: %+v, %v", own, ok)
	}
	if len(e.events.got) != 0 {
		t.Errorf("a request pushed %d events, want 0", len(e.events.got))
	}

	// The 4th message: LIMIT_REACHED request_unanswered, 0 writes, nothing stored.
	_, c, err := e.send(alice, toUser(skey(4), bob, "request message 4"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "request_unanswered"})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("the refused 4th message wrote %d / deleted %d", c.Writes(), c.Deletes())
	}
	if n := len(e.msgs(convID)); n != 3 {
		t.Errorf("messages stored = %d, want 3", n)
	}

	// The retry of the 3rd message (a lost response) is a replay, not a refusal: the cap has no say about it.
	resp, c, err := e.send(alice, toUser(skey(3), bob, "request message 3"))
	if err != nil {
		t.Fatalf("replay of the last allowed request message: %v", err)
	}
	if c.Writes() != 0 {
		t.Errorf("the replay wrote %d", c.Writes())
	}
	if resp.GetMessage().GetId() != MessageID(alice, skey(3)) {
		t.Errorf("replayed id = %q", resp.GetMessage().GetId())
	}
	if conv, _ := e.conv(convID); conv.RequestCount != 3 {
		t.Errorf("requestCount = %d after the replay, want 3", conv.RequestCount)
	}
}

// B's reply to a request accepts it (as X does): the conversation turns ACCEPTED, B's entry moves from dmRequests to
// dmInbox, A is pushed; 4 writes and 1 delete.
func TestSend_ReplyAcceptsARequest(t *testing.T) {
	e := newIT(t, nil)
	convID := ConversationID(alice, bob)
	e.must(alice, toUser(skey(1), bob, "may I?"))
	e.tick(time.Second)
	_, c, err := e.send(bob, toUser(skey(2), alice, "sure"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage reply that accepts", c, budgettest.Budget{Reads: 2, Writes: 4, Deletes: 1})
	if c.Writes() != 4 || c.Deletes() != 1 {
		t.Errorf("reply writes/deletes = %d/%d, want 4/1", c.Writes(), c.Deletes())
	}
	if conv, _ := e.conv(convID); conv.State != stateAccepted {
		t.Errorf("state = %q, want ACCEPTED", conv.State)
	}
	if _, ok := e.entry(bob, "dmRequests", convID); ok {
		t.Error("bob's dmRequests entry must be gone after his reply")
	}
	if in, ok := e.entry(bob, "dmInbox", convID); !ok || !in.Last.FromSelf || in.PeerID != alice {
		t.Errorf("bob's dmInbox entry = %+v, %v", in, ok)
	}
	if in, ok := e.entry(alice, "dmInbox", convID); !ok || in.UnreadCount != 1 || in.Last.Snippet != "sure" {
		t.Errorf("alice's entry = %+v, %v", in, ok)
	}
	if len(e.events.got) != 1 || e.events.got[0].RecipientUID != alice {
		t.Errorf("events = %+v, want one push to alice", e.events.got)
	}
}

// B muted A: delivered, `silent`, no unread increment, no event. The conversation is still created and visible to B.
func TestSend_MutedSenderIsDeliveredSilently(t *testing.T) {
	e := newIT(t, func(e *itEnv) {
		e.setSocial(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Muted: map[string]bool{alice: true}})
		e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
	})
	convID := ConversationID(alice, bob)
	e.must(alice, toUser(skey(1), bob, "psst"))
	in, ok := e.entry(bob, "dmInbox", convID)
	if !ok || !in.Silent || in.UnreadCount != 0 || in.Last.Snippet != "psst" {
		t.Errorf("bob's entry = %+v, %v, want silent with no unread", in, ok)
	}
	if len(e.events.got) != 0 {
		t.Errorf("a muted sender pushed %d events", len(e.events.got))
	}
	// A second silent message still does not count.
	e.tick(time.Second)
	e.must(alice, toUser(skey(2), bob, "psst again"))
	if in, _ := e.entry(bob, "dmInbox", convID); in.UnreadCount != 0 {
		t.Errorf("unread = %d after two silent messages, want 0", in.UnreadCount)
	}
}

// The same key twice: one message; the second call returns it with 0 writes and no second event. The same key with
// other text is a VALIDATION error on idempotency_key.
func TestSend_ReplayAndKeyReuse(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	first, _, err := e.send(alice, toUser(skey(1), bob, "once"))
	if err != nil {
		t.Fatal(err)
	}
	e.tick(time.Minute)
	again, c, err := e.send(alice, toUser(skey(1), bob, "once"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage replay", c, budgettest.Budget{Reads: 3})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("replay wrote %d / deleted %d, want 0 / 0", c.Writes(), c.Deletes())
	}
	if first.GetMessage().GetId() != again.GetMessage().GetId() || !first.GetMessage().GetCreatedAt().AsTime().Equal(again.GetMessage().GetCreatedAt().AsTime()) {
		t.Errorf("the replay answered another message: %v vs %v", first.GetMessage(), again.GetMessage())
	}
	if n := len(e.msgs(convID)); n != 1 {
		t.Errorf("messages = %d, want 1", n)
	}
	if in, _ := e.entry(bob, "dmInbox", convID); in.UnreadCount != 1 {
		t.Errorf("unread = %d after a replay, want 1", in.UnreadCount)
	}
	if len(e.events.got) != 1 {
		t.Errorf("events = %d after a replay, want 1", len(e.events.got))
	}

	_, c, err = e.send(alice, toUser(skey(1), bob, "different text"))
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
	if c.Writes() != 0 {
		t.Errorf("a reused key wrote %d", c.Writes())
	}
	if msgs := e.msgs(convID); len(msgs) != 1 {
		t.Errorf("messages = %d after the reuse, want 1", len(msgs))
	}
}

// The 21st new conversation in a day is LIMIT_REACHED dm_new_daily (5 for a new account: the 6th); a message in an
// existing conversation is not charged.
func TestSend_NewConversationDailyQuota(t *testing.T) {
	for _, tt := range []struct {
		name  string
		isNew bool
		max   int
	}{{"established account: 20", false, 20}, {"new account: 5", true, 5}} {
		t.Run(tt.name, func(t *testing.T) {
			e := newIT(t, func(e *itEnv) {
				e.addUser(alice, "alice", tt.isNew)
				for i := 0; i <= tt.max; i++ {
					e.addUser(fmt.Sprintf("peer-%02d", i), fmt.Sprintf("peer%02d", i), false)
				}
			})
			for i := range tt.max {
				e.must(alice, toUser(skey(i), fmt.Sprintf("peer-%02d", i), "hi"))
			}
			if got := e.dmNew(alice); got != int64(tt.max) {
				t.Fatalf("dmNew = %d, want %d", got, tt.max)
			}
			_, c, err := e.send(alice, toUser(skey(99), fmt.Sprintf("peer-%02d", tt.max), "one too many"))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "dm_new_daily"})
			if c.Writes() != 0 {
				t.Errorf("the refused conversation wrote %d", c.Writes())
			}
			if _, ok := e.conv(ConversationID(alice, fmt.Sprintf("peer-%02d", tt.max))); ok {
				t.Error("the refused conversation was created")
			}
			// An existing conversation is not a new one.
			if _, _, err := e.send(alice, toUser(skey(100), "peer-00", "follow-up")); err != nil {
				t.Errorf("a message in an existing conversation at the cap: %v", err)
			}
			if got := e.dmNew(alice); got != int64(tt.max) {
				t.Errorf("dmNew = %d after the follow-up, want still %d", got, tt.max)
			}
		})
	}
}

// A conversation whose peer deleted the account (gone) refuses every send with CANNOT_MESSAGE and writes nothing.
func TestSend_GoneConversation(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	e.must(alice, toUser(skey(1), bob, "before"))
	if _, err := e.fs.Collection("conversations").Doc(convID).Update(context.Background(), []firestoreUpdate{{Path: "gone", Value: []string{bob}}}); err != nil {
		t.Fatal(err)
	}
	// A fresh instance: no cached conversation, so the refusal comes from the transaction itself.
	_, c, err := e.sendOn(e.newService(), alice, toUser(skey(2), bob, "after"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
	if c.Writes() != 0 {
		t.Errorf("a gone conversation wrote %d", c.Writes())
	}
	if n := len(e.msgs(convID)); n != 1 {
		t.Errorf("messages = %d, want 1", n)
	}
	// By conversation id too, from a service whose cache is cold.
	_, _, err = e.sendOn(e.newService(), alice, toConv(skey(3), convID, "after"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
}

// Sending by conversation_id (IT): the participant check reads the document once (cold, 1 extra read), later sends hit the
// cache; a stranger gets NOT_FOUND.
func TestSendIT_ByConversationID(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	e.must(alice, toUser(skey(1), bob, "hi"))

	svc := e.newService() // cold cache
	_, c, err := e.sendOn(svc, bob, toConv(skey(2), convID, "hi alice"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage by conversation_id, cold cache", c, budgettest.Budget{Reads: 3, Writes: 3})
	_, c, err = e.sendOn(svc, bob, toConv(skey(3), convID, "still here"))
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "SendMessage by conversation_id, warm cache", c, budgettest.Budget{Reads: 2, Writes: 3})

	e.addUser("uid-carol", "carol", false)
	_, _, err = e.sendOn(svc, "uid-carol", toConv(skey(4), convID, "let me in"))
	wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
}

// Two senders creating one conversation at the same time (A to B and B to A): exactly one conversation document, both
// messages stored, and the new-conversation quota charged once in all. The loser's transaction re-runs, finds the
// conversation and sends into it (as the reply that accepts a request, or into the accepted conversation).
func TestSend_TwoSendersCreateOneConversation(t *testing.T) {
	for round := range 5 {
		t.Run(fmt.Sprintf("round %d", round), func(t *testing.T) {
			e := newIT(t, func(e *itEnv) {
				if round%2 == 0 {
					e.mutual(alice, bob)
				}
			})
			convID := ConversationID(alice, bob)
			svcA, svcB := e.newService(), e.newService()
			var wg sync.WaitGroup
			errs := make([]error, 2)
			start := make(chan struct{})
			for i, who := range []struct {
				svc  *service
				from string
				to   string
			}{{svcA, alice, bob}, {svcB, bob, alice}} {
				wg.Add(1)
				go func() {
					defer wg.Done()
					<-start
					_, _, errs[i] = e.sendOn(who.svc, who.from, toUser(skey(10+i), who.to, "hello from "+who.from))
				}()
			}
			close(start)
			wg.Wait()
			for i, err := range errs {
				if err != nil {
					t.Fatalf("sender %d: %v", i, err)
				}
			}
			if msgs := e.msgs(convID); len(msgs) != 2 {
				t.Errorf("messages = %d, want 2", len(msgs))
			}
			conv, ok := e.conv(convID)
			if !ok {
				t.Fatal("no conversation document")
			}
			if total := e.dmNew(alice) + e.dmNew(bob); total != 1 {
				t.Errorf("dmNew charged %d times in all, want 1 (the loser sent into the existing conversation)", total)
			}
			if round%2 == 0 && conv.State != stateAccepted {
				t.Errorf("mutual pair: state = %q", conv.State)
			}
		})
	}
}

// The key hashed into the message id is the sender's: two users sending with the same key do not collide.
func TestSend_SameKeyDifferentSendersDoNotCollide(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	a := e.must(alice, toUser(skey(1), bob, "from alice"))
	b := e.must(bob, toUser(skey(1), alice, "from bob"))
	if a.GetMessage().GetId() == b.GetMessage().GetId() {
		t.Error("two senders with one key got one message id")
	}
	if n := len(e.msgs(ConversationID(alice, bob))); n != 2 {
		t.Errorf("messages = %d, want 2", n)
	}
}

// The conversation is never trusted from the cache: a send after the peer's account turned gone elsewhere still fails.
func TestSend_NeverTrustsTheCachedConversation(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	e.must(alice, toUser(skey(1), bob, "hi")) // caches the conversation as not gone
	if _, err := e.fs.Collection("conversations").Doc(convID).Update(context.Background(), []firestoreUpdate{{Path: "gone", Value: []string{bob}}}); err != nil {
		t.Fatal(err)
	}
	_, _, err := e.send(alice, toConv(skey(2), convID, "stale cache"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
}

// A long text is stored whole while the entry snippet is cut to 100 code points.
func TestSend_SnippetIsCutStoredTextIsNot(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	long := strings.Repeat("é", 250)
	resp := e.must(alice, toUser(skey(1), bob, long))
	convID := ConversationID(alice, bob)
	in, _ := e.entry(bob, "dmInbox", convID)
	if n := len([]rune(in.Last.Snippet)); n != SnippetMaxRunes {
		t.Errorf("snippet has %d code points, want %d", n, SnippetMaxRunes)
	}
	for _, m := range e.msgs(convID) {
		if m.Text != long {
			t.Errorf("stored text has %d code points, want 250", len([]rune(m.Text)))
		}
	}
	if resp.GetConversation().GetLastMessage().GetSnippet() != in.Last.Snippet {
		t.Error("the response snippet differs from the stored one")
	}
}
