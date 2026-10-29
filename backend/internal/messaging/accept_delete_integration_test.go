//go:build integration

package messaging

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W7-9 integration tests: AcceptMessageRequest and DeleteConversation on the real FirestoreRepo (ADR-0027 D1, D4, D6, D14).
// In every test alice is the requester and bob the recipient, as in the plan's A and B. Each RPC runs under its own budget
// counter pre-charged with the account-status interceptor's 1 read, so the budgets are the per-RPC table of ADR-0027.

func (e *itEnv) accept(svc *service, uid, convID string) (*budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	c.AddReads(1)
	_, err := svc.Accept(ctx, uid, &messagingv1.AcceptMessageRequestRequest{IdempotencyKey: lifeKey, ConversationId: convID})
	return c, err
}

// delSeq makes every del call a new user action with a new idempotency_key (a client generates one key per action, and
// reuses it only to retry that action): a second del in a test is a second delete, not a retry of the first.
var delSeq atomic.Int64

func (e *itEnv) del(svc *service, uid, convID string) (*budget.Counter, error) {
	return e.delKey(svc, uid, convID, fmt.Sprintf("delete-key-%016d", delSeq.Add(1)))
}

// delKey is DeleteConversation with an explicit idempotency_key (a retry reuses the key of the action it retries).
func (e *itEnv) delKey(svc *service, uid, convID, key string) (*budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	c.AddReads(1)
	_, err := svc.Delete(ctx, uid, &messagingv1.DeleteConversationRequest{IdempotencyKey: key, ConversationId: convID})
	return c, err
}

// request opens a request from alice to bob with n messages (not mutual, so it lands in bob's dmRequests), one second
// apart, and returns the conversation id.
func (e *itEnv) request(n int) string {
	e.t.Helper()
	for i := range n {
		e.tick(time.Second)
		e.must(alice, toUser(skey(100+i), bob, fmt.Sprintf("request %d", i)))
	}
	return ConversationID(alice, bob)
}

func (e *itEnv) listFolder(svc *service, uid string, folder messagingv1.Folder) []string {
	e.t.Helper()
	resp, err := svc.ListConversations(context.Background(), uid, &messagingv1.ListConversationsRequest{Folder: folder})
	if err != nil {
		e.t.Fatalf("ListConversations: %v", err)
	}
	return respIDs(resp)
}

func (e *itEnv) threadTexts(svc *service, uid, convID string) []string {
	e.t.Helper()
	resp, err := svc.ListMessages(context.Background(), uid, &messagingv1.ListMessagesRequest{ConversationId: convID})
	if err != nil {
		e.t.Fatalf("ListMessages: %v", err)
	}
	var out []string
	for _, m := range resp.Messages {
		out = append(out, m.Text)
	}
	return out
}

