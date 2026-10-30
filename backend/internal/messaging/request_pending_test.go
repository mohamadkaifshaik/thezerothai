package messaging

import (
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// conversationOf maps the requestPending flag (ADR-0027 note W7-25) to REQUEST in the INBOX; nothing else changes.
func TestConversationOf_RequestPending(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		folder     string
		pending    bool
		wantState  messagingv1.ConversationState
		wantFolder messagingv1.Folder
	}{
		{"inbox, no flag (accepted, mutual path, legacy entry)", dmInboxCollection, false, messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, messagingv1.Folder_FOLDER_INBOX},
		{"inbox, requester's pending request", dmInboxCollection, true, messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.Folder_FOLDER_INBOX},
		{"requests row", dmRequestsCollection, false, messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.Folder_FOLDER_REQUESTS},
		{"requests row ignores a stray flag", dmRequestsCollection, true, messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.Folder_FOLDER_REQUESTS},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			row := EntryRow{ID: ConversationID(alice, bob), EntryDoc: EntryDoc{PeerID: bob, RequestPending: tt.pending}}
			c := conversationOf(row, tt.folder, graph.Snapshot{})
			if c.State != tt.wantState || c.Folder != tt.wantFolder {
				t.Errorf("state/folder = %v/%v, want %v/%v", c.State, c.Folder, tt.wantState, tt.wantFolder)
			}
		})
	}
}
