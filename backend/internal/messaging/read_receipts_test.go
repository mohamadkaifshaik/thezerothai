package messaging

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F3: read receipts. peer_read_at needs the flag on for both users AND both settings on AND no block; MarkRead stores a
// receipt only for a caller with the flag on and the setting on.

func receiptsReg(mode flags.Mode, allow ...string) *flags.Registry {
	set := map[string]struct{}{}
	for _, u := range allow {
		set[u] = struct{}{}
	}
	return flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: identity.ReadReceiptsFlag, Mode: mode, Allowlist: set})
}

func withReceiptSettings(aliceOn, bobOn bool) func(*rig) {
	return func(r *rig) {
		a, b := r.profs.profiles[alice], r.profs.profiles[bob]
		a.ReadReceipts, b.ReadReceipts = aliceOn, bobOn
		r.profs.profiles[alice], r.profs.profiles[bob] = a, b
	}
}

// The 2x2 settings matrix, every flag mode, blocks and a missing receipt, on the first page of alice's thread.
func TestListMessages_PeerReadAt(t *testing.T) {
	stamp := time.Date(2026, 10, 28, 11, 30, 0, 0, time.UTC)
	blocked := func(s graph.Snapshot) func(*rig) {
		return func(r *rig) { r.social.snaps[alice] = s }
	}
	tests := []struct {
		name      string
		reg       *flags.Registry
		alice     bool
		bob       bool
		entry     EntryDoc
		social    func(*rig)
		entryErr  error
		wantSet   bool
		wantReads int // reads of bob's entry
	}{
		{"both on", receiptsReg(flags.On), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, true, 1},
		{"I am off: I see none", receiptsReg(flags.On), false, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"the peer is off: I see none", receiptsReg(flags.On), true, false, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"both off", receiptsReg(flags.On), false, false, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"both on, the peer never read with receipts", receiptsReg(flags.On), true, true, EntryDoc{LastReadAt: stamp}, nil, nil, false, 1},
		{"flag off", receiptsReg(flags.Off), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"allowlist with both", receiptsReg(flags.Allowlist, alice, bob), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, true, 1},
		{"allowlist without me", receiptsReg(flags.Allowlist, bob), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"allowlist without the peer", receiptsReg(flags.Allowlist, alice), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, nil, false, 0},
		{"I blocked the peer", receiptsReg(flags.On), true, true, EntryDoc{ReadReceiptAt: stamp}, blocked(graph.Snapshot{Blocked: map[string]bool{bob: true}}), nil, false, 0},
		{"the peer blocked me", receiptsReg(flags.On), true, true, EntryDoc{ReadReceiptAt: stamp}, blocked(graph.Snapshot{BlockedBy: map[string]bool{bob: true}}), nil, false, 0},
		{"block list overflow fails closed", receiptsReg(flags.On), true, true, EntryDoc{ReadReceiptAt: stamp}, blocked(graph.Snapshot{BlockedByOverflow: true}), nil, false, 0},
		{"a failed peer-entry read degrades to unset", receiptsReg(flags.On), true, true, EntryDoc{ReadReceiptAt: stamp}, nil, errors.New("boom"), false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, func(r *rig) {
				r.reg = tt.reg
				withReceiptSettings(tt.alice, tt.bob)(r)
				if tt.social != nil {
					tt.social(r)
				}
			})
			rg.putThread(2, nil)
			rg.putEntry(alice, dmInboxCollection, EntryDoc{UnreadCount: 1})
			rg.putEntry(bob, dmInboxCollection, tt.entry)
			if tt.entryErr != nil {
				// only bob's entry read fails; alice's own entry read (the unread count) must still work
				rg.repo.entryErrFor = map[string]error{bob: tt.entryErr}
			}
			resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			c := resp.GetConversation()
			if c == nil {
				t.Fatal("no conversation block")
			}
			if got := c.GetPeerReadAt() != nil; got != tt.wantSet {
				t.Errorf("peer_read_at set = %v, want %v", got, tt.wantSet)
			}
			if tt.wantSet && !c.GetPeerReadAt().AsTime().Equal(stamp) {
				t.Errorf("peer_read_at = %v, want %v", c.GetPeerReadAt().AsTime(), stamp)
			}
			reads := 0
			for _, g := range rg.repo.entryGets {
				if g == bob+"|"+entryInbox+"|"+aliceBobConv {
					reads++
				}
			}
			if reads != tt.wantReads {
				t.Errorf("reads of the peer's entry = %d, want %d (all: %v)", reads, tt.wantReads, rg.repo.entryGets)
			}
			if c.GetUnreadCount() != 1 {
				t.Errorf("unread_count = %d: the caller's own entry must be unaffected", c.GetUnreadCount())
			}
		})
	}
}

