package messaging

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const permPeer = "uid-peer"

// permAllOn: messaging on for everyone and FEATURE_DM_POLICY on for everyone (the rig's default minus the suggestion sources).
func permAllOn() []flags.Spec {
	return []flags.Spec{{Name: FlagName, Mode: flags.On}, {Name: identity.DMPolicyFlag, Mode: flags.On}}
}

func allowOnly(name string, uids ...string) flags.Spec {
	s := flags.Spec{Name: name, Mode: flags.Allowlist, Allowlist: map[string]struct{}{}}
	for _, u := range uids {
		s.Allowlist[u] = struct{}{}
	}
	return s
}

func followingOnly(r *suggestRig) {
	p := r.profs.profiles[permPeer]
	p.DMPolicy = identity.DMPolicyFollowingOnly
	r.profs.profiles[permPeer] = p
}

// assertNoWrite: CanMessage never sends, accepts, deletes, marks, writes or evicts a profile.
func assertNoWrite(t *testing.T, r *suggestRig) {
	t.Helper()
	if len(r.repo.sends) != 0 || len(r.repo.accepts) != 0 || len(r.repo.deletes) != 0 || len(r.repo.marked) != 0 ||
		r.repo.writes != 0 || r.repo.deletedDocs != 0 || len(r.profs.forgot) != 0 {
		t.Fatalf("CanMessage wrote: sends=%d accepts=%d deletes=%d marked=%d writes=%d deleted=%d forgot=%v",
			len(r.repo.sends), len(r.repo.accepts), len(r.repo.deletes), len(r.repo.marked), r.repo.writes, r.repo.deletedDocs, r.profs.forgot)
	}
}

