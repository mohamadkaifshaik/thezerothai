package messaging

import (
	"context"
	"errors"
	"testing"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// The instance conversation cache is shared by every caller and a conversation id is a public function of two public uids,
// so a non-participant's probe must neither read from it nor write to it (security review W7-22, H-1): whether the
// conversation exists, is warm, is cold or is missing, the probe costs exactly one repo read and leaves the cache as it
// found it. A participant's warm path stays at 0 reads.
func TestConversationCache_NonParticipantProbeIsOneReadAndLeavesNoTrace(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	unknown := ConversationID(alice, "uid-nobody")

	// Each path is one of the three callers of conversationHit, driven through its public entry point.
	type path struct {
		name  string
		setup func(rg *rig) (probe func(uid, convID string) error)
	}
	paths := []path{
		{"ListMessages", func(rg *rig) func(string, string) error {
			return func(uid, convID string) error {
				_, err := rg.svc.ListMessages(ctx, uid, &messagingv1.ListMessagesRequest{ConversationId: convID})
				return err
			}
		}},
		{"ReportContent MESSAGE", func(rg *rig) func(string, string) error {
			svc, _ := rg.reporter()
			return func(uid, convID string) error {
				_, err := svc.ReportableMessage(ctx, uid, convID, msgID(1))
				return err
			}
		}},
		{"SendMessage by conversation_id", func(rg *rig) func(string, string) error {
			n := 0
			return func(uid, convID string) error {
				n++
				_, err := rg.svc.Send(ctx, uid, toConv(key1+string(rune('a'+n)), convID, "probe"))
				return err
			}
		}},
	}
	for _, p := range paths {
		t.Run(p.name, func(t *testing.T) {
			t.Parallel()
			rg := newRig(t, nil)
			rg.putThread(3, nil)
			probe := p.setup(rg)
			reads := func(uid, convID string) (int, error) {
				before := rg.repo.gets
				err := probe(uid, convID)
				return rg.repo.gets - before, err
			}
			// Exists and cold: one read, NOT_FOUND, and nothing cached (the participant's next call still reads).
			for i := range 2 {
				if n, err := reads(stranger, aliceBobConv); n != 1 || err == nil {
					t.Fatalf("cold probe %d: repo reads = %d, err = %v, want 1 and an error", i, n, err)
				}
			}
			if n, err := reads(alice, aliceBobConv); n != 1 {
				t.Fatalf("participant after a stranger's probes: repo reads = %d (err %v), want 1: the probe must not warm the cache", n, err)
			}
			// Exists and warm (the participant just cached it): still exactly one read per probe, run twice.
			for i := range 2 {
				if n, err := reads(stranger, aliceBobConv); n != 1 || err == nil {
					t.Fatalf("warm probe %d: repo reads = %d, err = %v, want 1 and an error", i, n, err)
				}
			}
			// A participant's warm path makes no repo read, even after the strangers' probes.
			if n, err := reads(alice, aliceBobConv); n != 0 {
				t.Fatalf("participant warm: repo reads = %d (err %v), want 0", n, err)
			}
			// Missing: one read, twice.
			for i := range 2 {
				if n, err := reads(stranger, unknown); n != 1 || err == nil {
					t.Fatalf("missing probe %d: repo reads = %d, err = %v, want 1 and an error", i, n, err)
				}
			}
		})
	}
}

// conversationHit itself: the cache answers only a participant, a read for a non-participant is not cached, and the
// returned document still reaches the caller's own participant check (which turns it into NOT_FOUND).
func TestConversationHit(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	rg := newRig(t, nil)
	rg.putThread(1, nil)

	if _, hit, err := rg.svc.conversationHit(ctx, stranger, aliceBobConv); err != nil || hit {
		t.Fatalf("stranger cold: hit = %v err = %v, want a miss", hit, err)
	}
	if _, ok := rg.svc.convs.Get(aliceBobConv); ok {
		t.Fatal("a non-participant's read was put into the cache")
	}
	if _, hit, err := rg.svc.conversationHit(ctx, alice, aliceBobConv); err != nil || hit {
		t.Fatalf("alice cold: hit = %v err = %v, want a miss", hit, err)
	}
	if _, ok := rg.svc.convs.Get(aliceBobConv); !ok {
		t.Fatal("a participant's read was not cached")
	}
	if _, hit, _ := rg.svc.conversationHit(ctx, stranger, aliceBobConv); hit {
		t.Fatal("the cached copy answered a non-participant")
	}
	if c, hit, err := rg.svc.conversationHit(ctx, bob, aliceBobConv); err != nil || !hit || !c.hasParticipant(bob) {
		t.Fatalf("bob warm: hit = %v err = %v, want a hit", hit, err)
	}
	if _, _, err := rg.svc.conversationHit(ctx, alice, ConversationID(alice, "uid-nobody")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing: err = %v, want ErrNotFound", err)
	}
}