// Polls stay free: a since refresh and an older page never read the peer's entry nor set peer_read_at.
func TestListMessages_PeerReadAtFirstPageOnly(t *testing.T) {
	rg := newRig(t, func(r *rig) { r.reg = receiptsReg(flags.On); withReceiptSettings(true, true)(r) })
	rg.putThread(45, nil)
	rg.putEntry(bob, dmInboxCollection, EntryDoc{ReadReceiptAt: rg.now})
	first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageSize: 20})
	if first.Conversation.GetPeerReadAt() == nil {
		t.Fatal("first page: no peer_read_at")
	}
	rg.repo.entryGets = nil
	older := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageSize: 20, PageToken: first.NextPageToken})
	if older.Conversation.GetPeerReadAt() != nil {
		t.Error("older page carries peer_read_at")
	}
	since := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageSize: 20, SinceToken: first.SinceToken})
	if since.Conversation != nil {
		t.Error("a since response carries a conversation block")
	}
	if len(rg.repo.entryGets) != 0 {
		t.Errorf("entry reads on an older page and a since poll = %v, want none", rg.repo.entryGets)
	}
}

// The caller's own setting rides on the existing peer profile lookup: one GetProfiles call, no second lookup, whatever the flag.
func TestListMessages_ReceiptSettingRidesTheProfileLookup(t *testing.T) {
	for _, tt := range []struct {
		name string
		reg  *flags.Registry
	}{{"flag on", receiptsReg(flags.On)}, {"flag off", receiptsReg(flags.Off)}} {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, func(r *rig) { r.reg = tt.reg })
			rg.putThread(2, nil)
			rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			if rg.profs.calls != 1 {
				t.Errorf("profile lookups = %d, want 1", rg.profs.calls)
			}
		})
	}
}

// MarkRead stores a receipt only when the flag is on for the caller and the caller's own setting is on; never retroactive.
func TestMarkRead_Receipt(t *testing.T) {
	tests := []struct {
		name        string
		reg         *flags.Registry
		setting     bool
		profErr     error
		wantReceipt bool
		wantLookups int
	}{
		{"flag on, setting on", receiptsReg(flags.On), true, nil, true, 1},
		{"flag on, setting off", receiptsReg(flags.On), false, nil, false, 1},
		{"flag off, setting on", receiptsReg(flags.Off), true, nil, false, 0},
		{"allowlist with me", receiptsReg(flags.Allowlist, alice), true, nil, true, 1},
		{"allowlist without me", receiptsReg(flags.Allowlist, bob), true, nil, false, 0},
		{"a failed setting lookup still marks read, without a receipt", receiptsReg(flags.On), true, errors.New("boom"), false, 1},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, func(r *rig) { r.reg = tt.reg; withReceiptSettings(tt.setting, false)(r); r.profs.err = tt.profErr })
			if _, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err != nil {
				t.Fatal(err)
			}
			if len(rg.repo.marked) != 1 {
				t.Fatalf("marked = %v", rg.repo.marked)
			}
			if got := slices.Equal(rg.repo.receipts, []string{alice + "|" + aliceBobConv}); got != tt.wantReceipt {
				t.Errorf("receipt stored = %v (%v), want %v", got, rg.repo.receipts, tt.wantReceipt)
			}
			if rg.profs.calls != tt.wantLookups {
				t.Errorf("profile lookups = %d, want %d", rg.profs.calls, tt.wantLookups)
			}
		})
	}
	t.Run("not retroactive: a read while off stays unstamped after turning on", func(t *testing.T) {
		rg := newRig(t, func(r *rig) { r.reg = receiptsReg(flags.On) })
		mark := func() {
			if _, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err != nil {
				t.Fatal(err)
			}
		}
		mark() // setting off
		withReceiptSettings(true, false)(rg)
		if len(rg.repo.receipts) != 0 {
			t.Fatalf("the read made while off stored a receipt: %v", rg.repo.receipts)
		}
		mark() // setting on
		if len(rg.repo.receipts) != 1 {
			t.Errorf("receipts after turning on and reading = %v, want 1", rg.repo.receipts)
		}
	})
}
