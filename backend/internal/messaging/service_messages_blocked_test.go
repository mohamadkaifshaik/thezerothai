package messaging

import (
	"testing"

	"google.golang.org/protobuf/proto"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// W7-30 (security review M-2) and the W7-27 audit: when the peer blocked the caller (or BlockedBy overflowed), the header shows
// the peer snapshot frozen on the caller's own entry, never the live profile, whatever the directory says about the peer; the
// placeholder is the answer for an erased peer, an entry that is gone or names someone else, and an older page. Peers are
// compared as whole snapshots, so a stray uid, avatar or verified flag fails.
func TestListMessages_BlockedPeerIsFrozen(t *testing.T) {
	frozenPeer := PeerDoc{Handle: "bob_old", DisplayName: "Bob Old", AvatarThumbURL: "https://img/old.jpg", Verified: true}
	frozen := &commonv1.AuthorSnapshot{UserId: bob, Handle: "bob_old", DisplayName: "Bob Old", AvatarUrl: "https://img/old.jpg", Verified: true}
	placeholder := &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
	live := &commonv1.AuthorSnapshot{UserId: bob, Handle: "bob", DisplayName: "Name bob", AvatarUrl: "https://img/bob"}

	blockedBy := func(r *rig) { r.social.snaps[alice] = graph.Snapshot{BlockedBy: map[string]bool{bob: true}} }
	overflow := func(r *rig) { r.social.snaps[alice] = graph.Snapshot{BlockedByOverflow: true} }
	absent := func(r *rig) { delete(r.profs.profiles, bob) }
	blockedAbsent := func(r *rig) { blockedBy(r); absent(r) }

	entry := func(peerID string) *EntryDoc { return &EntryDoc{PeerID: peerID, Peer: frozenPeer, UnreadCount: 2} }
	tests := []struct {
		name    string
		mut     func(*rig)
		entry   *EntryDoc // alice's dmInbox entry (nil = none)
		older   bool
		want    *commonv1.AuthorSnapshot
		canRepl bool
	}{
		{"first page, blocked by the peer", blockedBy, entry(bob), false, frozen, false},
		{"first page, BlockedBy overflow", overflow, entry(bob), false, frozen, false},
		{"blocked, peer absent from the directory, entry names the peer: still frozen", blockedAbsent, entry(bob), false, frozen, false},
		{"blocked, entry names the erased uid (MarkGone ran)", blockedBy, entry(DeletedUID), false, placeholder, false},
		{"blocked, entry names someone else", blockedBy, entry("uid-other"), false, placeholder, false},
		{"blocked, no entry", blockedBy, nil, false, placeholder, false},
		{"blocked, older page", blockedBy, entry(bob), true, placeholder, false},
		{"not blocked, not live: placeholder", absent, entry(bob), false, placeholder, false},
		{"not blocked keeps the live profile", nil, entry(bob), false, live, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, tt.mut)
			rg.putThread(45, nil)
			if tt.entry != nil {
				rg.putEntry(alice, dmInboxCollection, *tt.entry)
			}
			req := &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}
			if tt.older {
				req.PageToken = rg.listMsgs(t, alice, req).NextPageToken
			}
			c := rg.listMsgs(t, alice, req).Conversation
			if c == nil || !proto.Equal(c.Peer, tt.want) {
				t.Fatalf("peer = %v, want %v", c.GetPeer(), tt.want)
			}
			if c.CanReply != tt.canRepl {
				t.Errorf("can_reply = %v, want %v", c.CanReply, tt.canRepl)
			}
		})
	}
}

// Per-caller fields never cross between callers on one instance: alice's unread_count, silent and frozen peer stay hers,
// bob's first page after hers carries his own entry and the live profile of alice (he did not block her).
func TestListMessages_PerCallerFieldsDoNotCross(t *testing.T) {
	rg := newRig(t, func(r *rig) { r.social.snaps[alice] = graph.Snapshot{BlockedBy: map[string]bool{bob: true}} })
	rg.putThread(3, nil)
	rg.putEntry(alice, dmInboxCollection, EntryDoc{PeerID: bob, Peer: PeerDoc{Handle: "bob_old", DisplayName: "Bob Old"}, UnreadCount: 3, Silent: true})
	rg.putEntry(bob, dmInboxCollection, EntryDoc{PeerID: alice, Peer: PeerDoc{Handle: "alice_old", DisplayName: "Alice Old"}})
	req := &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}

	a1 := rg.listMsgs(t, alice, req).Conversation
	b := rg.listMsgs(t, bob, req).Conversation
	a2 := rg.listMsgs(t, alice, req).Conversation

	for i, a := range []*messagingv1.Conversation{a1, a2} {
		if a.UnreadCount != 3 || !a.Silent || a.Peer.Handle != "bob_old" || a.CanReply {
			t.Errorf("alice call %d = %+v, want unread 3 silent true, frozen bob_old, can_reply false", i, a)
		}
	}
	if b.UnreadCount != 0 || b.Silent || b.Peer.Handle != "alice" || !b.CanReply {
		t.Errorf("bob = %+v, want unread 0 silent false, the live alice, can_reply true", b)
	}
}
