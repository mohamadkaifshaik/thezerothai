package messaging

import (
	"bytes"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// F9: the recipient's "who can message me" policy.

func TestDMPolicyRefuses(t *testing.T) {
	accepted := &ConvDoc{State: stateAccepted, Participants: sortedPair(alice, bob)}
	requestAliceToBob := &ConvDoc{State: stateRequest, Participants: sortedPair(alice, bob), RequestFrom: alice, RequestTo: bob}
	tests := []struct {
		name          string
		conv          *ConvDoc
		uid           string
		followingOnly bool
		theyFollowMe  bool
		want          bool
	}{
		{"everyone policy never refuses", nil, alice, false, false, false},
		{"new conversation, recipient does not follow the caller", nil, alice, true, false, true},
		{"new conversation, recipient follows the caller", nil, alice, true, true, false},
		{"existing accepted conversation keeps working", accepted, alice, true, false, false},
		{"requester adds to a pending request", requestAliceToBob, alice, true, false, true},
		{"requester adds to a pending request, now followed", requestAliceToBob, alice, true, true, false},
		{"the recipient's reply accepts the request whoever follows whom", requestAliceToBob, bob, true, false, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := dmPolicyRefuses(tt.conv, tt.uid, tt.followingOnly, tt.theyFollowMe); got != tt.want {
				t.Errorf("dmPolicyRefuses = %v, want %v", got, tt.want)
			}
		})
	}
}

// bothFlags is the registry with messaging and dm_policy on for everyone.
func policyRegistry(dm flags.Spec) *flags.Registry {
	return flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, dm)
}

func followingOnlyBob(r *rig) {
	p := r.profs.profiles[bob]
	p.DMPolicy = identity.DMPolicyFollowingOnly
	r.profs.profiles[bob] = p
}

// TestSend_DMPolicyMatrix is the policy matrix: follows, mutual, blocked, existing conversations, and every flag mode.
func TestSend_DMPolicyMatrix(t *testing.T) {
	on := flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On}
	convID := ConversationID(alice, bob)
	tests := []struct {
		name string
		mut  func(*rig)
		// refused: CANNOT_MESSAGE; reason is the logged refused_reason.
		refused bool
		reason  string
	}{
		{"no relationship", func(r *rig) {}, true, refusedDMPolicy},
		{"the caller follows the recipient only", func(r *rig) { r.social.snaps[alice] = follows(alice, bob) }, true, refusedDMPolicy},
		{"the recipient follows the caller", func(r *rig) { r.social.snaps[bob] = follows(bob, alice) }, false, ""},
		{"mutual follows", func(r *rig) {
			r.social.snaps[alice] = follows(alice, bob)
			r.social.snaps[bob] = follows(bob, alice)
		}, false, ""},
		{"the recipient follows the caller but also blocked them", func(r *rig) {
			s := follows(bob, alice)
			s.Blocked = map[string]bool{alice: true}
			r.social.snaps[bob] = s
		}, true, refusedBlocked},
		{"the caller blocked the recipient, who follows them", func(r *rig) {
			r.social.snaps[bob] = follows(bob, alice)
			r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}}
		}, true, refusedBlocked},
		{"existing accepted conversation keeps working", func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted}
		}, false, ""},
		{"existing pending request from the caller", func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob, RequestCount: 1}
		}, true, refusedDMPolicy},
		{"policy unset (default) is today's behaviour", func(r *rig) {
			p := r.profs.profiles[bob]
			p.DMPolicy = identity.DMPolicyEveryoneRequests
			r.profs.profiles[bob] = p
		}, false, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.reg = policyRegistry(on)
				followingOnlyBob(r)
				tt.mut(r)
			})
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hi"))
			if !tt.refused {
				if err != nil {
					t.Fatalf("send = %v, want allowed", err)
				}
				return
			}
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
			if v, _ := info.Get(fieldRefused); v != tt.reason {
				t.Errorf("refused_reason = %v, want %q", v, tt.reason)
			}
		})
	}
}

// TestSend_DMPolicyFlagModes: the policy applies only to a recipient with FEATURE_DM_POLICY on; every other mode sends as before.
func TestSend_DMPolicyFlagModes(t *testing.T) {
	spec := func(mode flags.Mode, allow ...string) flags.Spec {
		m := map[string]struct{}{}
		for _, u := range allow {
			m[u] = struct{}{}
		}
		return flags.Spec{Name: identity.DMPolicyFlag, Mode: mode, Allowlist: m}
	}
	tests := []struct {
		name    string
		spec    flags.Spec
		refused bool
	}{
		{"off: a stored FOLLOWING_ONLY is ignored", spec(flags.Off), false},
		{"allowlist with the recipient", spec(flags.Allowlist, bob), true},
		{"allowlist with only the caller: the recipient is outside the rollout", spec(flags.Allowlist, alice), false},
		{"percent 0", flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.Percent}, false},
		{"percent 100", flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.Percent, Percent: 100}, true},
		{"on", spec(flags.On), true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.reg = policyRegistry(tt.spec)
				followingOnlyBob(r)
			})
			_, err := r.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
			if tt.refused {
				wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
				if len(r.repo.sends) != 1 {
					t.Errorf("the policy is decided in the transaction: sends = %d", len(r.repo.sends))
				}
				return
			}
			if err != nil {
				t.Fatalf("send = %v, want allowed", err)
			}
		})
	}
}

// TestSend_DMPolicyRefusalIsByteIdenticalToABlock: the sender cannot tell a policy refusal from a block.
func TestSend_DMPolicyRefusalIsByteIdenticalToABlock(t *testing.T) {
	on := flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On}
	blocked := newRig(t, func(r *rig) {
		r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}}
	})
	_, blockErr := blocked.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
	policy := newRig(t, func(r *rig) {
		r.reg = policyRegistry(on)
		followingOnlyBob(r)
	})
	_, policyErr := policy.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi"))
	if !bytes.Equal(wireBytes(t, blockErr), wireBytes(t, policyErr)) {
		t.Errorf("policy refusal differs from a block:\n block  %q\n policy %q", wireBytes(t, blockErr), wireBytes(t, policyErr))
	}
}

// TestSend_DMPolicyReachesTheTransaction: the service tells the transaction what it read from the recipient's profile.
func TestSend_DMPolicyReachesTheTransaction(t *testing.T) {
	on := flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On}
	r := newRig(t, func(r *rig) {
		r.reg = policyRegistry(on)
		followingOnlyBob(r)
		r.social.snaps[bob] = follows(bob, alice)
	})
	if _, err := r.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi")); err != nil {
		t.Fatal(err)
	}
	if !r.repo.sends[0].RecipientFollowingOnly {
		t.Error("RecipientFollowingOnly not set for a FOLLOWING_ONLY recipient with the flag on")
	}
	plain := newRig(t, nil)
	if _, err := plain.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi")); err != nil {
		t.Fatal(err)
	}
	if plain.repo.sends[0].RecipientFollowingOnly {
		t.Error("RecipientFollowingOnly set for a default recipient")
	}
}
