//go:build integration

package messaging

import (
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// F9 over the real FirestoreRepo: bob restricts DMs to accounts he follows. The recipient's Following set is read fresh in the
// send transaction (the service's cached snapshot of bob is deliberately left stale in these tests).

func policyIT(t *testing.T, mut func(*itEnv)) *itEnv {
	t.Helper()
	return newIT(t, func(e *itEnv) {
		e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On})
		p := e.profs.profiles[bob]
		p.DMPolicy = identity.DMPolicyFollowingOnly
		e.profs.profiles[bob] = p
		if mut != nil {
			mut(e)
		}
	})
}

func wantCannotMessage(t *testing.T, err error) {
	t.Helper()
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
}

func TestSendIT_DMPolicyMatrix(t *testing.T) {
	convID := ConversationID(alice, bob)
	tests := []struct {
		name      string
		setup     func(*itEnv)
		refused   bool
		wantState string
	}{
		{"strangers", func(e *itEnv) {}, true, ""},
		{"alice follows bob only", func(e *itEnv) {
			e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
		}, true, ""},
		{"bob follows alice only: allowed, arrives as a request (alice does not follow bob)", func(e *itEnv) {
			e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}}) // the cached snapshot stays empty
		}, false, stateRequest},
		{"mutual follows: allowed, accepted at once", func(e *itEnv) { e.mutual(alice, bob) }, false, stateAccepted},
		{"bob follows alice but blocked her", func(e *itEnv) {
			e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}, Blocked: map[string]bool{alice: true}})
		}, true, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := policyIT(t, nil)
			tt.setup(e)
			_, err := e.send(alice, toUser(skey(1), bob, "hello"))
			if tt.refused {
				wantCannotMessage(t, err)
				wantNothingWritten(t, e, convID)
				return
			}
			if err != nil {
				t.Fatalf("send: %v", err)
			}
			conv, ok := e.conv(convID)
			if !ok || conv.State != tt.wantState {
				t.Errorf("conversation = %+v (found %v), want state %s", conv, ok, tt.wantState)
			}
		})
	}
}

// Existing conversations: an ACCEPTED one keeps working when the policy is set later; a pending request the caller sent
// stops growing, and the recipient's own reply still accepts it.
func TestSendIT_DMPolicyAndExistingConversations(t *testing.T) {
	t.Run("accepted conversation keeps working", func(t *testing.T) {
		e := newIT(t, func(e *itEnv) {
			e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On})
		})
		e.mutual(alice, bob)
		e.must(alice, toUser(skey(1), bob, "before the policy"))
		// bob unfollows alice and restricts DMs afterwards.
		e.writeGraphDoc(bob, graph.Snapshot{})
		p := e.profs.profiles[bob]
		p.DMPolicy = identity.DMPolicyFollowingOnly
		e.profs.profiles[bob] = p
		if _, err := e.send(alice, toUser(skey(2), bob, "after the policy")); err != nil {
			t.Fatalf("an accepted conversation was refused: %v", err)
		}
		if n := len(e.msgs(ConversationID(alice, bob))); n != 2 {
			t.Errorf("messages = %d, want 2", n)
		}
	})
	t.Run("pending request: more messages refused, the recipient's reply accepts", func(t *testing.T) {
		e := newIT(t, func(e *itEnv) {
			e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On})
		})
		convID := ConversationID(alice, bob)
		e.must(alice, toUser(skey(1), bob, "request sent before the policy")) // strangers: a request
		if conv, _ := e.conv(convID); conv.State != stateRequest {
			t.Fatalf("state = %s, want request", conv.State)
		}
		p := e.profs.profiles[bob]
		p.DMPolicy = identity.DMPolicyFollowingOnly
		e.profs.profiles[bob] = p
		_, err := e.send(alice, toUser(skey(2), bob, "another one"))
		wantCannotMessage(t, err)
		if n := len(e.msgs(convID)); n != 1 {
			t.Errorf("messages = %d, want 1 (the refused one was not written)", n)
		}
		if _, err := e.send(bob, toUser(skey(3), alice, "ok, hi")); err != nil {
			t.Fatalf("the recipient's own reply was refused: %v", err)
		}
		if conv, _ := e.conv(convID); conv.State != stateAccepted {
			t.Errorf("state after the reply = %s, want accepted", conv.State)
		}
		// Now accepted: alice can write again whatever the policy says.
		if _, err := e.send(alice, toUser(skey(4), bob, "thanks")); err != nil {
			t.Fatalf("after acceptance: %v", err)
		}
	})
}

// The recipient's Following is read in the transaction, so an unfollow on another instance applies at once even though the
// sender's instance still caches a snapshot that says "follows".
func TestSendIT_DMPolicyFollowsReadFresh(t *testing.T) {
	e := policyIT(t, nil)
	e.writeGraphDoc(bob, graph.Snapshot{Following: map[string]bool{alice: true}})
	e.must(alice, toUser(skey(1), bob, "allowed while followed"))
	e.writeGraphDoc(bob, graph.Snapshot{}) // bob unfollows alice; the conversation is still a pending request
	_, err := e.send(alice, toUser(skey(2), bob, "after the unfollow"))
	wantCannotMessage(t, err)
	if n := len(e.msgs(ConversationID(alice, bob))); n != 1 {
		t.Errorf("messages = %d, want 1", n)
	}
}

// Flag mode: with FEATURE_DM_POLICY off for the recipient a stored FOLLOWING_ONLY changes nothing.
func TestSendIT_DMPolicyFlagOff(t *testing.T) {
	e := policyIT(t, func(e *itEnv) {
		e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.Off})
	})
	if _, err := e.send(alice, toUser(skey(1), bob, "policy ignored")); err != nil {
		t.Fatalf("send with the flag off: %v", err)
	}
	if conv, ok := e.conv(ConversationID(alice, bob)); !ok || conv.State != stateRequest {
		t.Errorf("conversation = %+v (found %v), want a request", conv, ok)
	}
}
