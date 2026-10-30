//go:build integration

package messaging

import (
	"context"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// A DeleteConversation that commits between a send's clock read and its transaction must not hide the message the send
// recreates (W7-9 B2): the send stamps the message and the entries strictly after either participant's clearedAt, read in
// its own transaction (0 extra reads). The clock is fake and never ticks between the delete and the send, so the ordering
// does not depend on real concurrency: Now == clearedAt, Now < clearedAt (another instance's slower clock) and the control
// Now > clearedAt.
func TestDelete_ThenAnInFlightSend(t *testing.T) {
	for _, tc := range []struct {
		name  string
		shift time.Duration // the sender's clock relative to the delete's clearedAt
		want  time.Duration // the message's createdAt relative to clearedAt
	}{
		{"same instant", 0, time.Microsecond},
		{"a slower clock", -3 * time.Second, time.Microsecond},
		{"control, the clock moved on", time.Second, time.Second},
	} {
		t.Run("recipient deletes a request, "+tc.name, func(t *testing.T) {
			e := newIT(t, nil)
			id := e.request(2)
			e.tick(time.Minute)
			if _, err := e.del(e.newService(), bob, id); err != nil {
				t.Fatal(err)
			}
			cleared := e.now().Truncate(time.Microsecond)
			if conv, _ := e.conv(id); !conv.ClearedAt[bob].Equal(cleared) {
				t.Fatalf("clearedAt[bob] = %v, want %v", conv.ClearedAt[bob], cleared)
			}
			// The in-flight send: its handler read the clock before the delete committed.
			e.tick(tc.shift)
			resp, c, err := e.sendOn(e.newService(), alice, toUser(skey(600), bob, "in flight"))
			if err != nil {
				t.Fatal(err)
			}
			budgettest.Assert(t, "SendMessage after a delete", c, budgettest.Budget{Reads: 2, Writes: 4})
			stamp := cleared.Add(tc.want)
			if got := resp.GetMessage().GetCreatedAt().AsTime(); !got.Equal(stamp) {
				t.Errorf("message createdAt = %v, want %v", got, stamp)
			}
			ent, ok := e.entry(bob, dmRequestsCollection, id)
			if !ok || ent.UnreadCount != 1 || ent.Last.Snippet != "in flight" || !ent.LastMessageAt.Equal(stamp) {
				t.Fatalf("bob's recreated entry = %+v %v, want unread 1, the preview and lastMessageAt %v", ent, ok, stamp)
			}
			if got := e.threadTexts(e.newService(), bob, id); len(got) != 1 || got[0] != "in flight" {
				t.Errorf("bob reads %v, want exactly the in-flight message", got)
			}
			if got := e.threadTexts(e.newService(), alice, id); len(got) != 3 {
				t.Errorf("alice reads %v, want all three messages", got)
			}
			// A second delete clears the stamped message too: clearedAt is never before the entry's lastMessageAt.
			if _, err := e.del(e.newService(), bob, id); err != nil {
				t.Fatal(err)
			}
			if got := e.threadTexts(e.newService(), bob, id); len(got) != 0 {
				t.Errorf("after a second delete bob still reads %v", got)
			}
			if conv, _ := e.conv(id); conv.ClearedAt[bob].Before(stamp) {
				t.Errorf("clearedAt[bob] = %v is before the message %v", conv.ClearedAt[bob], stamp)
			}
		})
	}

	t.Run("sender deletes, then her own in-flight send lands", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		e.must(alice, toUser(skey(1), bob, "old 1"))
		e.tick(time.Second)
		e.must(bob, toUser(skey(2), alice, "old 2"))
		id := ConversationID(alice, bob)
		e.tick(time.Minute)
		if _, err := e.del(e.newService(), alice, id); err != nil {
			t.Fatal(err)
		}
		cleared := e.now().Truncate(time.Microsecond)
		e.tick(-2 * time.Second) // the send's handler read a slower clock
		resp, _, err := e.sendOn(e.newService(), alice, toUser(skey(3), bob, "mine, in flight"))
		if err != nil {
			t.Fatal(err)
		}
		if got := resp.GetMessage().GetCreatedAt().AsTime(); !got.Equal(cleared.Add(time.Microsecond)) {
			t.Errorf("message createdAt = %v, want clearedAt + 1 µs", got)
		}
		own, ok := e.entry(alice, dmInboxCollection, id)
		if !ok || own.Last.Snippet != "mine, in flight" || !own.LastMessageAt.Equal(cleared.Add(time.Microsecond)) {
			t.Fatalf("alice's recreated entry = %+v %v", own, ok)
		}
		if got := e.threadTexts(e.newService(), alice, id); len(got) != 1 || got[0] != "mine, in flight" {
			t.Errorf("alice reads %v, want exactly her in-flight message", got)
		}
		if got := e.threadTexts(e.newService(), bob, id); len(got) != 3 {
			t.Errorf("bob reads %v, want all three messages", got)
		}
	})

	t.Run("both cleared: the later clearedAt decides", func(t *testing.T) {
		e := newIT(t, nil)
		e.mutual(alice, bob)
		e.must(alice, toUser(skey(1), bob, "old"))
		id := ConversationID(alice, bob)
		e.tick(time.Minute)
		if _, err := e.del(e.newService(), alice, id); err != nil {
			t.Fatal(err)
		}
		e.tick(time.Second)
		if _, err := e.del(e.newService(), bob, id); err != nil {
			t.Fatal(err)
		}
		conv, _ := e.conv(id)
		later := conv.ClearedAt[bob]
		e.tick(-time.Hour)
		resp, _, err := e.sendOn(e.newService(), alice, toUser(skey(2), bob, "after both"))
		if err != nil {
			t.Fatal(err)
		}
		if got := resp.GetMessage().GetCreatedAt().AsTime(); !got.Equal(later.Add(time.Microsecond)) {
			t.Errorf("message createdAt = %v, want the later clearedAt + 1 µs (%v)", got, later.Add(time.Microsecond))
		}
		for _, uid := range []string{alice, bob} {
			if got := e.threadTexts(e.newService(), uid, id); len(got) != 1 || got[0] != "after both" {
				t.Errorf("%s reads %v, want exactly the new message", uid, got)
			}
		}
	})
}

