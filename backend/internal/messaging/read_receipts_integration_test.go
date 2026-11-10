//go:build integration

package messaging

import (
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F3 on the emulator: the real FirestoreRepo stores readReceiptAt (MarkRead), and peer_read_at is derived from it.
// Needs no Pub/Sub.

func (e *itEnv) receiptsFlag(mode flags.Mode, allow ...string) {
	e.t.Helper()
	e.reg = receiptsReg(mode, allow...)
	e.svc = e.newService()
}

func (e *itEnv) setReceipts(uid string, on bool) {
	e.profs.mu.Lock()
	defer e.profs.mu.Unlock()
	p := e.profs.profiles[uid]
	p.ReadReceipts = on
	e.profs.profiles[uid] = p
}

func (e *itEnv) peerReadAt(svc *service, uid, convID string) bool {
	e.t.Helper()
	return e.mustListMsgs(svc, uid, &messagingv1.ListMessagesRequest{ConversationId: convID}).Conversation.GetPeerReadAt() != nil
}

// The 2x2 settings matrix: only both-on shows bob's read to alice; the stored receipt exists only for a reader who is on.
func TestReadReceipts_SettingsMatrix(t *testing.T) {
	for _, tt := range []struct {
		name           string
		aliceOn, bobOn bool
		want           bool
		bobStores      bool
	}{
		{"both on", true, true, true, true},
		{"alice off", false, true, false, true},
		{"bob off", true, false, false, false},
		{"both off", false, false, false, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.receiptsFlag(flags.On)
			e.setReceipts(alice, tt.aliceOn)
			e.setReceipts(bob, tt.bobOn)
			id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "hi"})
			if err := e.markRead(e.svc, bob, id); err != nil {
				t.Fatal(err)
			}
			ent, ok := e.entry(bob, dmInboxCollection, id)
			if !ok || ent.LastReadAt.IsZero() || ent.UnreadCount != 0 {
				t.Fatalf("bob's entry = %+v, %v: mark read must still clear unread and set lastReadAt", ent, ok)
			}
			if got := !ent.ReadReceiptAt.IsZero(); got != tt.bobStores {
				t.Errorf("readReceiptAt stored = %v, want %v", got, tt.bobStores)
			}
			if got := e.peerReadAt(e.msgSvc(), alice, id); got != tt.want {
				t.Errorf("alice sees peer_read_at = %v, want %v", got, tt.want)
			}
			// The reader's own page never carries the receipt of the peer who has not read.
			if e.peerReadAt(e.msgSvc(), bob, id) {
				t.Error("bob sees alice's receipt although alice never read")
			}
		})
	}
}

// Every flag mode: off and an allowlist missing either side hide the receipt and store none; on and an allowlist with both show it.
func TestReadReceipts_FlagModes(t *testing.T) {
	for _, tt := range []struct {
		name      string
		mode      flags.Mode
		allow     []string
		wantStore bool
		want      bool
	}{
		{"on", flags.On, nil, true, true},
		{"off", flags.Off, nil, false, false},
		{"allowlist both", flags.Allowlist, []string{alice, bob}, true, true},
		{"allowlist only alice", flags.Allowlist, []string{alice}, false, false},
		{"allowlist only bob", flags.Allowlist, []string{bob}, true, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.receiptsFlag(tt.mode, tt.allow...)
			e.setReceipts(alice, true)
			e.setReceipts(bob, true)
			id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "hi"})
			if err := e.markRead(e.svc, bob, id); err != nil {
				t.Fatal(err)
			}
			ent, _ := e.entry(bob, dmInboxCollection, id)
			if got := !ent.ReadReceiptAt.IsZero(); got != tt.wantStore {
				t.Errorf("readReceiptAt stored = %v, want %v", got, tt.wantStore)
			}
			if got := e.peerReadAt(e.msgSvc(), alice, id); got != tt.want {
				t.Errorf("peer_read_at = %v, want %v", got, tt.want)
			}
		})
	}
}

// Turning either setting off hides the receipt at once (the next first page), and turning it back on shows the stored
// receipt again: the field is not erased, only gated.
func TestReadReceipts_ToggleOffHidesAtOnce(t *testing.T) {
	for _, who := range []string{alice, bob} {
		t.Run("toggle "+who, func(t *testing.T) {
			e := newIT(t, nil)
			e.receiptsFlag(flags.On)
			e.setReceipts(alice, true)
			e.setReceipts(bob, true)
			id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "hi"})
			if err := e.markRead(e.svc, bob, id); err != nil {
				t.Fatal(err)
			}
			if !e.peerReadAt(e.svc, alice, id) {
				t.Fatal("receipt not visible before the toggle")
			}
			e.setReceipts(who, false)
			if e.peerReadAt(e.svc, alice, id) {
				t.Error("receipt still visible right after toggling off")
			}
			e.setReceipts(who, true)
			if !e.peerReadAt(e.svc, alice, id) {
				t.Error("receipt not back after toggling on")
			}
		})
	}
}

// A later send does not clear the receipt, and neither does accepting a request (the entry is moved whole).
func TestReadReceipts_SurviveSendAndAccept(t *testing.T) {
	t.Run("send", func(t *testing.T) {
		e := newIT(t, nil)
		e.receiptsFlag(flags.On)
		e.setReceipts(alice, true)
		e.setReceipts(bob, true)
		e.mutual(alice, bob)
		e.must(alice, toUser(skey(1), bob, "hello"))
		id := ConversationID(alice, bob)
		if err := e.markRead(e.svc, bob, id); err != nil {
			t.Fatal(err)
		}
		before, _ := e.entry(bob, dmInboxCollection, id)
		e.tick(1e9)
		e.must(alice, toUser(skey(2), bob, "hello again"))
		after, _ := e.entry(bob, dmInboxCollection, id)
		if after.ReadReceiptAt.IsZero() || !after.ReadReceiptAt.Equal(before.ReadReceiptAt) {
			t.Errorf("readReceiptAt after a send = %v, want unchanged %v", after.ReadReceiptAt, before.ReadReceiptAt)
		}
		if !e.peerReadAt(e.msgSvc(), alice, id) {
			t.Error("peer_read_at lost after a send")
		}
	})
	t.Run("accept", func(t *testing.T) {
		e := newIT(t, nil)
		e.receiptsFlag(flags.On)
		e.setReceipts(alice, true)
		e.setReceipts(bob, true)
		id := e.seedConversation(alice, bob, stateRequest, base, [2]string{alice, "hello"})
		if err := e.markRead(e.svc, bob, id); err != nil {
			t.Fatal(err)
		}
		if ent, _ := e.entry(bob, dmRequestsCollection, id); ent.ReadReceiptAt.IsZero() {
			t.Fatal("receipt not stored on the request entry")
		}
		if err := e.accept(e.svc, bob, id); err != nil {
			t.Fatal(err)
		}
		moved, ok := e.entry(bob, dmInboxCollection, id)
		if !ok || moved.ReadReceiptAt.IsZero() {
			t.Errorf("accepted entry = %+v, %v: readReceiptAt must survive the move", moved, ok)
		}
		if !e.peerReadAt(e.msgSvc(), alice, id) {
			t.Error("peer_read_at lost after accept")
		}
	})
}
