//go:build integration

package apiserver

// W7-20 (ADR-0027): the read side of messaging, the caps and the block/overflow matrix over the real Build chain on the
// emulators. The package-level tests in internal/messaging run the service behind fake graph and directory seams and
// without the interceptors, so they cannot see the interceptor's read, the graph snapshot reads or the rate limiters.
// This file measures ListConversations, ListMessages and MarkConversationRead with budgettest on the logged fs_reads /
// fs_writes of the request line against the ceilings of the proto doc comments, compares NOT_FOUND bytes on the wire,
// walks the flag classes of the read RPCs (F6), and covers DEGRADED_MODE=readonly, the send and read caps, and the
// suspended, muted and blockedByOverflow cases. A chain that measures is booted AFTER the data is written, so nothing is
// warm (a cold instance).

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

const (
	rpcListConversations = "/dzeroth.messaging.v1.MessagingService/ListConversations"
	rpcListMessages      = "/dzeroth.messaging.v1.MessagingService/ListMessages"
)

func (e *dmChain) listConvs(who dmUser, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, error) {
	r, err := e.msg.ListConversations(context.Background(), authed(who.token, req))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *dmChain) listMsgs(who dmUser, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, error) {
	r, err := e.msg.ListMessages(context.Background(), authed(who.token, req))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

func (e *dmChain) markRead(who dmUser, convID string) error {
	_, err := e.msg.MarkConversationRead(context.Background(), authed(who.token, &messagingv1.MarkConversationReadRequest{
		IdempotencyKey: contractKey("dm-read"), ConversationId: convID,
	}))
	return err
}

func (e *dmChain) unread(t *testing.T, owner, peer dmUser) int64 {
	t.Helper()
	ent, ok := e.entry(t, owner, peer, "dmInbox")
	if !ok {
		t.Fatalf("no dmInbox entry for the pair")
	}
	n, _ := ent["unreadCount"].(int64)
	return n
}

// convID is the deterministic conversation id of a pair.
func convID(a, b dmUser) string { return messaging.ConversationID(a.uid, b.uid) }

// Budget table of the read RPCs through the whole chain on a cold instance, against the proto doc comments:
// ListConversations first INBOX page of n rows 3+n reads (interceptor, caller graph, query rows, request count()), REQUESTS
// 2+n, a since refresh 3 worst; ListMessages first page 4+n (interceptor, conversation, caller graph, peer, rows), a poll 3 +
// 1 per new message; MarkConversationRead 1 read (the interceptor's) and 1 write, 0 writes for a missing entry.
func TestMessagingChain_ReadBudgetTable(t *testing.T) {
	setup := newDMChain(t, nil)
	me := setup.user(t)
	const peers, requests = 20, 3
	for range peers {
		p := setup.user(t)
		setup.mutual(t, me, p)
		setup.mustSend(t, p, me, "inbox row")
	}
	for range requests {
		q := setup.user(t)
		setup.mustSend(t, q, me, "may I?")
	}
	heavy := setup.user(t)
	setup.mutual(t, me, heavy)
	for i := range 55 {
		setup.mustSend(t, heavy, me, fmt.Sprintf("thread %d", i))
	}
	calm := setup.user(t) // one message, so a poll of this thread has only the settle-window message to re-deliver
	setup.mutual(t, me, calm)
	setup.mustSend(t, calm, me, "calm")
	// Tokens from a first look at the data, taken once the newest write is past the 5 s settle window (so a refresh with them
	// finds nothing to re-deliver); sealed with an instance-independent cursor key, so a cold chain accepts them.
	time.Sleep(6 * time.Second)
	firstPage, err := setup.listConvs(me, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 20})
	if err != nil {
		t.Fatal(err)
	}
	if len(firstPage.GetConversations()) != 20 || firstPage.GetNextPageToken() == "" || firstPage.GetSinceToken() == "" {
		t.Fatalf("setup: first page = %d rows, next %q since %q", len(firstPage.GetConversations()), firstPage.GetNextPageToken(), firstPage.GetSinceToken())
	}
	thread, err := setup.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, heavy)})
	if err != nil {
		t.Fatal(err)
	}
	if len(thread.GetMessages()) != 20 || thread.GetSinceToken() == "" {
		t.Fatalf("setup: thread page = %d messages, since %q", len(thread.GetMessages()), thread.GetSinceToken())
	}
	calmThread, err := setup.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, calm)})
	if err != nil || len(calmThread.GetMessages()) != 1 {
		t.Fatalf("setup: calm thread = %v, %v", calmThread, err)
	}

	measure := func(label, rpc string, ceil budgettest.Budget, run func(e *dmChain)) {
		t.Helper()
		e := newDMChain(t, nil) // a cold instance: no cache is warm
		run(e)
		got := e.lineBudget(t, rpc)
		budgettest.Assert(t, label, got, ceil)
		t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d ceil_reads=%d ceil_writes=%d", label, got.Reads(), got.Writes(), got.Deletes(), ceil.Reads, ceil.Writes)
	}
	measure("ListConversations INBOX first page of 20, cold", rpcListConversations, budgettest.Budget{Reads: 23}, func(e *dmChain) {
		r, err := e.listConvs(me, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 20})
		if err != nil || len(r.GetConversations()) != 20 {
			t.Fatalf("rows = %d, err = %v", len(r.GetConversations()), err)
		}
		if r.GetRequestCount() != requests {
			t.Errorf("request_count = %d, want %d", r.GetRequestCount(), requests)
		}
	})
	measure("ListConversations INBOX older page (2 rows), cold", rpcListConversations, budgettest.Budget{Reads: 2 + 2}, func(e *dmChain) {
		r, err := e.listConvs(me, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 20, PageToken: firstPage.GetNextPageToken()})
		if err != nil || len(r.GetConversations()) != 2 {
			t.Fatalf("rows = %d, err = %v", len(r.GetConversations()), err)
		}
	})
	measure("ListConversations REQUESTS (3 rows), cold", rpcListConversations, budgettest.Budget{Reads: 2 + requests}, func(e *dmChain) {
		r, err := e.listConvs(me, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_REQUESTS})
		if err != nil || len(r.GetConversations()) != requests {
			t.Fatalf("rows = %d, err = %v", len(r.GetConversations()), err)
		}
	})
	measure("ListConversations since, nothing new, cold", rpcListConversations, budgettest.Budget{Reads: 3}, func(e *dmChain) {
		r, err := e.listConvs(me, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: firstPage.GetSinceToken()})
		if err != nil || len(r.GetConversations()) != 0 {
			t.Fatalf("rows = %d, err = %v", len(r.GetConversations()), err)
		}
	})
	measure("ListMessages first page of 20, cold", rpcListMessages, budgettest.Budget{Reads: 24}, func(e *dmChain) {
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, heavy), PageSize: 20})
		if err != nil || len(r.GetMessages()) != 20 || r.GetConversation() == nil {
			t.Fatalf("messages = %d, conversation %v, err = %v", len(r.GetMessages()), r.GetConversation(), err)
		}
	})
	measure("ListMessages first page of 50, cold", rpcListMessages, budgettest.Budget{Reads: 54}, func(e *dmChain) {
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, heavy), PageSize: 50})
		if err != nil || len(r.GetMessages()) != 50 {
			t.Fatalf("messages = %d, err = %v", len(r.GetMessages()), err)
		}
	})
	measure("ListMessages older page of 20, cold", rpcListMessages, budgettest.Budget{Reads: 24}, func(e *dmChain) {
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, heavy), PageSize: 20, PageToken: thread.GetNextPageToken()})
		if err != nil || len(r.GetMessages()) != 20 {
			t.Fatalf("messages = %d, err = %v", len(r.GetMessages()), err)
		}
	})
	measure("ListMessages poll, 0 new, cold", rpcListMessages, budgettest.Budget{Reads: 3}, func(e *dmChain) {
		// The token trails the newest message by the 5 s settle window, so the one message already seen comes back (the client
		// dedupes by id); it is the query's minimum read, so the poll still costs 3.
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, calm), SinceToken: calmThread.GetSinceToken()})
		if err != nil || len(r.GetMessages()) > 1 || r.GetConversation() != nil || r.GetSinceToken() == "" {
			t.Fatalf("poll = %d messages, conversation %v, err = %v", len(r.GetMessages()), r.GetConversation(), err)
		}
	})
	setup.mustSend(t, calm, me, "one new")
	measure("ListMessages poll, 1 new, cold", rpcListMessages, budgettest.Budget{Reads: 3 + 1}, func(e *dmChain) {
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, calm), SinceToken: calmThread.GetSinceToken()})
		if err != nil || len(r.GetMessages()) < 1 || len(r.GetMessages()) > 2 || r.GetMessages()[0].GetText() != "one new" {
			t.Fatalf("poll = %v, err = %v", r.GetMessages(), err)
		}
	})
	measure("MarkConversationRead, cold", rpcMarkRead, budgettest.Budget{Reads: 1, Writes: 1}, func(e *dmChain) {
		if err := e.markRead(me, convID(me, heavy)); err != nil {
			t.Fatal(err)
		}
	})
	if n := setup.unread(t, me, heavy); n != 0 {
		t.Errorf("unreadCount after MarkConversationRead = %d, want 0", n)
	}
	measure("MarkConversationRead, no entry, cold", rpcMarkRead, budgettest.Budget{Reads: 1, Writes: 0}, func(e *dmChain) {
		if err := e.markRead(me, convID(me, setup.user(t))); err != nil {
			t.Fatal(err)
		}
	})
}