// The stamp changes neither the message id nor the replay rules: the same key after a delete replays the stored message
// with its original createdAt (not moved after clearedAt), and a different body under the key is still VALIDATION.
func TestSend_ReplayAfterAPeerDeleteKeepsTheStoredStamp(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	first := e.must(alice, toUser(skey(1), bob, "once"))
	id := ConversationID(alice, bob)
	e.tick(time.Minute)
	if _, err := e.del(e.newService(), bob, id); err != nil {
		t.Fatal(err)
	}
	again, _, err := e.sendOn(e.newService(), alice, toUser(skey(1), bob, "once"))
	if err != nil {
		t.Fatal(err)
	}
	if again.GetMessage().GetId() != first.GetMessage().GetId() || !again.GetMessage().GetCreatedAt().AsTime().Equal(first.GetMessage().GetCreatedAt().AsTime()) {
		t.Errorf("replay = %v, want the stored message %v unchanged", again.GetMessage(), first.GetMessage())
	}
	if n := len(e.msgs(id)); n != 1 {
		t.Errorf("messages = %d, want 1", n)
	}
	if _, _, err := e.sendOn(e.newService(), alice, toUser(skey(1), bob, "another body")); codeOf(err) != connect.CodeInvalidArgument {
		t.Errorf("same key, other body: %v, want VALIDATION", err)
	}
}

// A malformed idempotency_key is VALIDATION idempotency_key after the interceptor's read alone, for Accept, Delete and MarkConversationRead, and nothing
// is read or written.
func TestAcceptDelete_MalformedKeyOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	id := e.request(1)
	for _, key := range []string{"", "short", "has spaces in the key!!", strings.Repeat("k", 65)} {
		for name, run := range map[string]func(ctx context.Context) error{
			"accept": func(ctx context.Context) error {
				_, err := e.svc.Accept(ctx, bob, &messagingv1.AcceptMessageRequestRequest{IdempotencyKey: key, ConversationId: id})
				return err
			},
			"delete": func(ctx context.Context) error {
				_, err := e.svc.Delete(ctx, bob, &messagingv1.DeleteConversationRequest{IdempotencyKey: key, ConversationId: id})
				return err
			},
			"mark read": func(ctx context.Context) error {
				_, err := e.svc.MarkRead(ctx, bob, &messagingv1.MarkConversationReadRequest{IdempotencyKey: key, ConversationId: id})
				return err
			},
		} {
			ctx, c := budget.WithCounter(verifiedCtx())
			c.AddReads(1)
			err := run(ctx)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
			if c.Reads() != 1 || c.Writes() != 0 || c.Deletes() != 0 {
				t.Errorf("%s with key %q: reads/writes/deletes = %d/%d/%d, want 1/0/0", name, key, c.Reads(), c.Writes(), c.Deletes())
			}
		}
	}
	if conv, _ := e.conv(id); conv.State != stateRequest || conv.ClearedAt != nil {
		t.Errorf("a refused call changed the conversation: %+v", conv)
	}
	if ent, ok := e.entry(bob, dmRequestsCollection, id); !ok || ent.UnreadCount != 1 {
		t.Errorf("bob's request entry = %+v %v, want it intact with its unread count (a refused mark read cleared nothing)", ent, ok)
	}
}