// TestCanMessage_Rules: every row of the rule table. A refusal is exactly ErrCannotMessage (never an *apierr.Error);
// self is its own error; a message request and the send caps are not refusals; nothing is written in any case.
func TestCanMessage_Rules(t *testing.T) {
	type want int
	const (
		allowed want = iota
		refused
		self
	)
	conv := func(c ConvDoc) func(*suggestRig) {
		return func(r *suggestRig) { r.repo.convs[ConversationID(me, permPeer)] = c }
	}
	tests := []struct {
		name   string
		specs  []flags.Spec
		target string
		setup  []func(*suggestRig)
		want   want
	}{
		{name: "allowed: active peer, both flags on, no relationship (a message request)", want: allowed},
		{name: "allowed: the caller follows the peer, the peer does not follow back (a request)", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{Following: map[string]bool{permPeer: true}}
		}}, want: allowed},
		{name: "allowed: the caller muted the peer", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{Muted: map[string]bool{permPeer: true}}
		}}, want: allowed},
		{name: "allowed: a request at the unanswered cap (caps limit sends, not this check)", setup: []func(*suggestRig){
			conv(ConvDoc{Participants: sortedPair(me, permPeer), State: stateRequest, RequestFrom: me, RequestTo: permPeer, RequestCount: 1_000_000}),
		}, want: allowed},
		{name: "self", target: me, want: self},
		{name: "malformed target", target: "not a uid/x", want: refused},
		{name: "unknown target", target: "uid-nobody", want: refused},
		{name: "suspended target", setup: []func(*suggestRig){func(r *suggestRig) {
			p := r.profs.profiles[permPeer]
			p.Status = identity.AccountStatusSuspended
			r.profs.profiles[permPeer] = p
		}}, want: refused},
		{name: "deleting target", setup: []func(*suggestRig){func(r *suggestRig) {
			p := r.profs.profiles[permPeer]
			p.Status = identity.AccountStatusDeleting
			r.profs.profiles[permPeer] = p
		}}, want: refused},
		{name: "the caller blocked the peer", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{Blocked: map[string]bool{permPeer: true}}
		}}, want: refused},
		{name: "the peer blocked the caller", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{BlockedBy: map[string]bool{permPeer: true}}
		}}, want: refused},
		// blockedBy overflow: the caller's list cannot say, so the peer's own block list decides, as SendMessage's
		// transaction does (it reads the recipient's graph, never the caller's blockedBy).
		{name: "blockedBy overflow, the peer did not block the caller: allowed like a send", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
		}}, want: allowed},
		{name: "blockedBy overflow, the peer blocked the caller", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
			r.social.snaps[permPeer] = graph.Snapshot{Blocked: map[string]bool{me: true}}
		}}, want: refused},
		{name: "blockedBy overflow, the listed blocker still refuses", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true, BlockedBy: map[string]bool{permPeer: true}}
		}}, want: refused},
		{name: "blockedBy overflow, unknown target", target: "uid-nobody", setup: []func(*suggestRig){func(r *suggestRig) {
			r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
		}}, want: refused},
		{name: "messaging off for the caller", specs: []flags.Spec{allowOnly(FlagName, permPeer), {Name: identity.DMPolicyFlag, Mode: flags.On}}, want: refused},
		{name: "messaging off for the peer", specs: []flags.Spec{allowOnly(FlagName, me), {Name: identity.DMPolicyFlag, Mode: flags.On}}, want: refused},
		{name: "messaging globally off", specs: []flags.Spec{{Name: FlagName, Mode: flags.Off}}, want: refused},
		{name: "FOLLOWING_ONLY, no follow, no conversation", setup: []func(*suggestRig){followingOnly}, want: refused},
		{name: "FOLLOWING_ONLY, the peer follows the caller", setup: []func(*suggestRig){followingOnly, func(r *suggestRig) {
			r.follow.back[permPeer] = true
		}}, want: allowed},
		{name: "FOLLOWING_ONLY, no follow, an ACCEPTED conversation", setup: []func(*suggestRig){followingOnly,
			conv(ConvDoc{Participants: sortedPair(me, permPeer), State: stateAccepted}),
		}, want: allowed},
		{name: "FOLLOWING_ONLY, no follow, the caller's own pending request", setup: []func(*suggestRig){followingOnly,
			conv(ConvDoc{Participants: sortedPair(me, permPeer), State: stateRequest, RequestFrom: me, RequestTo: permPeer, RequestCount: 1}),
		}, want: refused},
		{name: "FOLLOWING_ONLY, no follow, the peer's request to the caller (a reply accepts it)", setup: []func(*suggestRig){followingOnly,
			conv(ConvDoc{Participants: sortedPair(me, permPeer), State: stateRequest, RequestFrom: permPeer, RequestTo: me, RequestCount: 1}),
		}, want: allowed},
		{name: "FOLLOWING_ONLY with FEATURE_DM_POLICY off for the peer", specs: []flags.Spec{{Name: FlagName, Mode: flags.On}, allowOnly(identity.DMPolicyFlag, me)},
			setup: []func(*suggestRig){followingOnly}, want: allowed},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			specs := tc.specs
			if specs == nil {
				specs = permAllOn()
			}
			r := newSuggestRig(t, []string{me, permPeer}, specs...)
			for _, f := range tc.setup {
				f(r)
			}
			target := tc.target
			if target == "" {
				target = permPeer
			}
			err := r.svc.CanMessage(context.Background(), me, target)
			var ae *apierr.Error
			if errors.As(err, &ae) {
				t.Fatalf("CanMessage answered an *apierr.Error: %v", err)
			}
			switch tc.want {
			case allowed:
				if err != nil {
					t.Fatalf("want allowed, got %v", err)
				}
			case refused:
				if !errors.Is(err, ErrCannotMessage) || err != ErrCannotMessage {
					t.Fatalf("want exactly ErrCannotMessage, got %v", err)
				}
			case self:
				if !errors.Is(err, ErrSelf) || errors.Is(err, ErrCannotMessage) {
					t.Fatalf("want ErrSelf (not a refusal), got %v", err)
				}
			}
			assertNoWrite(t, r)
		})
	}
}