// A non-participant, an unknown id and a well-formed id nobody derives all answer ListMessages with the same NOT_FOUND
// bytes, after at most 2 reads. A malformed id is VALIDATION. SendMessage by conversation_id answers the same bytes for
// the same three causes. Foreign and tampered tokens are VALIDATION after the
// interceptor's one read alone. MarkConversationRead on a conversation that is not the caller's is a success that writes
// nothing and touches nobody else's entry.
func TestMessagingChain_ReadAuthzIsByteIdentical(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b, mallory := setup.user(t), setup.user(t), setup.user(t)
	setup.mutual(t, a, b)
	for i := range 3 {
		setup.mustSend(t, a, b, fmt.Sprintf("secret %d", i))
	}
	real := convID(a, b)
	unknown := messaging.ConversationID(mallory.uid, "uid-nobody-at-all")
	wellFormed := "00000000000000000000000000000000" // 32 lower-hex that no pair of users derives
	pageOne, err := setup.listMsgs(b, &messagingv1.ListMessagesRequest{ConversationId: real, PageSize: 1})
	if err != nil || pageOne.GetNextPageToken() == "" || pageOne.GetSinceToken() == "" {
		t.Fatalf("setup: %v %v", pageOne, err)
	}
	listA, err := setup.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 1})
	if err != nil {
		t.Fatal(err)
	}

	e := newDMChain(t, nil)
	var first string
	for i, tc := range []struct {
		name string
		id   string
	}{
		{"a non-participant guessing a real id", real},
		{"an unknown id", unknown},
		{"a well-formed id nobody derives", wellFormed},
	} {
		_, err := e.listMsgs(mallory, &messagingv1.ListMessagesRequest{ConversationId: tc.id})
		wireError(t, err, connect.CodeNotFound)
		got := wireBytes(t, err)
		if i == 0 {
			first = got
		} else if got != first {
			t.Errorf("%s: ListMessages bytes differ from the first refusal:\n got  %q\n want %q", tc.name, got, first)
		}
		budgettest.Assert(t, "ListMessages NOT_FOUND: "+tc.name, e.lineBudget(t, rpcListMessages), budgettest.Budget{Reads: 2})

		// SendMessage by conversation_id answers the same thing for the same causes (the one NOT_FOUND of the send path).
		_, serr := e.msg.SendMessage(context.Background(), authed(mallory.token, &messagingv1.SendMessageRequest{
			IdempotencyKey: contractKey("dm"), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: tc.id}, Text: "let me in",
		}))
		wireError(t, serr, connect.CodeNotFound)
		if sb := wireBytes(t, serr); sb != first {
			t.Errorf("%s: SendMessage bytes differ from ListMessages' NOT_FOUND:\n got  %q\n want %q", tc.name, sb, first)
		}
		budgettest.Assert(t, "SendMessage by conversation_id NOT_FOUND: "+tc.name, e.lineBudget(t, rpcSendMessage), budgettest.Budget{Reads: 2})
	}
	if n := setup.messageCount(t, a, b); n != 3 {
		t.Errorf("a refused send stored a message: %d messages", n)
	}

	_, err = e.listMsgs(mallory, &messagingv1.ListMessagesRequest{ConversationId: "NOT-A-VALID-ID"})
	d := wireError(t, err, connect.CodeInvalidArgument)
	if d.GetMetadata()["field"] != "conversation_id" {
		t.Errorf("malformed id: field = %q", d.GetMetadata()["field"])
	}
	budgettest.Assert(t, "ListMessages malformed id", e.lineBudget(t, rpcListMessages), budgettest.Budget{Reads: 1})

	flip := func(s string) string { b := []byte(s); b[len(b)/2] ^= 1; return string(b) }
	tokens := []struct {
		name  string
		field string
		run   func() error
	}{
		{"ListMessages: b's page token used by a (a participant, but not the token's owner)", "page_token", func() error {
			_, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: real, PageToken: pageOne.GetNextPageToken()})
			return err
		}},
		{"ListMessages: b's since token used by a", "since_token", func() error {
			_, err := e.listMsgs(a, &messagingv1.ListMessagesRequest{ConversationId: real, SinceToken: pageOne.GetSinceToken()})
			return err
		}},
		{"ListMessages: tampered page token", "page_token", func() error {
			_, err := e.listMsgs(b, &messagingv1.ListMessagesRequest{ConversationId: real, PageToken: flip(pageOne.GetNextPageToken())})
			return err
		}},
		{"ListMessages: tampered since token", "since_token", func() error {
			_, err := e.listMsgs(b, &messagingv1.ListMessagesRequest{ConversationId: real, SinceToken: flip(pageOne.GetSinceToken())})
			return err
		}},
		{"ListConversations: a's since token used by b", "since_token", func() error {
			_, err := e.listConvs(b, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, SinceToken: listA.GetSinceToken()})
			return err
		}},
		{"ListConversations: a's page token on the other folder", "page_token", func() error {
			_, err := e.listConvs(a, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_REQUESTS, PageToken: listA.GetNextPageToken()})
			return err
		}},
	}
	for _, tc := range tokens {
		rpc := rpcListMessages
		if strings.HasPrefix(tc.name, "ListConversations") {
			rpc = rpcListConversations
		}
		d := wireError(t, tc.run(), connect.CodeInvalidArgument)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if d.GetMetadata()["field"] != tc.field {
			t.Errorf("%s: field = %q, want %q", tc.name, d.GetMetadata()["field"], tc.field)
		}
		budgettest.Assert(t, tc.name, e.lineBudget(t, rpc), budgettest.Budget{Reads: 1})
	}

	// MarkConversationRead: someone else's conversation is a quiet success that changes nothing of theirs.
	before := setup.unread(t, b, a)
	if err := e.markRead(mallory, real); err != nil {
		t.Fatalf("MarkConversationRead of a foreign conversation: %v", err)
	}
	budgettest.Assert(t, "MarkConversationRead foreign", e.lineBudget(t, rpcMarkRead), budgettest.Budget{Reads: 1, Writes: 0})
	if err := e.markRead(mallory, unknown); err != nil {
		t.Fatalf("MarkConversationRead of an unknown conversation: %v", err)
	}
	budgettest.Assert(t, "MarkConversationRead unknown", e.lineBudget(t, rpcMarkRead), budgettest.Budget{Reads: 1, Writes: 0})
	if _, ok := e.entry(t, mallory, a, "dmInbox"); ok {
		t.Error("MarkConversationRead created an entry for a non-participant")
	}
	if after := setup.unread(t, b, a); after != before {
		t.Errorf("b's unreadCount changed %d -> %d", before, after)
	}
}
