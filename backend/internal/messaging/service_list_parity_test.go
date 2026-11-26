package messaging

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

const dana = "uid-dana"

// parityCase is one conversation of alice's with dana, as the list row and the thread header must both show it.
type parityCase struct {
	name string
	// status is dana's account status in the directory; AccountStatusUnspecified = no profile at all.
	status identity.AccountStatus
	snap   graph.Snapshot
	// convPeer is the peer in the conversation's participants (DeletedUID once the eraser rewrote them; dana before).
	convPeer string
	// entryPeer is the peerId on alice's entry (DeletedUID once the eraser's MarkGone rewrote it).
	entryPeer string
	// state, requestFrom and requestTo are the conversation's; pending is requestPending on alice's INBOX entry.
	state, requestFrom, requestTo string
	pending                       bool
	// folder is the collection alice's entry is in.
	folder string
	// noConv: the conversation document is missing (only the entry remains). The header is then NOT_FOUND, so the row is
	// pinned on its own (want*) rather than compared.
	noConv bool

	wantState messagingv1.ConversationState
	wantFold  messagingv1.Folder
	wantReply bool
	// wantPlaceholder: the peer is the "Deleted account" snapshot; else dana's snapshot.
	wantPlaceholder bool
}

func parityCases() []parityCase {
	accepted := func(name string, status identity.AccountStatus, snap graph.Snapshot, reply, placeholder bool) parityCase {
		return parityCase{
			name: name, status: status, snap: snap, convPeer: dana, entryPeer: dana, state: stateAccepted, folder: dmInboxCollection,
			wantState: messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, wantFold: inbox, wantReply: reply, wantPlaceholder: placeholder,
		}
	}
	blocks := graph.Snapshot{Blocked: map[string]bool{dana: true}}
	blockedBy := graph.Snapshot{BlockedBy: map[string]bool{dana: true}}
	overflow := graph.Snapshot{BlockedByOverflow: true}
	reqState, accState := messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED
	return []parityCase{
		accepted("active", identity.AccountStatusActive, graph.Snapshot{}, true, false),
		accepted("suspended", identity.AccountStatusSuspended, graph.Snapshot{}, false, true),
		accepted("deactivated (deleting)", identity.AccountStatusDeleting, graph.Snapshot{}, false, true),
		accepted("no profile", identity.AccountStatusUnspecified, graph.Snapshot{}, false, true),
		accepted("caller blocks an active peer", identity.AccountStatusActive, blocks, false, false),
		accepted("caller blocks a suspended peer", identity.AccountStatusSuspended, blocks, false, true),
		// A blocked caller learns nothing about the blocker's account status: the frozen snapshot either way.
		accepted("blocked by an active peer", identity.AccountStatusActive, blockedBy, false, false),
		accepted("blocked by a suspended peer", identity.AccountStatusSuspended, blockedBy, false, false),
		accepted("blocked by a deactivated peer", identity.AccountStatusDeleting, blockedBy, false, false),
		accepted("overflow, active peer", identity.AccountStatusActive, overflow, false, false),
		accepted("overflow, suspended peer", identity.AccountStatusSuspended, overflow, false, false),
		{
			name: "erased peer, accepted", convPeer: DeletedUID, entryPeer: DeletedUID, state: stateAccepted, folder: dmInboxCollection,
			wantState: accState, wantFold: inbox, wantPlaceholder: true,
		},
		{
			name: "erased peer, accepted, caller blocked by it before", snap: graph.Snapshot{BlockedBy: map[string]bool{DeletedUID: true}},
			convPeer: DeletedUID, entryPeer: DeletedUID, state: stateAccepted, folder: dmInboxCollection,
			wantState: accState, wantFold: inbox, wantPlaceholder: true,
		},
		// L-A: alice requested dana, dana was erased. MarkGone deleted requestPending; the conversation is still REQUEST.
		{
			name: "erased request recipient", convPeer: DeletedUID, entryPeer: DeletedUID, state: stateRequest, requestFrom: alice, requestTo: DeletedUID,
			folder: dmInboxCollection, wantState: reqState, wantFold: inbox, wantPlaceholder: true,
		},
		// The same, between MarkGone and the participants rewrite: the conversation still names dana, who is DELETING.
		{
			name: "erased request recipient, mid-erasure", status: identity.AccountStatusDeleting, convPeer: dana, entryPeer: DeletedUID,
			state: stateRequest, requestFrom: alice, requestTo: dana, folder: dmInboxCollection, wantState: reqState, wantFold: inbox, wantPlaceholder: true,
		},
		{
			name: "pending request, active recipient", status: identity.AccountStatusActive, convPeer: dana, entryPeer: dana, state: stateRequest,
			requestFrom: alice, requestTo: dana, pending: true, folder: dmInboxCollection, wantState: reqState, wantFold: inbox, wantReply: true,
		},
		{
			name: "pending request, suspended recipient", status: identity.AccountStatusSuspended, convPeer: dana, entryPeer: dana, state: stateRequest,
			requestFrom: alice, requestTo: dana, pending: true, folder: dmInboxCollection, wantState: reqState, wantFold: inbox, wantPlaceholder: true,
		},
		{
			name: "incoming request, suspended requester", status: identity.AccountStatusSuspended, convPeer: dana, entryPeer: dana, state: stateRequest,
			requestFrom: dana, requestTo: alice, folder: dmRequestsCollection, wantState: reqState, wantFold: requests, wantPlaceholder: true,
		},
		{
			name: "incoming request, erased requester", convPeer: DeletedUID, entryPeer: DeletedUID, state: stateRequest,
			requestFrom: DeletedUID, requestTo: alice, folder: dmRequestsCollection, wantState: reqState, wantFold: requests, wantPlaceholder: true,
		},
		// An erased-peer INBOX row whose conversation document is gone: the list keeps ACCEPTED, read-only, Deleted
		// account; the header answers NOT_FOUND (nothing to agree on).
		{
			name: "erased peer, conversation missing", convPeer: DeletedUID, entryPeer: DeletedUID, folder: dmInboxCollection, noConv: true,
			wantState: accState, wantFold: inbox, wantPlaceholder: true,
		},
	}
}

