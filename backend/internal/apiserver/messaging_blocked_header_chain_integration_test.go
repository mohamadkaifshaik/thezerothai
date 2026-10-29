//go:build integration

package apiserver

import (
	"fmt"
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// W7-27 and W7-30 over the real chain and the real graph snapshot: a caller whose peer blocked them opens the thread for exactly
// the reads of an unblocked caller (25 at page 20: interceptor, conversation, 20 messages, peer, graph, own entry), with the
// header's unread_count from their own entry, can_reply false, and a peer that is a real snapshot (the frozen one).
func TestMessagingChain_BlockedCallerFirstPageCostsTheSame(t *testing.T) {
	setup := newDMChain(t, nil)
	me, friend := setup.user(t), setup.user(t)
	setup.mutual(t, me, friend)
	for i := range 25 {
		setup.mustSend(t, friend, me, fmt.Sprintf("m%d", i))
	}
	open := func(label string) *messagingv1.Conversation {
		t.Helper()
		e := newDMChain(t, nil) // a cold instance: no cache is warm
		r, err := e.listMsgs(me, &messagingv1.ListMessagesRequest{ConversationId: convID(me, friend), PageSize: 20})
		if err != nil || len(r.GetMessages()) != 20 || r.GetConversation() == nil {
			t.Fatalf("%s: messages = %d, conversation %v, err = %v", label, len(r.GetMessages()), r.GetConversation(), err)
		}
		budgettest.Assert(t, label, e.lineBudget(t, rpcListMessages), budgettest.Budget{Reads: 25})
		if got := e.lineBudget(t, rpcListMessages).Reads(); got != 25 {
			t.Errorf("%s: reads = %d, want exactly 25", label, got)
		}
		return r.GetConversation()
	}

	before := open("first page, not blocked")
	if before.GetUnreadCount() != 25 || !before.GetCanReply() {
		t.Fatalf("unblocked header = %+v, want unread 25 and can_reply", before)
	}
	setup.block(t, friend, me)
	after := open("first page, blocked by the peer")
	if after.GetUnreadCount() != 25 || after.GetCanReply() {
		t.Errorf("blocked header = %+v, want unread 25 from the own entry and can_reply false", after)
	}
	if after.GetPeer().GetUserId() != friend.uid || after.GetPeer().GetHandle() == "" || after.GetPeer().GetHandle() != before.GetPeer().GetHandle() {
		t.Errorf("blocked peer = %+v, want the frozen snapshot (same as before the block: %+v)", after.GetPeer(), before.GetPeer())
	}
}