// Given B accepts, then both see the conversation in the Inbox, B's unread count is kept, the state is ACCEPTED, A's own
// entry is untouched, nothing is emitted, and B's next reply pushes to A. A second message of A lands in B's Inbox, not in
// Requests, and the unanswered-request cap no longer applies. Budget (ADR-0027 table): 3 reads, 2 writes, 1 delete.
func TestAccept_MovesTheRequestWithinBudget(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(2)
	if ent, ok := e.entry(bob, dmRequestsCollection, id); !ok || ent.UnreadCount != 2 {
		t.Fatalf("setup: bob's request entry = %+v %v", ent, ok)
	}
	aliceBefore, _ := e.entry(alice, dmInboxCollection, id)
	requestEntry, _ := e.entry(bob, dmRequestsCollection, id)
	events := len(e.events.got)

	svc := e.newService() // a cold instance
	e.tick(time.Minute)
	c, err := e.accept(svc, bob, id)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "AcceptMessageRequest", c, budgettest.Budget{Reads: 3, Writes: 2, Deletes: 1})
	if c.Reads() != 3 || c.Writes() != 2 || c.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 3/2/1", c.Reads(), c.Writes(), c.Deletes())
	}
	conv, _ := e.conv(id)
	if conv.State != stateAccepted || conv.RequestTo != bob || conv.RequestFrom != alice || conv.RequestCount != 2 || !conv.UpdatedAt.Equal(e.now().Truncate(time.Microsecond)) {
		t.Errorf("conversation = %+v", conv)
	}
	if _, ok := e.entry(bob, dmRequestsCollection, id); ok {
		t.Error("the request entry was not deleted")
	}
	moved, ok := e.entry(bob, dmInboxCollection, id)
	if !ok || moved != requestEntry {
		t.Errorf("bob's inbox entry = %+v %v, want the request entry as it was (unreadCount kept)", moved, ok)
	}
	if after, _ := e.entry(alice, dmInboxCollection, id); after != aliceBefore {
		t.Errorf("alice's entry changed: %+v -> %+v", aliceBefore, after)
	}
	if len(e.events.got) != events {
		t.Error("accept emitted an event")
	}
	if last := e.badge.got[len(e.badge.got)-1]; len(last) != 1 || last[0] != bob {
		t.Errorf("badge evictions = %v, want a last eviction of bob", e.badge.got)
	}
	// Both see it in the Inbox; bob's Requests is empty.
	if got := e.listFolder(svc, bob, messagingv1.Folder_FOLDER_INBOX); len(got) != 1 || got[0] != id {
		t.Errorf("bob's inbox = %v", got)
	}
	if got := e.listFolder(svc, bob, messagingv1.Folder_FOLDER_REQUESTS); len(got) != 0 {
		t.Errorf("bob's requests = %v, want none", got)
	}
	if got := e.listFolder(e.newService(), alice, messagingv1.Folder_FOLDER_INBOX); len(got) != 1 || got[0] != id {
		t.Errorf("alice's inbox = %v", got)
	}

	// B's reply pushes to A (the recipient side is accepted now).
	e.tick(time.Second)
	e.must(bob, toUser(skey(1), alice, "hi alice"))
	if n := len(e.events.got); n != events+1 || e.events.got[n-1].RecipientUID != alice || e.events.got[n-1].ActorUID != bob {
		t.Errorf("events = %+v, want one message event to alice", e.events.got[events:])
	}
	// A's further messages (past the old cap of 3) land in B's Inbox, with a push.
	for i := range 4 {
		e.tick(time.Second)
		e.must(alice, toUser(skey(200+i), bob, fmt.Sprintf("after accept %d", i)))
	}
	if _, ok := e.entry(bob, dmRequestsCollection, id); ok {
		t.Error("a message after accept recreated bob's request entry")
	}
	in, ok := e.entry(bob, dmInboxCollection, id)
	if !ok || in.UnreadCount != 2+4 || in.Last.Snippet != "after accept 3" {
		t.Errorf("bob's inbox entry after four more messages = %+v %v", in, ok)
	}
	if final, _ := e.conv(id); final.State != stateAccepted || final.RequestCount != 2 {
		t.Errorf("conversation after more messages = %+v", final)
	}
	if n := len(e.events.got); n != events+1+4 || e.events.got[n-1].RecipientUID != bob {
		t.Errorf("events = %d, want 4 more pushes to bob", n)
	}
}

// Given an accept replayed, then success with 2 reads (interceptor, conversation) and no write.
func TestAccept_ReplayOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	if _, err := e.accept(e.newService(), bob, id); err != nil {
		t.Fatal(err)
	}
	conv, _ := e.conv(id)
	entry, _ := e.entry(bob, dmInboxCollection, id)
	e.tick(time.Minute)
	c, err := e.accept(e.newService(), bob, id)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	budgettest.Assert(t, "AcceptMessageRequest replay", c, budgettest.Budget{Reads: 2})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("replay writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}
	if again, _ := e.conv(id); again.UpdatedAt != conv.UpdatedAt {
		t.Error("a replay moved updatedAt")
	}
	if again, _ := e.entry(bob, dmInboxCollection, id); again != entry {
		t.Error("a replay changed bob's entry")
	}
}