// seedParity stores the case's conversation, alice's entry and dana's profile in the rig.
func seedParity(rg *rig, tc parityCase) (string, identity.Profile) {
	id := ConversationID(alice, dana)
	prof := activeProfile(dana, "dana", rg.now.AddDate(0, -1, 0))
	prof.Verified = true
	if tc.status != identity.AccountStatusUnspecified {
		p := prof
		p.Status = tc.status
		rg.profs.profiles[dana] = p
	}
	if !tc.noConv {
		rg.repo.convs[id] = ConvDoc{
			Kind: kindDirect, Participants: sortedPair(alice, tc.convPeer), State: tc.state, RequestFrom: tc.requestFrom, RequestTo: tc.requestTo,
			CreatedAt: rg.now.Add(-2 * time.Hour), UpdatedAt: rg.now.Add(-time.Hour),
		}
	}
	e := rg.entryAt(tc.entryPeer, 1)
	e.ID, e.RequestPending = id, tc.pending
	e.Peer = peerDocOf(prof) // the snapshot Send stored (the header shows the live profile; equal here)
	if tc.entryPeer == DeletedUID {
		e.Peer = PeerDoc{DisplayName: DeletedAccountName}
	}
	if rg.repo.entries == nil {
		rg.repo.entries = map[string][]EntryRow{}
	}
	k := entryKey(alice, tc.folder)
	rg.repo.entries[k] = append(rg.repo.entries[k], e)
	rg.social.snaps[alice] = tc.snap
	return id, prof
}

