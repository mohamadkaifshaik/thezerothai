package messaging

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"

	"connectrpc.com/connect"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// An account past the blockedBy cap cannot tell who blocks it from its own graph, so the REQUESTS read rule asks each
// remaining peer's graph instead: the request from a blocker is hidden, the one from anyone else stays.
func TestListConversations_RequestsOverflowCallerAsksThePeerGraph(t *testing.T) {
	const carol = "uid-carol"
	rg := newRig(t, nil)
	rg.social.snaps[alice] = graph.Snapshot{BlockedByOverflow: true}
	rg.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}}
	rg.put(alice, dmRequestsCollection, rg.entryAt(bob, 1), rg.entryAt(carol, 2))

	resp := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests})
	if got, want := convIDs(resp), []string{ConversationID(alice, carol)}; !slices.Equal(got, want) {
		t.Fatalf("REQUESTS = %v, want only %v", got, want)
	}
}

// The extra reads are the overflow case's alone, and never touch the shared "deleted account" peer.
func TestListConversations_RequestsPeerGraphReadOnlyWhenNeeded(t *testing.T) {
	const blockedPeer = "uid-blocked"
	tests := []struct {
		name  string
		snap  graph.Snapshot
		peer  string
		calls int // Social reads: the caller's graph, plus one if the peer was asked
	}{
		{name: "no overflow", snap: graph.Snapshot{}, peer: bob, calls: 1},
		{name: "overflow, hidden by the caller's own graph", snap: graph.Snapshot{BlockedByOverflow: true, Blocked: map[string]bool{blockedPeer: true}}, peer: blockedPeer, calls: 1},
		{name: "overflow, deleted peer", snap: graph.Snapshot{BlockedByOverflow: true}, peer: DeletedUID, calls: 1},
		{name: "overflow, live peer", snap: graph.Snapshot{BlockedByOverflow: true}, peer: bob, calls: 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, nil)
			rg.social.snaps[alice] = tt.snap
			rg.put(alice, dmRequestsCollection, rg.entryAt(tt.peer, 1))
			rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests})
			if rg.social.calls != tt.calls {
				t.Fatalf("Social reads = %d, want %d", rg.social.calls, tt.calls)
			}
		})
	}
}

// A peer graph that cannot be read fails the call rather than showing a request that may come from a blocker, and the
// peer's uid stays out of the error.
func TestListConversations_RequestsPeerGraphFailureFailsClosed(t *testing.T) {
	rg := newRig(t, nil)
	rg.social.snaps[alice] = graph.Snapshot{BlockedByOverflow: true}
	rg.social.errFor = map[string]error{bob: fmt.Errorf("read graph/%s: unavailable", bob)}
	rg.put(alice, dmRequestsCollection, rg.entryAt(bob, 1))

	_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: requests})
	if err == nil {
		t.Fatal("ListConversations answered without the peer's graph")
	}
	if strings.Contains(err.Error(), bob) {
		t.Fatalf("error carries the peer uid: %v", err)
	}
}

// A conversation document whose participants are not a pair answers with the bytes of an unknown id, as SendMessage by
// conversation_id does. It used to go on and look up the empty peer, which came back INTERNAL.
func TestListMessages_MalformedParticipantListIsNotFound(t *testing.T) {
	for name, parts := range map[string][]string{
		"caller alone": {alice},
		"three people": {alice, bob, "uid-carol"},
	} {
		t.Run(name, func(t *testing.T) {
			rg := newRig(t, nil)
			_, unknown := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: ConversationID(alice, "uid-nobody")})
			want := wireBytes(t, unknown)

			rg.repo.convs[aliceBobConv] = ConvDoc{Participants: parts}
			_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			if code := apierr.ToConnect(err).Code(); code != connect.CodeNotFound {
				t.Fatalf("err = %v, want NOT_FOUND", err)
			}
			if got := wireBytes(t, err); !bytes.Equal(got, want) {
				t.Fatalf("bytes differ from an unknown id's:\n got  %q\n want %q", got, want)
			}
		})
	}
}