// Given A calls Accept on its own request, then NOT_FOUND; the same bytes as a non-participant, an unknown id and a
// conversation that never was a request, after 2 reads, with nothing written.
func TestAccept_OnlyTheRecipient_NotFoundByteIdentical(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	e.addUser(carol, "carol", false)
	e.mutual(alice, "uid-dave")
	e.addUser("uid-dave", "dave", false)
	e.must(alice, toUser(skey(7), "uid-dave", "hello dave"))
	mutual := ConversationID(alice, "uid-dave")
	unknown := ConversationID(alice, "uid-nobody")
	// A request the recipient already deleted for themselves: the conversation is still a REQUEST for bob, but his entry is
	// gone, so Accept answers the same NOT_FOUND, after one more read (interceptor, conversation, the missing entry).
	e.addUser("uid-erin", "erin", false)
	e.must("uid-erin", toUser(skey(8), bob, "hello bob"))
	deleted := ConversationID("uid-erin", bob)
	if _, err := e.del(e.newService(), bob, deleted); err != nil {
		t.Fatal(err)
	}

	cases := map[string]struct {
		uid, id string
		reads   int64
	}{
		"the requester":                   {alice, id, 2},
		"a non-participant":               {carol, id, 2},
		"an unknown id":                   {alice, unknown, 2},
		"never a request":                 {"uid-dave", mutual, 2},
		"a request the recipient deleted": {bob, deleted, 3},
	}
	var first []byte
	for name, tt := range cases {
		c, err := e.accept(e.newService(), tt.uid, tt.id)
		if codeOf(err) != connect.CodeNotFound {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
		budgettest.Assert(t, "AcceptMessageRequest NOT_FOUND "+name, c, budgettest.Budget{Reads: tt.reads})
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("%s: writes/deletes = %d/%d, want 0/0", name, c.Writes(), c.Deletes())
		}
		if b := wireBytes(t, err); first == nil {
			first = b
		} else if !bytes.Equal(first, b) {
			t.Errorf("%s: NOT_FOUND bytes differ", name)
		}
	}
	conv, _ := e.conv(id)
	if conv.State != stateRequest {
		t.Errorf("state = %q after refused accepts, want REQUEST", conv.State)
	}
	if _, ok := e.entry(bob, dmRequestsCollection, id); !ok {
		t.Error("bob's request entry is gone")
	}
	for _, uid := range []string{alice, carol} {
		if _, ok := e.entry(uid, dmRequestsCollection, id); ok {
			t.Errorf("%s got a request entry", uid)
		}
	}
	if _, ok := e.entry(alice, dmInboxCollection, unknown); ok {
		t.Error("an unknown id created an entry")
	}
}