// TestCanMessage_Reads: the cheapest paths read nothing; the worst case (FOLLOWING_ONLY, no follow-back) is one graph
// snapshot, one profile batch, one follow lookup and one conversation read; a refusal by the caller's own graph stops
// before the profile read.
func TestCanMessage_Reads(t *testing.T) {
	t.Run("self and caller flag off read nothing", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, allowOnly(FlagName, permPeer))
		_ = r.svc.CanMessage(context.Background(), me, me)
		_ = r.svc.CanMessage(context.Background(), me, permPeer)
		if r.social.calls != 0 || r.profs.calls != 0 || len(r.follow.asked) != 0 || r.repo.gets != 0 {
			t.Fatalf("reads: social=%d profiles=%d follows=%d convs=%d", r.social.calls, r.profs.calls, len(r.follow.asked), r.repo.gets)
		}
	})
	t.Run("a block in the caller's graph stops before the profile read", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
		r.social.snaps[me] = graph.Snapshot{BlockedBy: map[string]bool{permPeer: true}}
		if err := r.svc.CanMessage(context.Background(), me, permPeer); !errors.Is(err, ErrCannotMessage) {
			t.Fatal(err)
		}
		if r.social.calls != 1 || r.profs.calls != 0 {
			t.Fatalf("reads: social=%d profiles=%d", r.social.calls, r.profs.calls)
		}
	})
	t.Run("no policy: graph and profile only", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
		if err := r.svc.CanMessage(context.Background(), me, permPeer); err != nil {
			t.Fatal(err)
		}
		if r.social.calls != 1 || r.profs.calls != 1 || len(r.follow.asked) != 0 || r.repo.gets != 0 {
			t.Fatalf("reads: social=%d profiles=%d follows=%d convs=%d", r.social.calls, r.profs.calls, len(r.follow.asked), r.repo.gets)
		}
	})
	t.Run("blockedBy overflow adds the peer's graph", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
		r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
		r.social.snaps[permPeer] = graph.Snapshot{Blocked: map[string]bool{me: true}}
		if err := r.svc.CanMessage(context.Background(), me, permPeer); !errors.Is(err, ErrCannotMessage) {
			t.Fatal(err)
		}
		if r.social.calls != 2 || r.profs.calls != 0 {
			t.Fatalf("reads: social=%d profiles=%d", r.social.calls, r.profs.calls)
		}
	})
	t.Run("worst case: five reads (blockedBy overflow and FOLLOWING_ONLY)", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
		followingOnly(r)
		r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
		if err := r.svc.CanMessage(context.Background(), me, permPeer); !errors.Is(err, ErrCannotMessage) {
			t.Fatal(err)
		}
		if r.social.calls != 2 || r.profs.calls != 1 || len(r.follow.asked) != 1 || r.repo.gets != 1 {
			t.Fatalf("reads: social=%d profiles=%d follows=%d convs=%d", r.social.calls, r.profs.calls, len(r.follow.asked), r.repo.gets)
		}
	})
	t.Run("worst case without overflow: four reads", func(t *testing.T) {
		r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
		followingOnly(r)
		if err := r.svc.CanMessage(context.Background(), me, permPeer); !errors.Is(err, ErrCannotMessage) {
			t.Fatal(err)
		}
		if r.social.calls != 1 || r.profs.calls != 1 || len(r.follow.asked) != 1 || r.repo.gets != 1 {
			t.Fatalf("reads: social=%d profiles=%d follows=%d convs=%d", r.social.calls, r.profs.calls, len(r.follow.asked), r.repo.gets)
		}
		if got := r.follow.asked[0]; len(got) != 1 || got[0] != permPeer {
			t.Fatalf("follow lookup asked %v", got)
		}
		assertNoWrite(t, r)
	})
}

// convErrRepo fails the conversation read.
type convErrRepo struct {
	*fakeRepo
	err error
}

func (c convErrRepo) GetConversation(context.Context, string) (ConvDoc, bool, error) {
	return ConvDoc{}, false, c.err
}

// TestCanMessage_ReadFailures: a failed read is a plain error, never ErrCannotMessage and never an *apierr.Error (even
// when the dependency's own error is one), with both uids hashed out of its text; nothing is written.
func TestCanMessage_ReadFailures(t *testing.T) {
	boom := errors.New("boom for " + me + " and " + permPeer)
	shaped := apierr.Validation("user_id", "shaped "+permPeer)
	for _, cause := range []error{boom, shaped} {
		for _, tc := range []struct {
			name string
			mut  func(*suggestRig)
		}{
			{"caller graph", func(r *suggestRig) { r.social.err = cause }},
			{"peer graph (blockedBy overflow)", func(r *suggestRig) {
				r.social.snaps[me] = graph.Snapshot{BlockedByOverflow: true}
				r.social.errFor = map[string]error{permPeer: cause}
			}},
			{"profiles", func(r *suggestRig) { r.profs.err = cause }},
			{"follow lookup", func(r *suggestRig) { followingOnly(r); r.follow.err = cause }},
			{"conversation", func(r *suggestRig) {
				followingOnly(r)
				r.svc.d.Repo = convErrRepo{fakeRepo: r.repo, err: cause}
			}},
		} {
			t.Run(tc.name+"/"+cause.Error(), func(t *testing.T) {
				r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
				tc.mut(r)
				err := r.svc.CanMessage(context.Background(), me, permPeer)
				var ae *apierr.Error
				switch {
				case err == nil:
					t.Fatal("a failed read was allowed")
				case errors.Is(err, ErrCannotMessage):
					t.Fatalf("a failed read became a refusal: %v", err)
				case errors.As(err, &ae):
					t.Fatalf("a failed read is an *apierr.Error: %v", err)
				case strings.Contains(err.Error(), me) || strings.Contains(err.Error(), permPeer):
					t.Fatalf("a uid is in the error text: %v", err)
				}
				assertNoWrite(t, r)
			})
		}
	}
}

