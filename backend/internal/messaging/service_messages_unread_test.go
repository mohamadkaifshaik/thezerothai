package messaging

import (
	"bytes"
	"context"
	"errors"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// putEntry stores an entry of uid in a folder collection (dmInbox or dmRequests) of the rig's fake repo.
func (r *rig) putEntry(uid, collection string, e EntryDoc) {
	if r.repo.entries == nil {
		r.repo.entries = map[string][]EntryRow{}
	}
	r.repo.entries[entryKey(uid, collection)] = append(r.repo.entries[entryKey(uid, collection)], EntryRow{ID: aliceBobConv, EntryDoc: e})
}

// W7-27: a first page carries the caller's own unread_count and silent, from dmInbox, or dmRequests for the recipient of an
// unaccepted request; a missing entry is 0 / false. One entry read on a first page, resolved from the conversation.
func TestListMessages_FirstPageUnreadCount(t *testing.T) {
	request := func(c *ConvDoc) { c.State, c.RequestFrom, c.RequestTo = stateRequest, alice, bob }
	tests := []struct {
		name       string
		conv       func(*ConvDoc)
		uid        string
		collection string // where the entry is stored ("" = none)
		entry      EntryDoc
		wantFolder string
		wantUnread int64
		wantSilent bool
	}{
		{"3 unread in the inbox", nil, alice, dmInboxCollection, EntryDoc{UnreadCount: 3}, entryInbox, 3, false},
		{"silent is mapped", nil, alice, dmInboxCollection, EntryDoc{UnreadCount: 1, Silent: true}, entryInbox, 1, true},
		{"read entry is 0", nil, alice, dmInboxCollection, EntryDoc{}, entryInbox, 0, false},
		{"missing entry (delete for me) is 0", nil, alice, "", EntryDoc{}, entryInbox, 0, false},
		{"recipient of a request reads dmRequests", request, bob, dmRequestsCollection, EntryDoc{UnreadCount: 2}, entryRequests, 2, false},
		{"requester reads dmInbox", request, alice, dmInboxCollection, EntryDoc{UnreadCount: 4}, entryInbox, 4, false},
		{"request recipient, entry only in dmInbox (stale copy) is 0", request, bob, dmInboxCollection, EntryDoc{UnreadCount: 9}, entryRequests, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, nil)
			rg.putThread(2, tt.conv)
			if tt.collection != "" {
				rg.putEntry(tt.uid, tt.collection, tt.entry)
			}
			resp := rg.listMsgs(t, tt.uid, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			c := resp.Conversation
			if c == nil || c.UnreadCount != tt.wantUnread || c.Silent != tt.wantSilent {
				t.Fatalf("conversation = %+v, want unread_count %d silent %v", c, tt.wantUnread, tt.wantSilent)
			}
			if want := []string{tt.uid + "|" + tt.wantFolder + "|" + aliceBobConv}; !slices.Equal(rg.repo.entryGets, want) {
				t.Errorf("entry reads = %v, want exactly %v (one read, the folder from the conversation)", rg.repo.entryGets, want)
			}
		})
	}
}

// Given 3 unread and a conversation of 45 messages, then only the first page carries the count: an older page and a since
// refresh leave unread_count unset and read no entry.
func TestListMessages_UnreadOnlyOnTheFirstPage(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(45, nil)
	rg.putEntry(alice, dmInboxCollection, EntryDoc{UnreadCount: 3, Silent: true})
	first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if first.Conversation.UnreadCount != 3 || len(rg.repo.entryGets) != 1 {
		t.Fatalf("first page: unread %d, entry reads %d", first.Conversation.UnreadCount, len(rg.repo.entryGets))
	}
	older := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: first.NextPageToken})
	if older.Conversation == nil || older.Conversation.UnreadCount != 0 || older.Conversation.Silent {
		t.Errorf("older page conversation = %+v, want unread_count 0 and silent false", older.Conversation)
	}
	since := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken})
	if since.Conversation != nil {
		t.Errorf("since refresh conversation = %+v, want none", since.Conversation)
	}
	if len(rg.repo.entryGets) != 1 {
		t.Errorf("entry reads = %d after an older page and a since refresh, want still 1", len(rg.repo.entryGets))
	}
}