// Given a peer outside the flag cohort, then CANNOT_MESSAGE (the bytes of a block) and nothing changes. Given the
// requester deleted the account, then CANNOT_MESSAGE as well, and the recipient can still delete the request.
func TestAccept_PeerFlagOffAndErasedPeer(t *testing.T) {
	t.Run("peer flag off", func(t *testing.T) {
		e := newIT(t, nil)
		id := e.request(1)
		e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{bob: {}}})
		c, err := e.accept(e.newService(), bob, id)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
		budgettest.Assert(t, "AcceptMessageRequest peer flag off", c, budgettest.Budget{Reads: 2})
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
		}
		if conv, _ := e.conv(id); conv.State != stateRequest {
			t.Errorf("state = %q, want REQUEST", conv.State)
		}
		if _, ok := e.entry(bob, dmRequestsCollection, id); !ok {
			t.Error("the request entry moved")
		}
		// The caller outside the cohort: FEATURE_DISABLED before any read.
		e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{alice: {}}})
		c, err = e.accept(e.newService(), bob, id)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": FlagName})
		if c.Reads() != 1 {
			t.Errorf("a disabled accept read %d, want only the interceptor's 1", c.Reads())
		}
	})
	t.Run("requester erased", func(t *testing.T) {
		e := newIT(t, nil)
		id := e.request(2)
		e.runEraserFor(alice)
		if conv, _ := e.conv(id); len(conv.Gone) != 1 || conv.RequestFrom != DeletedUID {
			t.Fatalf("setup: conversation after the eraser = %+v", conv)
		}
		c, err := e.accept(e.newService(), bob, id)
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
		}
		ent, ok := e.entry(bob, dmRequestsCollection, id)
		if !ok || ent.PeerID != DeletedUID || ent.Peer.DisplayName != DeletedAccountName {
			t.Errorf("bob's request entry = %+v %v, want the Deleted account placeholder", ent, ok)
		}
		// Clean-up stays possible.
		dc, err := e.del(e.newService(), bob, id)
		if err != nil {
			t.Fatalf("delete of a conversation with an erased peer: %v", err)
		}
		budgettest.Assert(t, "DeleteConversation erased peer", dc, budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1})
		if _, ok := e.entry(bob, dmRequestsCollection, id); ok {
			t.Error("bob's entry survived the delete")
		}
		conv, _ := e.conv(id)
		if conv.ClearedAt[bob].IsZero() || len(conv.Participants) != 2 {
			t.Errorf("conversation after delete = %+v", conv)
		}
	})
}

// Given B deleted a request, then Accept is NOT_FOUND (a deleted conversation) and the state stays REQUEST.
func TestAccept_AfterDeleteIsNotFound(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	if _, err := e.del(e.newService(), bob, id); err != nil {
		t.Fatal(err)
	}
	c, err := e.accept(e.newService(), bob, id)
	if codeOf(err) != connect.CodeNotFound {
		t.Fatalf("err = %v, want NOT_FOUND", err)
	}
	budgettest.Assert(t, "AcceptMessageRequest after delete", c, budgettest.Budget{Reads: 3})
	if c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("writes/deletes = %d/%d, want 0/0", c.Writes(), c.Deletes())
	}
	if conv, _ := e.conv(id); conv.State != stateRequest {
		t.Errorf("state = %q, want REQUEST", conv.State)
	}
	if _, ok := e.entry(bob, dmInboxCollection, id); ok {
		t.Error("a refused accept created an inbox entry")
	}
}

