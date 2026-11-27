//go:build integration

package messaging

import (
	"context"
	"fmt"
	"testing"

	"google.golang.org/protobuf/proto"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// GetConversations reads every existing conversation with one GetAll, leaves a missing id out, and refuses more than a
// page of ids before any read.
func TestGetConversations_Batch(t *testing.T) {
	e := newIT(t, nil)
	a := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "hi"})
	e.addUser(carol, "carol", false)
	r := e.seedConversation(alice, carol, stateRequest, base, [2]string{alice, "may I?"})
	missing := ConversationID(alice, "nobody")
	got, err := e.repo.GetConversations(context.Background(), []string{a, missing, r})
	if err != nil {
		t.Fatalf("GetConversations: %v", err)
	}
	if len(got) != 2 || got[a].State != stateAccepted || got[r].State != stateRequest || got[r].RequestTo != carol {
		t.Fatalf("got %+v, want the two seeded conversations", got)
	}
	if _, ok := got[missing]; ok {
		t.Error("a missing conversation is in the result")
	}
	if empty, err := e.repo.GetConversations(context.Background(), nil); err != nil || len(empty) != 0 {
		t.Errorf("no ids: %v, %v", empty, err)
	}
	tooMany := make([]string, MaxPageSize+1)
	for i := range tooMany {
		tooMany[i] = fmt.Sprintf("%032x", i)
	}
	if _, err := e.repo.GetConversations(context.Background(), tooMany); err == nil {
		t.Error("more than a page of ids must be refused")
	}
}

// listRowAndHeader is alice's list row for convID in folder and the header ListMessages returns for it, read by a cold
// instance each.
func (e *itEnv) listRowAndHeader(uid, convID string, folder messagingv1.Folder) (*messagingv1.Conversation, *messagingv1.Conversation) {
	e.t.Helper()
	var row *messagingv1.Conversation
	for _, c := range e.mustList(e.newService(), uid, &messagingv1.ListConversationsRequest{Folder: folder}).Conversations {
		if c.Id == convID {
			row = c
		}
	}
	if row == nil {
		e.t.Fatalf("%s is not listed in %v", convID, folder)
	}
	head := e.mustListMsgs(e.newService(), uid, &messagingv1.ListMessagesRequest{ConversationId: convID}).Conversation
	return row, head
}

func sameAsHeader(t *testing.T, row, head *messagingv1.Conversation) {
	t.Helper()
	if row.State != head.State || row.Folder != head.Folder || row.CanReply != head.CanReply || !proto.Equal(row.Peer, head.Peer) {
		t.Fatalf("list row and header differ:\n row:    state=%v folder=%v can_reply=%v peer=%+v\n header: state=%v folder=%v can_reply=%v peer=%+v",
			row.State, row.Folder, row.CanReply, row.Peer, head.State, head.Folder, head.CanReply, head.Peer)
	}
}

// L-A on the emulator with the real eraser: alice's request to carol, carol erased. MarkGone deleted requestPending from
// alice's entry, yet the conversation is still a REQUEST; the list row says what the header says.
func TestList_ErasedRequestRecipientMatchesHeader(t *testing.T) {
	e := newIT(t, nil)
	e.addUser(carol, "carol", false)
	convID := e.seedConversation(alice, carol, stateRequest, base, [2]string{alice, "may I?"})
	e.runEraserFor(carol)
	if ent, ok := e.entry(alice, dmInboxCollection, convID); !ok || ent.RequestPending || ent.PeerID != DeletedUID {
		t.Fatalf("precondition: alice's entry = %+v, %v (MarkGone should have run)", ent, ok)
	}
	row, head := e.listRowAndHeader(alice, convID, messagingv1.Folder_FOLDER_INBOX)
	sameAsHeader(t, row, head)
	if row.State != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || row.CanReply || row.Peer.GetDisplayName() != DeletedAccountName {
		t.Errorf("row = state %v can_reply %v peer %+v, want REQUEST, read-only, Deleted account", row.State, row.CanReply, row.Peer)
	}
	// An accepted conversation whose peer was erased stays ACCEPTED.
	e.addUser("uid-erin", "erin", false)
	acc := e.seedConversation(alice, "uid-erin", stateAccepted, base, [2]string{"uid-erin", "hi"})
	e.runEraserFor("uid-erin")
	row, head = e.listRowAndHeader(alice, acc, messagingv1.Folder_FOLDER_INBOX)
	sameAsHeader(t, row, head)
	if row.State != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED {
		t.Errorf("accepted erased-peer row state = %v, want ACCEPTED", row.State)
	}
}

// L-C on the emulator: a suspended or deleting peer is "Deleted account" and read-only in the list as in the header.
func TestList_InactivePeerMatchesHeader(t *testing.T) {
	for _, st := range []identity.AccountStatus{identity.AccountStatusSuspended, identity.AccountStatusDeleting} {
		t.Run(fmt.Sprint(st), func(t *testing.T) {
			e := newIT(t, nil)
			convID := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "hi"})
			e.profs.mu.Lock()
			p := e.profs.profiles[bob]
			p.Status = st
			e.profs.profiles[bob] = p
			e.profs.mu.Unlock()
			row, head := e.listRowAndHeader(alice, convID, messagingv1.Folder_FOLDER_INBOX)
			sameAsHeader(t, row, head)
			if row.CanReply || row.Peer.GetDisplayName() != DeletedAccountName || row.Peer.GetUserId() != "" {
				t.Errorf("row = can_reply %v peer %+v, want read-only Deleted account", row.CanReply, row.Peer)
			}
		})
	}
}