// The entry read comes after the participant check: a non-participant and an unknown id read no entry and get the same bytes.
func TestListMessages_NotFoundReadsNoEntry(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(1, nil)
	rg.putEntry(alice, dmInboxCollection, EntryDoc{UnreadCount: 3})
	_, a := rg.svc.ListMessages(context.Background(), "uid-mallory", &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	_, b := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: ConversationID(alice, "uid-carol")})
	wantAPI(t, a, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
	if !bytes.Equal(wireBytes(t, a), wireBytes(t, b)) {
		t.Errorf("bytes differ:\n %q\n %q", wireBytes(t, a), wireBytes(t, b))
	}
	if len(rg.repo.entryGets) != 0 {
		t.Errorf("entry reads = %v, want none for a refused call", rg.repo.entryGets)
	}
}

// An entry read error fails the call like any other repo error (no partial thread).
func TestListMessages_EntryReadError(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(1, nil)
	rg.repo.entryErr = errors.New("boom")
	if _, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); err == nil {
		t.Fatal("want an error")
	}
}

// W7-30 (security review M-2): when the peer blocked the caller (or BlockedBy overflowed), the header shows the peer snapshot
// frozen on the caller's own entry, never the live profile; an older page and a gone entry read "Deleted account".
func TestListMessages_BlockedPeerIsFrozen(t *testing.T) {
	frozenPeer := PeerDoc{Handle: "bob_old", DisplayName: "Bob Old", AvatarThumbURL: "https://img/old.jpg", Verified: true}
	blockedBy := func(r *rig) { r.social.snaps[alice] = graph.Snapshot{BlockedBy: map[string]bool{bob: true}} }
	overflow := func(r *rig) { r.social.snaps[alice] = graph.Snapshot{BlockedByOverflow: true} }
	tests := []struct {
		name       string
		mut        func(*rig)
		withEntry  bool
		older      bool
		wantHandle string
		wantName   string
		wantFrozen bool
	}{
		{"first page, blocked by the peer", blockedBy, true, false, "bob_old", "Bob Old", true},
		{"first page, BlockedBy overflow", overflow, true, false, "bob_old", "Bob Old", true},
		{"first page, entry gone", blockedBy, false, false, "", DeletedAccountName, false},
		{"older page", blockedBy, true, true, "", DeletedAccountName, false},
		{"not blocked keeps the live profile", nil, true, false, "bob", "bob", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, tt.mut)
			rg.putThread(45, nil)
			if tt.withEntry {
				rg.putEntry(alice, dmInboxCollection, EntryDoc{PeerID: bob, Peer: frozenPeer, UnreadCount: 2})
			}
			req := &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}
			if tt.older {
				req.PageToken = rg.listMsgs(t, alice, req).NextPageToken
			}
			c := rg.listMsgs(t, alice, req).Conversation
			if c == nil || c.Peer.Handle != tt.wantHandle || !strings.Contains(c.Peer.DisplayName, tt.wantName) {
				t.Fatalf("peer = %+v, want handle %q name %q", c.GetPeer(), tt.wantHandle, tt.wantName)
			}
			if tt.wantFrozen && tt.name != "first page, BlockedBy overflow" && c.CanReply {
				t.Error("can_reply = true for a blocked-by caller")
			}
			if tt.wantFrozen && (c.Peer.AvatarUrl != frozenPeer.AvatarThumbURL || !c.Peer.Verified || c.Peer.UserId != bob || c.UnreadCount != 2) {
				t.Errorf("frozen snapshot = %+v unread %d", c.Peer, c.UnreadCount)
			}
		})
	}
}