// Given B deletes a request, then B's folders lack it, clearedAt[B] is set, the state is still REQUEST with its count, and
// A's entry and the messages are untouched. Budget: 3 reads, 1 write, 1 delete. A's cap still applies: the 4th message of
// A is refused after the delete. Replay: 0 writes.
func TestDelete_RequestKeepsTheSendersCap(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(3)
	aliceBefore, _ := e.entry(alice, dmInboxCollection, id)

	svc := e.newService()
	e.tick(time.Minute)
	c, err := e.del(svc, bob, id)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "DeleteConversation request", c, budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1})
	if c.Reads() != 3 || c.Writes() != 1 || c.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 3/1/1", c.Reads(), c.Writes(), c.Deletes())
	}
	conv, _ := e.conv(id)
	if conv.State != stateRequest || conv.RequestCount != 3 || !conv.ClearedAt[bob].Equal(e.now().Truncate(time.Microsecond)) || !conv.ClearedAt[alice].IsZero() {
		t.Errorf("conversation = %+v, want REQUEST, count 3, clearedAt[bob] = now only", conv)
	}
	for _, folder := range []string{dmInboxCollection, dmRequestsCollection} {
		if _, ok := e.entry(bob, folder, id); ok {
			t.Errorf("bob still has a %s entry", folder)
		}
	}
	if after, _ := e.entry(alice, dmInboxCollection, id); after != aliceBefore {
		t.Error("alice's entry changed")
	}
	if len(e.msgs(id)) != 3 {
		t.Errorf("messages = %d, want 3 (delete for me removes none)", len(e.msgs(id)))
	}
	if got := e.listFolder(svc, bob, messagingv1.Folder_FOLDER_REQUESTS); len(got) != 0 {
		t.Errorf("bob's requests = %v", got)
	}
	if bobView := e.threadTexts(svc, bob, id); len(bobView) != 0 {
		t.Errorf("bob still reads %v on this instance", bobView)
	}
	if aliceView := e.threadTexts(e.newService(), alice, id); len(aliceView) != 3 {
		t.Errorf("alice reads %d messages, want 3", len(aliceView))
	}

	// The cap still applies to A.
	e.tick(time.Second)
	_, _, err = e.send(alice, toUser(skey(300), bob, "a fourth request"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "request_unanswered"})

	// A repeat of the delete: success, nothing written.
	rc, err := e.del(e.newService(), bob, id)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	budgettest.Assert(t, "DeleteConversation replay", rc, budgettest.Budget{Reads: 3})
	if rc.Writes() != 0 || rc.Deletes() != 0 {
		t.Errorf("replay writes/deletes = %d/%d, want 0/0", rc.Writes(), rc.Deletes())
	}
	if again, _ := e.conv(id); !again.ClearedAt[bob].Equal(conv.ClearedAt[bob]) {
		t.Error("a replayed delete moved clearedAt")
	}
}

// Given B deletes, then a new message from A (under the cap) recreates B's request entry showing only that message: B reads
// only the newer message, with unreadCount 1, while A still reads the whole thread. The same for an accepted conversation
// deleted from the Inbox.
func TestDelete_ThenANewMessageRecreatesTheEntry(t *testing.T) {
	t.Run("request", func(t *testing.T) {
		e := newIT(t, nil)
		id := e.request(1)
		e.tick(time.Minute)
		if _, err := e.del(e.newService(), bob, id); err != nil {
			t.Fatal(err)
		}
		e.tick(time.Minute)
		e.must(alice, toUser(skey(400), bob, "after the delete"))
		ent, ok := e.entry(bob, dmRequestsCollection, id)
		if !ok || ent.UnreadCount != 1 || ent.Last.Snippet != "after the delete" || ent.PeerID != alice {
			t.Fatalf("bob's recreated request entry = %+v %v", ent, ok)
		}
		if _, ok := e.entry(bob, dmInboxCollection, id); ok {
			t.Error("the request landed in the Inbox")
		}
		svc := e.newService()
		if got := e.threadTexts(svc, bob, id); len(got) != 1 || got[0] != "after the delete" {
			t.Errorf("bob reads %v, want only the newer message", got)
		}
		if got := e.listFolder(svc, bob, messagingv1.Folder_FOLDER_REQUESTS); len(got) != 1 || got[0] != id {
			t.Errorf("bob's requests = %v", got)
		}
		if got := e.threadTexts(e.newService(), alice, id); len(got) != 2 {
			t.Errorf("alice reads %v, want both messages", got)
		}
		if conv, _ := e.conv(id); conv.State != stateRequest || conv.RequestCount != 2 {
			t.Errorf("conversation = %+v, want REQUEST with count 2", conv)
		}
	})
	t.Run("accepted conversation, deleted from the Inbox", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		e.must(alice, toUser(skey(1), bob, "old 1"))
		e.tick(time.Second)
		e.must(bob, toUser(skey(2), alice, "old 2"))
		id := ConversationID(alice, bob)
		e.tick(time.Minute)
		c, err := e.del(e.newService(), bob, id)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "DeleteConversation inbox", c, budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1})
		if _, ok := e.entry(bob, dmInboxCollection, id); ok {
			t.Fatal("bob's inbox entry survived")
		}
		if _, ok := e.entry(alice, dmInboxCollection, id); !ok {
			t.Fatal("alice's entry was removed by bob's delete")
		}
		e.tick(time.Minute)
		e.must(alice, toUser(skey(3), bob, "new 1"))
		ent, ok := e.entry(bob, dmInboxCollection, id)
		if !ok || ent.UnreadCount != 1 || ent.Last.Snippet != "new 1" {
			t.Errorf("bob's recreated inbox entry = %+v %v", ent, ok)
		}
		if got := e.threadTexts(e.newService(), bob, id); len(got) != 1 || got[0] != "new 1" {
			t.Errorf("bob reads %v, want only new 1", got)
		}
		// The sender deleting and sending again sees only newer messages too.
		e.tick(time.Minute)
		if _, err := e.del(e.newService(), alice, id); err != nil {
			t.Fatal(err)
		}
		e.tick(time.Minute)
		e.must(alice, toUser(skey(4), bob, "new 2"))
		if got := e.threadTexts(e.newService(), alice, id); len(got) != 1 || got[0] != "new 2" {
			t.Errorf("alice reads %v, want only new 2", got)
		}
		if got := e.threadTexts(e.newService(), bob, id); len(got) != 2 {
			t.Errorf("bob reads %v, want new 1 and new 2", got)
		}
	})
}