// TestListConversations_AgreesWithThreadHeader: for the same caller and conversation the list row and the ListMessages
// header carry the same state, folder, can_reply and peer (L-C: inactive peers; L-A: a request whose recipient was erased).
func TestListConversations_AgreesWithThreadHeader(t *testing.T) {
	for _, tc := range parityCases() {
		t.Run(tc.name, func(t *testing.T) {
			rg := newRig(t, nil)
			id, _ := seedParity(rg, tc)
			folder := inbox
			if tc.folder == dmRequestsCollection {
				folder = requests
			}
			list := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: folder})
			if len(list.Conversations) != 1 {
				t.Fatalf("list rows = %d, want 1", len(list.Conversations))
			}
			row := list.Conversations[0]
			msgs, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
			if tc.noConv {
				if code, _, _ := reasonOf(t, err); code != connect.CodeNotFound {
					t.Fatalf("ListMessages err = %v, want NOT_FOUND for a missing conversation", err)
				}
			} else if err != nil {
				t.Fatalf("ListMessages: %v", err)
			}
			if head := msgs.GetConversation(); !tc.noConv && (row.Id != head.Id || row.State != head.State || row.Folder != head.Folder || row.CanReply != head.CanReply || !proto.Equal(row.Peer, head.Peer)) {
				t.Fatalf("list row and header differ:\n row:    state=%v folder=%v can_reply=%v peer=%+v\n header: state=%v folder=%v can_reply=%v peer=%+v",
					row.State, row.Folder, row.CanReply, row.Peer, head.State, head.Folder, head.CanReply, head.Peer)
			}
			if row.State != tc.wantState || row.Folder != tc.wantFold || row.CanReply != tc.wantReply {
				t.Errorf("row: state=%v folder=%v can_reply=%v, want %v %v %v", row.State, row.Folder, row.CanReply, tc.wantState, tc.wantFold, tc.wantReply)
			}
			placeholder := row.Peer.GetDisplayName() == DeletedAccountName && row.Peer.GetUserId() == "" && row.Peer.GetHandle() == "" && row.Peer.GetAvatarUrl() == ""
			if placeholder != tc.wantPlaceholder {
				t.Errorf("peer = %+v, want placeholder %v", row.Peer, tc.wantPlaceholder)
			}
			if !tc.wantPlaceholder && (row.Peer.GetUserId() != dana || row.Peer.GetHandle() != "dana") {
				t.Errorf("peer = %+v, want dana's snapshot", row.Peer)
			}
		})
	}
}

// TestListConversations_LivenessCost: one batched directory call per non-empty page over the distinct live peers (never
// DeletedUID); the conversation batch read runs only for erased-peer INBOX rows that are not RequestPending, once, and the
// instance's conversation copy answers a second list.
func TestListConversations_LivenessCost(t *testing.T) {
	rg := newRig(t, nil)
	for i := range 5 {
		rg.put(alice, dmInboxCollection, rg.entryAt(fmt.Sprintf("peer-%d", i), i))
	}
	rg.put(alice, dmInboxCollection, rg.entryAt("peer-0", 9)) // the same peer twice is looked up once
	rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if rg.profs.calls != 1 || len(rg.repo.batchGets) != 0 {
		t.Fatalf("directory calls = %d, conversation batches = %d; want 1 and 0 (no erased-peer row)", rg.profs.calls, len(rg.repo.batchGets))
	}

	erased := rg.entryAt(DeletedUID, 6)
	erased.ID = ConversationID(alice, "gone-1")
	pending := rg.entryAt(DeletedUID, 7)
	pending.ID, pending.RequestPending = ConversationID(alice, "gone-2"), true // never left by MarkGone; no read needed
	rg.repo.convs[erased.ID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, DeletedUID), State: stateRequest, RequestFrom: alice, RequestTo: DeletedUID}
	rg.put(alice, dmInboxCollection, erased, pending)
	resp := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(rg.repo.batchGets) != 1 || !slices.Equal(rg.repo.batchGets[0], []string{erased.ID}) {
		t.Fatalf("conversation batches = %v, want one of [%s]", rg.repo.batchGets, erased.ID)
	}
	for _, c := range resp.Conversations {
		if c.Id == erased.ID && c.State != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST {
			t.Errorf("erased-recipient request row state = %v, want REQUEST", c.State)
		}
	}
	rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(rg.repo.batchGets) != 1 {
		t.Errorf("conversation batches = %d after a second list, want 1 (the instance copy answers)", len(rg.repo.batchGets))
	}
	// REQUESTS never reads conversations: its state is REQUEST from the folder.
	rg.put(alice, dmRequestsCollection, erased)
	rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests})
	if len(rg.repo.batchGets) != 1 {
		t.Errorf("REQUESTS read conversations: %v", rg.repo.batchGets)
	}
}