// TestCanMessage_Unconfigured: a service without the read seams fails (a plain error), it never allows.
func TestCanMessage_Unconfigured(t *testing.T) {
	svc := New(flags.NewRegistry(permAllOn()...), Deps{}).(*service)
	err := svc.CanMessage(context.Background(), me, permPeer)
	if err == nil || errors.Is(err, ErrCannotMessage) {
		t.Fatalf("unconfigured CanMessage = %v", err)
	}
}

// TestSharesEncryptedConversation: true only for an MLS conversation whose two participants are exactly the two users
// (either order); no conversation, a plaintext one, an erased peer, an invalid or equal uid and a conversation that
// belongs to somebody else are false, nil; nothing is written, and the caller's messaging flag plays no part.
func TestSharesEncryptedConversation(t *testing.T) {
	id := ConversationID(me, permPeer)
	mls := func(participants ...string) func(*suggestRig) {
		return func(r *suggestRig) {
			r.repo.convs[id] = ConvDoc{Kind: kindDirect, Participants: participants, State: stateAccepted, Encryption: encMLS}
		}
	}
	tests := []struct {
		name         string
		caller, peer string
		mut          func(*suggestRig)
		want         bool
	}{
		{"no conversation", me, permPeer, func(*suggestRig) {}, false},
		{"plaintext", me, permPeer, func(r *suggestRig) {
			r.repo.convs[id] = ConvDoc{Kind: kindDirect, Participants: sortedPair(me, permPeer), State: stateAccepted}
		}, false},
		{"MLS, caller first", me, permPeer, mls(sortedPair(me, permPeer)...), true},
		{"MLS, asked the other way round", permPeer, me, mls(sortedPair(me, permPeer)...), true},
		{"MLS with an erased peer", me, permPeer, mls(sortedPair(me, DeletedUID)...), false},
		{"MLS whose participants are not the pair", me, permPeer, mls(sortedPair(me, "uid-someone-else")...), false},
		{"MLS with one participant", me, permPeer, mls(me), false},
		{"equal uids", me, me, mls(sortedPair(me, permPeer)...), false},
		{"invalid caller uid", "bad uid!", permPeer, mls(sortedPair(me, permPeer)...), false},
		{"invalid target uid", me, "bad uid!", mls(sortedPair(me, permPeer)...), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Messaging is off for the caller here: the shared-conversation check must not depend on the send gate.
			r := newSuggestRig(t, []string{me, permPeer}, flags.Spec{Name: FlagName, Mode: flags.Off})
			tc.mut(r)
			got, err := r.svc.SharesEncryptedConversation(context.Background(), tc.caller, tc.peer)
			if err != nil || got != tc.want {
				t.Fatalf("got %v, %v; want %v, nil", got, err, tc.want)
			}
			assertNoWrite(t, r)
		})
	}
}

// A failed conversation read is an error, never false and never a refusal, with both uids and the conversation id hashed
// out of its text; a service without a repository fails the same way.
func TestSharesEncryptedConversation_ReadFailure(t *testing.T) {
	id := ConversationID(me, permPeer)
	boom := errors.New("boom for " + me + " and " + permPeer + " in " + id)
	r := newSuggestRig(t, []string{me, permPeer}, permAllOn()...)
	r.svc.d.Repo = convErrRepo{fakeRepo: r.repo, err: boom}
	got, err := r.svc.SharesEncryptedConversation(context.Background(), me, permPeer)
	if err == nil || got {
		t.Fatalf("got %v, %v; want false with an error", got, err)
	}
	var ae *apierr.Error
	if errors.Is(err, ErrCannotMessage) || errors.As(err, &ae) {
		t.Fatalf("a failed read is a refusal or a wire error: %v", err)
	}
	for _, secret := range []string{me, permPeer, id} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("error text carries %q: %v", secret, err)
		}
	}
	r.svc.d.Repo = nil
	if got, err := r.svc.SharesEncryptedConversation(context.Background(), me, permPeer); err == nil || got {
		t.Fatalf("no repository: got %v, %v; want an error", got, err)
	}
}

// TestCanMessage_IsThePermission: the service satisfies the exported Permission seam.
func TestCanMessage_IsThePermission(t *testing.T) {
	if _, ok := New(nil, Deps{}).(Permission); !ok {
		t.Fatal("the messaging service does not implement Permission")
	}
}