// Given a non-participant or an unknown id, then NOT_FOUND with the bytes of Accept's, after 2 reads, with nothing written
// and no clearedAt created.
func TestDelete_NotFoundOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	e.addUser(carol, "carol", false)
	unknown := ConversationID(alice, "uid-nobody")
	cNon, errNon := e.del(e.newService(), carol, id)
	cUnk, errUnk := e.del(e.newService(), carol, unknown)
	_, errAcc := e.accept(e.newService(), alice, id)
	for name, err := range map[string]error{"non-participant": errNon, "unknown": errUnk, "accept by the requester": errAcc} {
		if codeOf(err) != connect.CodeNotFound {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
	}
	if !bytes.Equal(wireBytes(t, errNon), wireBytes(t, errUnk)) || !bytes.Equal(wireBytes(t, errNon), wireBytes(t, errAcc)) {
		t.Error("NOT_FOUND bytes differ")
	}
	for name, c := range map[string]*budget.Counter{"non-participant": cNon, "unknown": cUnk} {
		budgettest.Assert(t, "DeleteConversation NOT_FOUND "+name, c, budgettest.Budget{Reads: 2})
		if c.Writes() != 0 || c.Deletes() != 0 {
			t.Errorf("%s: writes/deletes = %d/%d", name, c.Writes(), c.Deletes())
		}
	}
	if conv, _ := e.conv(id); len(conv.ClearedAt) != 0 {
		t.Errorf("clearedAt = %v, want none", conv.ClearedAt)
	}
	if _, ok := e.conv(unknown); ok {
		t.Error("an unknown id created a conversation")
	}
	// Malformed: VALIDATION with only the interceptor's read.
	cBad, errBad := e.del(e.newService(), bob, "nope")
	if codeOf(errBad) != connect.CodeInvalidArgument || cBad.Reads() != 1 {
		t.Errorf("malformed id: err = %v reads = %d", errBad, cBad.Reads())
	}
}

// Given clearedAt set on this instance, then it takes effect at once here (the conversation cache is replaced), while another
// instance with the conversation cached converges within the cache TTL (D14).
func TestDelete_ClearedAtCacheOnThisAndOtherInstances(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(alice, toUser(skey(1), bob, "one"))
	id := ConversationID(alice, bob)
	here, other := e.newService(), e.newService()
	for _, svc := range []*service{here, other} {
		if got := e.threadTexts(svc, bob, id); len(got) != 1 { // both cache the conversation
			t.Fatalf("setup: %v", got)
		}
	}
	e.tick(time.Minute)
	if _, err := e.del(here, bob, id); err != nil {
		t.Fatal(err)
	}
	if got := e.threadTexts(here, bob, id); len(got) != 0 {
		t.Errorf("the deleting instance still shows %v", got)
	}
	if got := e.threadTexts(other, bob, id); len(got) != 1 {
		t.Errorf("another instance within the TTL shows %v, want the stale 1 (converges within 60 s)", got)
	}
	other.convs.Delete(id) // what the 60 s TTL does
	if got := e.threadTexts(other, bob, id); len(got) != 0 {
		t.Errorf("another instance after the TTL shows %v", got)
	}
}