// TestListConversations_ErasedPeerConversationOfAnotherUser: a conversation the caller is not in (a corrupt entry) never
// changes the row and is never cached.
func TestListConversations_ErasedPeerConversationOfAnotherUser(t *testing.T) {
	rg := newRig(t, nil)
	e := rg.entryAt(DeletedUID, 1)
	e.ID = ConversationID(bob, "x")
	rg.repo.convs[e.ID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(bob, DeletedUID), State: stateRequest, RequestFrom: bob, RequestTo: DeletedUID}
	rg.put(alice, dmInboxCollection, e)
	c := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox}).Conversations[0]
	if c.State != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED {
		t.Errorf("state = %v, want ACCEPTED (not the caller's conversation)", c.State)
	}
	if _, ok := rg.svc.convs.Get(e.ID); ok {
		t.Error("a conversation the caller is not in was cached")
	}
}

// TestListConversations_PreErasureCacheNotTrusted (security review L1): an instance copy cached before the erasure (its
// participants still name the peer, not DeletedUID) is never trusted for an erased-peer row: it may predate an accept that
// committed just before the erasure. The id goes to the batch read, whose answer (ACCEPTED, rewritten) wins and is cached;
// a copy holding DeletedUID is trusted on the next list.
func TestListConversations_PreErasureCacheNotTrusted(t *testing.T) {
	rg := newRig(t, nil)
	id := ConversationID(alice, dana)
	// Stale: the request as it was before dana accepted and was erased.
	rg.svc.convs.Set(id, ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, dana), State: stateRequest, RequestFrom: alice, RequestTo: dana})
	// Stored: accepted, then the eraser rewrote the participants.
	rg.repo.convs[id] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, DeletedUID), State: stateAccepted, UpdatedAt: rg.now}
	e := rg.entryAt(DeletedUID, 1)
	e.ID = id
	rg.put(alice, dmInboxCollection, e)

	c := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox}).Conversations[0]
	if c.State != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED {
		t.Errorf("state = %v, want ACCEPTED (the stale pre-erasure copy must not answer)", c.State)
	}
	if len(rg.repo.batchGets) != 1 || !slices.Equal(rg.repo.batchGets[0], []string{id}) {
		t.Fatalf("conversation batches = %v, want one of [%s]", rg.repo.batchGets, id)
	}
	if cached, ok := rg.svc.convs.Get(id); !ok || !cached.hasParticipant(DeletedUID) {
		t.Errorf("cache = %+v, %v; want the rewritten copy", cached, ok)
	}
	rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(rg.repo.batchGets) != 1 {
		t.Errorf("conversation batches = %d, want 1 (a post-erasure copy is trusted)", len(rg.repo.batchGets))
	}
}

// TestListConversations_LivenessErrors: a failed directory or conversation read fails the page (as the header fails), with
// no peer uid or conversation id in the error.
func TestListConversations_LivenessErrors(t *testing.T) {
	t.Run("directory", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.put(alice, dmInboxCollection, rg.entryAt("peer-secret", 1))
		rg.profs.err = fmt.Errorf("rpc: users/%s failed", "peer-secret")
		_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		if err == nil {
			t.Fatal("want an error")
		}
		if containsAny(err.Error(), "peer-secret", alice) {
			t.Errorf("error leaks a uid: %q", err.Error())
		}
	})
	t.Run("conversations", func(t *testing.T) {
		rg := newRig(t, nil)
		e := rg.entryAt(DeletedUID, 1)
		rg.put(alice, dmInboxCollection, e)
		rg.repo.batchErr = fmt.Errorf("rpc: conversations/%s failed", e.ID)
		_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		if err == nil {
			t.Fatal("want an error")
		}
		if containsAny(err.Error(), e.ID, alice) {
			t.Errorf("error leaks an id: %q", err.Error())
		}
	})
	t.Run("not configured without the directory", func(t *testing.T) {
		rg := newRig(t, nil)
		svc := New(rg.reg, Deps{Repo: rg.repo, Social: rg.social, CursorKey: testCursorKey})
		_, err := svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		if err == nil || errors.Is(err, context.Canceled) {
			t.Fatalf("err = %v, want not configured", err)
		}
	})
}