// Accept and Delete racing for the same request: whichever order Firestore serialises them in, bob ends with no entry in
// either folder (never one in both, never a resurrected one), clearedAt set, and a state consistent with who won.
func TestAcceptVsDelete_Race(t *testing.T) {
	for i := range 3 {
		t.Run(fmt.Sprintf("round %d", i), func(t *testing.T) {
			e := newIT(t, nil)
			id := e.request(1)
			e.tick(time.Minute)
			var wg sync.WaitGroup
			var accErr, delErr error
			svcA, svcD := e.newService(), e.newService()
			wg.Add(2)
			go func() { defer wg.Done(); _, accErr = e.accept(svcA, bob, id) }()
			go func() { defer wg.Done(); _, delErr = e.del(svcD, bob, id) }()
			wg.Wait()
			if delErr != nil {
				t.Fatalf("delete: %v", delErr)
			}
			if accErr != nil && codeOf(accErr) != connect.CodeNotFound {
				t.Fatalf("accept: %v, want success or NOT_FOUND", accErr)
			}
			for _, folder := range []string{dmInboxCollection, dmRequestsCollection} {
				if _, ok := e.entry(bob, folder, id); ok {
					t.Errorf("bob has a %s entry after both calls (accept err = %v)", folder, accErr)
				}
			}
			conv, _ := e.conv(id)
			if conv.ClearedAt[bob].IsZero() {
				t.Error("clearedAt[bob] not set")
			}
			wantState := stateAccepted
			if accErr != nil {
				wantState = stateRequest
			}
			if conv.State != wantState {
				t.Errorf("state = %q with accept err %v, want %q", conv.State, accErr, wantState)
			}
		})
	}
}

// Accept racing with the requester's next message must never lose the message or leave two entries.
func TestAcceptVsSend_Race(t *testing.T) {
	for i := range 2 {
		t.Run(fmt.Sprintf("round %d", i), func(t *testing.T) {
			e := newIT(t, nil)
			id := e.request(1)
			e.tick(time.Minute)
			var wg sync.WaitGroup
			var accErr, sendErr error
			svcA := e.newService()
			wg.Add(2)
			go func() { defer wg.Done(); _, accErr = e.accept(svcA, bob, id) }()
			go func() {
				defer wg.Done()
				_, _, sendErr = e.sendOn(e.newService(), alice, toUser(skey(500), bob, "racing"))
			}()
			wg.Wait()
			if accErr != nil || sendErr != nil {
				t.Fatalf("accept = %v, send = %v", accErr, sendErr)
			}
			_, inReq := e.entry(bob, dmRequestsCollection, id)
			in, inInbox := e.entry(bob, dmInboxCollection, id)
			if inReq == inInbox {
				t.Fatalf("bob's entry is in requests=%v inbox=%v, want exactly one place", inReq, inInbox)
			}
			if inInbox && in.UnreadCount != 2 {
				t.Errorf("inbox unreadCount = %d, want 2 (the request and the racing message)", in.UnreadCount)
			}
			if conv, _ := e.conv(id); conv.State != stateAccepted {
				t.Errorf("state = %q, want ACCEPTED", conv.State)
			}
			if len(e.msgs(id)) != 2 {
				t.Errorf("messages = %d, want 2", len(e.msgs(id)))
			}
		})
	}
}
