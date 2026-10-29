package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

const key1 = "send-key-000000001"

func toUser(key, uid, text string) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: uid}, Text: text}
}

func toConv(key, id, text string) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: id}, Text: text}
}

func follows(from string, to ...string) graph.Snapshot {
	f := map[string]bool{}
	for _, u := range to {
		f[u] = true
	}
	return graph.Snapshot{Following: f}
}

func wantAPI(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason, meta map[string]string) {
	t.Helper()
	if err == nil {
		t.Fatalf("no error, want %v %v", code, reason)
	}
	gotCode, gotReason, gotMeta := reasonOf(t, err)
	if gotCode != code || gotReason != reason {
		t.Fatalf("error = %v %v (%v), want %v %v", gotCode, gotReason, err, code, reason)
	}
	for k, v := range meta {
		if gotMeta[k] != v {
			t.Errorf("metadata[%s] = %q, want %q", k, gotMeta[k], v)
		}
	}
}

// Step 1: the key, the target and the text are validated before any read (0 reads on rejection).
func TestSend_ValidationCostsNoReads(t *testing.T) {
	tests := []struct {
		name  string
		req   *messagingv1.SendMessageRequest
		field string
	}{
		{"short key", toUser("short", bob, "hi"), "idempotency_key"},
		{"key with a space", toUser("key with a space 1", bob, "hi"), "idempotency_key"},
		{"no target", &messagingv1.SendMessageRequest{IdempotencyKey: key1, Text: "hi"}, "recipient_user_id"},
		{"bad recipient uid", toUser(key1, "bad_uid", "hi"), "recipient_user_id"},
		{"self", toUser(key1, alice, "hi"), "recipient_user_id"},
		{"bad conversation id", toConv(key1, "NOT-HEX", "hi"), "conversation_id"},
		{"empty text", toUser(key1, bob, "   "), "text"},
		{"text too long", toUser(key1, bob, strings.Repeat("a", 281)), "text"},
		{"eleven lines", toUser(key1, bob, strings.Repeat("a\n", 10)+"b"), "text"},
		{"control character", toUser(key1, bob, "a\x01b"), "text"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, nil)
			_, err := r.svc.Send(context.Background(), alice, tt.req)
			wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": tt.field})
			if r.repo.gets+len(r.repo.sends)+r.social.calls+r.profs.calls != 0 {
				t.Errorf("a rejected request read or wrote: repo gets %d sends %d graph %d profiles %d", r.repo.gets, len(r.repo.sends), r.social.calls, r.profs.calls)
			}
		})
	}
}

// Text goes through text.Normalize (A6): NFC and the stored form, never the raw input.
func TestSend_TextIsNormalised(t *testing.T) {
	r := newRig(t, nil)
	resp, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "  é \r\nok\t "))
	if err != nil {
		t.Fatal(err)
	}
	if want := "é \nok"; resp.GetMessage().GetText() != want || r.repo.sends[0].Text != want {
		t.Errorf("stored %q, answered %q, want %q", r.repo.sends[0].Text, resp.GetMessage().GetText(), want)
	}
}

// F6: the flag is checked for the caller (FEATURE_DISABLED, 0 reads) and for the recipient (CANNOT_MESSAGE). Both
// users are put through off / allowlist / percent / on.
func TestSend_FlagMatrix(t *testing.T) {
	spec := func(mode flags.Mode, allow ...string) flags.Spec {
		m := map[string]struct{}{}
		for _, u := range allow {
			m[u] = struct{}{}
		}
		return flags.Spec{Name: FlagName, Mode: mode, Allowlist: m}
	}
	tests := []struct {
		name string
		spec flags.Spec
		// callerOn, peerOn: the flag state per user the spec produces.
		callerOn, peerOn bool
	}{
		{"off", spec(flags.Off, alice, bob), false, false},
		{"allowlist: both listed", spec(flags.Allowlist, alice, bob), true, true},
		{"allowlist: only the caller", spec(flags.Allowlist, alice), true, false},
		{"allowlist: only the recipient", spec(flags.Allowlist, bob), false, true},
		{"percent 0, nobody listed", flags.Spec{Name: FlagName, Mode: flags.Percent}, false, false},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, true, true},
		{"on", spec(flags.On), true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(tt.spec) })
			resp, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi"))
			switch {
			case !tt.callerOn:
				wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": "messaging"})
				if r.social.calls+r.profs.calls+r.repo.gets+len(r.repo.sends) != 0 {
					t.Error("a caller outside the flag cost a read")
				}
			case !tt.peerOn:
				wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
				if len(r.repo.sends) != 0 {
					t.Error("a refused send reached the transaction")
				}
			default:
				if err != nil || resp.GetMessage().GetId() == "" {
					t.Fatalf("send = %v, %v", resp, err)
				}
			}
		})
	}
}

// Every refusal has identical bytes on the wire: a block either way, a deleted or suspended recipient, a recipient with
// the flag off, and a conversation whose peer deleted the account (ADR-0027 D4: no oracle).
func TestSend_RefusalsAreByteIdentical(t *testing.T) {
	convID := ConversationID(alice, bob)
	tests := []struct {
		name   string
		mut    func(*rig)
		reason string
	}{
		{"the caller blocks the recipient", func(r *rig) { r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}} }, refusedBlocked},
		{"the recipient blocks the caller", func(r *rig) { r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}} }, refusedBlocked},
		{"the recipient deleted the account", func(r *rig) { delete(r.profs.profiles, bob) }, refusedRecipientOff},
		{"the recipient is suspended", func(r *rig) {
			p := r.profs.profiles[bob]
			p.Status = identity.AccountStatusSuspended
			r.profs.profiles[bob] = p
		}, refusedRecipientOff},
		{"the recipient has messaging off", func(r *rig) {
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{alice: {}}})
		}, refusedRecipientFlagOff},
		{"the conversation is gone (by id)", func(r *rig) {
			r.repo.convs[convID] = ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted, Gone: []string{bob}}
		}, refusedGone},
		{"gone, seen inside the transaction", func(r *rig) { r.repo.sendErr = ErrCannotMessage }, refusedGone},
		{"the fresh status read finds the recipient inactive", func(r *rig) {
			r.repo.sendRes = SendResult{Created: true}
			r.repo.sendErr = nil
		}, refusedRecipientOff},
	}
	var first []byte
	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, tt.mut)
			req := toUser(key1, bob, "hi")
			if strings.Contains(tt.name, "(by id)") {
				req = toConv(key1, convID, "hi")
			}
			if strings.Contains(tt.name, "fresh status") {
				// The directory answers the first lookup but not the fresh one (the user was purged in between).
				calls := 0
				r.profs.err = nil
				r.svc.d.Profiles = profilesFunc(func(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
					calls++
					if calls > 1 {
						return map[string]identity.Profile{}, nil
					}
					return r.profs.GetProfiles(ctx, uids)
				}, r.profs.Forget)
			}
			ctx, info := logger.WithRequestInfo(context.Background())
			_, err := r.svc.Send(ctx, alice, req)
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
			got := wireBytes(t, err)
			if i == 0 {
				first = got
			} else if !bytes.Equal(got, first) {
				t.Errorf("response bytes differ from the first refusal:\n got  %q\n want %q", got, first)
			}
			if v, _ := info.Get(fieldRefused); v != tt.reason {
				t.Errorf("refused_reason = %v, want %q", v, tt.reason)
			}
		})
	}
}

type profilesFuncImpl struct {
	get    func(context.Context, []string) (map[string]identity.Profile, error)
	forget func(...string)
}

func (p profilesFuncImpl) GetProfiles(ctx context.Context, u []string) (map[string]identity.Profile, error) {
	return p.get(ctx, u)
}
func (p profilesFuncImpl) Forget(u ...string) { p.forget(u...) }

func profilesFunc(get func(context.Context, []string) (map[string]identity.Profile, error), forget func(...string)) Profiles {
	return profilesFuncImpl{get, forget}
}

// Routing facts handed to the transaction: mutual, silent (the recipient muted the caller), and the caller's own mute flag.
func TestSend_RoutingFlagsReachTheTransaction(t *testing.T) {
	tests := []struct {
		name                         string
		snaps                        map[string]graph.Snapshot
		wantMutual, wantSilent, mute bool
	}{
		{"strangers", nil, false, false, false},
		{"mutual follows", map[string]graph.Snapshot{alice: follows(alice, bob), bob: follows(bob, alice)}, true, false, false},
		{"only the caller follows", map[string]graph.Snapshot{alice: follows(alice, bob)}, false, false, false},
		{"only the recipient follows", map[string]graph.Snapshot{bob: follows(bob, alice)}, false, false, false},
		{"the recipient muted the caller", map[string]graph.Snapshot{bob: {Muted: map[string]bool{alice: true}}}, false, true, false},
		{"the caller muted the recipient", map[string]graph.Snapshot{alice: {Muted: map[string]bool{bob: true}}}, false, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				for u, s := range tt.snaps {
					r.social.snaps[u] = s
				}
			})
			resp, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi"))
			if err != nil {
				t.Fatal(err)
			}
			p := r.repo.sends[0]
			if p.Mutual != tt.wantMutual || p.Silent != tt.wantSilent || p.CallerSilent != tt.mute {
				t.Errorf("mutual/silent/callerSilent = %v/%v/%v, want %v/%v/%v", p.Mutual, p.Silent, p.CallerSilent, tt.wantMutual, tt.wantSilent, tt.mute)
			}
			if p.ConvID != ConversationID(alice, bob) || p.MsgID != MessageID(alice, key1) || p.RequestHash != requestHash(p.ConvID, "hi") {
				t.Errorf("ids = %q %q %q", p.ConvID, p.MsgID, p.RequestHash)
			}
			if p.MaxUnanswered != 3 || p.DMNewLimit != 20 {
				t.Errorf("limits = %d/%d, want 3/20", p.MaxUnanswered, p.DMNewLimit)
			}
			if p.Caller.Handle != "alice" || p.Peer.Handle != "bob" {
				t.Errorf("snapshots = %+v / %+v", p.Caller, p.Peer)
			}
			if resp.GetConversation().GetSilent() != tt.mute || !resp.GetConversation().GetCanReply() || resp.GetMessage().GetFromSelf() != true {
				t.Errorf("response = %v", resp)
			}
		})
	}
}

// F7 / D4 step 6: one event for an accepted, non-silent recipient; none for a request, a muted sender or a replay.
// Step 7: both participants' badge caches are evicted on a delivered message.
func TestSend_EventsAndBadge(t *testing.T) {
	tests := []struct {
		name       string
		snaps      map[string]graph.Snapshot
		res        SendResult
		wantEvents int
		wantBadge  bool
	}{
		{"accepted, not silent", map[string]graph.Snapshot{alice: follows(alice, bob), bob: follows(bob, alice)}, SendResult{Created: true, Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}}, 1, true},
		{"request: no push", nil, SendResult{Created: true, RecipientInRequests: true, Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateRequest}}, 0, true},
		{"accepted but muted: no push", map[string]graph.Snapshot{bob: {Following: map[string]bool{alice: true}, Muted: map[string]bool{alice: true}}, alice: follows(alice, bob)}, SendResult{}, 0, true},
		{"a reply that accepts pushes", nil, SendResult{AcceptedByReply: true, Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}}, 1, true},
		{"replay: nothing", nil, SendResult{Replay: true, Msg: MsgDoc{SenderID: alice, Text: "hi", State: msgVisible, CreatedAt: time.Unix(1, 0).UTC()}}, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				for u, s := range tt.snaps {
					r.social.snaps[u] = s
				}
				r.repo.sendRes = tt.res
			})
			if _, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err != nil {
				t.Fatal(err)
			}
			if len(r.events.got) != tt.wantEvents {
				t.Fatalf("events = %d, want %d", len(r.events.got), tt.wantEvents)
			}
			if tt.wantEvents == 1 {
				e := r.events.got[0]
				if e.ActorUID != alice || e.RecipientUID != bob || e.ConversationID != ConversationID(alice, bob) {
					t.Errorf("event = %+v", e)
				}
			}
			if (len(r.badge.got) == 1) != tt.wantBadge {
				t.Errorf("badge evictions = %v, want one: %v", r.badge.got, tt.wantBadge)
			}
			if tt.wantBadge && (len(r.badge.got[0]) != 2) {
				t.Errorf("badge evicted %v, want both participants", r.badge.got[0])
			}
		})
	}
}

// A nil Events and a nil Badge are a valid wiring (W7-10 and W7-11 have not landed yet).
func TestSend_NilSeamsAreSkipped(t *testing.T) {
	r := newRig(t, nil)
	r.svc.d.Events, r.svc.d.Badge = nil, nil
	if _, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err != nil {
		t.Fatal(err)
	}
}

// Repo errors map to the documented wire answers.
func TestSend_RepoErrorMapping(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		code   connect.Code
		reason commonv1.ErrorReason
		meta   map[string]string
	}{
		{"4th request message", ErrRequestLimit, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "request_unanswered"}},
		{"21st new conversation", ErrDMNewDaily, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "dm_new_daily"}},
		{"same key, other text", ErrKeyReused, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"}},
		{"not a participant", ErrNotFound, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
		{"gone", ErrCannotMessage, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil},
		{"lock contention", fmt.Errorf("x: %w", store.ErrContended), connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) { r.repo.sendErr = tt.err })
			ctx, info := logger.WithRequestInfo(context.Background())
			_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hi"))
			wantAPI(t, err, tt.code, tt.reason, tt.meta)
			if tt.meta["limit"] != "" && info.LimitName != tt.meta["limit"] {
				t.Errorf("limit_name = %q, want %q", info.LimitName, tt.meta["limit"])
			}
		})
	}
}

// An unexpected error is internal, and neither the uids nor the conversation id survive in the logged chain.
func TestSend_InternalErrorIsRedacted(t *testing.T) {
	r := newRig(t, func(r *rig) {
		r.repo.sendErr = fmt.Errorf("rpc error: documents/users/%s/dmInbox/%s and %s failed", bob, ConversationID(alice, bob), alice)
	})
	_, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi"))
	if err == nil || connect.CodeOf(apierr.ToConnect(err)) != connect.CodeInternal {
		t.Fatalf("err = %v, want an internal error", err)
	}
	chain := logger.CauseChain(err)
	for _, secret := range []string{alice, bob, ConversationID(alice, bob), MessageID(alice, key1)} {
		if strings.Contains(chain, secret) {
			t.Errorf("the error chain still holds %q: %s", secret, chain)
		}
	}
}

// A cancelled or expired request is the caller's, not a server fault.
func TestSend_ContextEndMapsToItsCode(t *testing.T) {
	for _, tt := range []struct {
		name string
		mk   func() (context.Context, context.CancelFunc)
		code connect.Code
	}{
		{"canceled", func() (context.Context, context.CancelFunc) {
			c, cancel := context.WithCancel(context.Background())
			cancel()
			return c, cancel
		}, connect.CodeCanceled},
		{"deadline", func() (context.Context, context.CancelFunc) {
			return context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
		}, connect.CodeDeadlineExceeded},
	} {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) { r.repo.sendErr = errors.New("boom") })
			ctx, cancel := tt.mk()
			defer cancel()
			_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hi"))
			if got := apierr.ToConnect(err).Code(); got != tt.code {
				t.Errorf("code = %v, want %v", got, tt.code)
			}
		})
	}
}

// A send by conversation_id checks membership against the instance cache: unknown and foreign ids are one NOT_FOUND
// (identical bytes), a hit costs no second read, and the peer comes from the participants.
func TestSend_ByConversationID(t *testing.T) {
	convID := ConversationID(alice, bob)
	stored := ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}

	t.Run("participant, cached after the first read", func(t *testing.T) {
		r := newRig(t, func(r *rig) { r.repo.convs[convID] = stored })
		for range 2 {
			if _, err := r.svc.Send(context.Background(), alice, toConv(key1, convID, "hi")); err != nil {
				t.Fatal(err)
			}
		}
		if r.repo.gets != 1 {
			t.Errorf("conversation reads = %d, want 1 (the second send hits the cache)", r.repo.gets)
		}
		if got := r.repo.sends[0].PeerUID; got != bob {
			t.Errorf("peer = %q, want bob", got)
		}
	})

	t.Run("a malformed participant list is NOT_FOUND, not a send to nobody", func(t *testing.T) {
		bad := strings.Repeat("b", 32)
		r := newRig(t, func(r *rig) { r.repo.convs[bad] = ConvDoc{Participants: []string{alice}, State: stateAccepted} })
		_, err := r.svc.Send(context.Background(), alice, toConv(key1, bad, "hi"))
		wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		if r.social.calls != 0 || len(r.repo.sends) != 0 {
			t.Error("a malformed conversation reached the graph or the transaction")
		}
	})

	t.Run("unknown and foreign ids answer the same bytes", func(t *testing.T) {
		r := newRig(t, func(r *rig) { r.repo.convs[convID] = stored })
		foreign := ConversationID(bob, "uid-carol")
		r.repo.convs[foreign] = ConvDoc{Participants: sortedPair(bob, "uid-carol"), State: stateAccepted}
		_, unknownErr := r.svc.Send(context.Background(), alice, toConv(key1, strings.Repeat("a", 32), "hi"))
		_, foreignErr := r.svc.Send(context.Background(), alice, toConv(key1, foreign, "hi"))
		wantAPI(t, unknownErr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		if !bytes.Equal(wireBytes(t, unknownErr), wireBytes(t, foreignErr)) {
			t.Errorf("NOT_FOUND bytes differ:\n unknown %q\n foreign %q", wireBytes(t, unknownErr), wireBytes(t, foreignErr))
		}
		if len(r.repo.sends) != 0 {
			t.Error("a foreign conversation reached the transaction")
		}
	})
}

// The new-account tier of the daily call cap (MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY) is applied by the service; an
// established account is not subject to it.
func TestSend_NewAccountDailyCap(t *testing.T) {
	fresh := func(r *rig) {
		r.limits.NewAccountSendsPerDay = 3
		r.profs.profiles[alice] = activeProfile(alice, "alice", r.now.Add(-time.Hour))
	}
	t.Run("new account: the 4th call is RATE_LIMITED messages_daily", func(t *testing.T) {
		r := newRig(t, fresh)
		for i := range 3 {
			if _, err := r.svc.Send(context.Background(), alice, toUser(fmt.Sprintf("send-key-%08d", i), bob, "hi")); err != nil {
				t.Fatalf("send %d: %v", i, err)
			}
		}
		ctx, info := logger.WithRequestInfo(context.Background())
		_, err := r.svc.Send(ctx, alice, toUser("send-key-00000009", bob, "hi"))
		wantAPI(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, map[string]string{"limit": "messages_daily"})
		if info.LimitName != "messages_daily" {
			t.Errorf("limit_name = %q", info.LimitName)
		}
		if ae := new(apierr.Error); errors.As(err, &ae) && ae.RetryAfter <= 0 {
			t.Error("no retry_after")
		}
		if len(r.repo.sends) != 3 {
			t.Errorf("transactions = %d, want 3 (the capped call must not reach the repo)", len(r.repo.sends))
		}
	})
	t.Run("established account is not capped by the tier", func(t *testing.T) {
		r := newRig(t, func(r *rig) { r.limits.NewAccountSendsPerDay = 1 })
		for i := range 4 {
			if _, err := r.svc.Send(context.Background(), alice, toUser(fmt.Sprintf("send-key-%08d", i), bob, "hi")); err != nil {
				t.Fatalf("send %d: %v", i, err)
			}
		}
	})
	t.Run("a new account gets the smaller new-conversation quota", func(t *testing.T) {
		r := newRig(t, fresh)
		if _, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err != nil {
			t.Fatal(err)
		}
		if got := r.repo.sends[0].DMNewLimit; got != 5 {
			t.Errorf("DMNewLimit = %d, want the new-account 5", got)
		}
	})
}

// The fresh recipient check runs inside the transaction for a new conversation only: Forget, then a directory read.
func TestSend_FreshRecipientCheck(t *testing.T) {
	r := newRig(t, func(r *rig) { r.repo.sendRes = SendResult{Created: true} })
	if _, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err != nil {
		t.Fatal(err)
	}
	if len(r.profs.forgot) != 1 || r.profs.forgot[0] != bob {
		t.Errorf("Forget = %v, want [bob]", r.profs.forgot)
	}
	if r.profs.calls != 2 {
		t.Errorf("directory lookups = %d, want 2 (the cached one, then the fresh one)", r.profs.calls)
	}
	// An existing conversation never pays it.
	r2 := newRig(t, nil)
	if _, err := r2.svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err != nil {
		t.Fatal(err)
	}
	if len(r2.profs.forgot) != 0 || r2.profs.calls != 1 {
		t.Errorf("an existing conversation forgot %v and looked up %d times", r2.profs.forgot, r2.profs.calls)
	}
}

// The request line (D11): the fixed fields, and never the text, a uid or the conversation id in clear.
func TestSend_RequestLineFields(t *testing.T) {
	convID := ConversationID(alice, bob)
	tests := []struct {
		name  string
		res   SendResult
		snaps map[string]graph.Snapshot
		state string
	}{
		{"new", SendResult{Created: true, RecipientInRequests: true, Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateRequest}}, nil, "new"},
		{"request", SendResult{RecipientInRequests: true, Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateRequest}}, nil, "request"},
		{"accepted", SendResult{Conv: ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted}}, nil, "accepted"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, func(r *rig) {
				r.repo.sendRes = tt.res
				r.social.snaps[bob] = graph.Snapshot{Muted: map[string]bool{alice: true}}
			})
			ctx, info := logger.WithRequestInfo(context.Background())
			if _, err := r.svc.Send(ctx, alice, toUser(key1, bob, "a secret sentence")); err != nil {
				t.Fatal(err)
			}
			want := map[string]any{fieldKind: kindSend, fieldState: tt.state, fieldSilent: true, fieldReplay: false, fieldConvHash: logger.HashUID(convID)}
			for k, v := range want {
				if got, _ := info.Get(k); got != v {
					t.Errorf("%s = %v, want %v", k, got, v)
				}
			}
			for _, a := range info.Fields() {
				s := fmt.Sprint(a.Value.Any())
				for _, secret := range []string{"a secret sentence", alice, bob, convID, MessageID(alice, key1)} {
					if strings.Contains(s, secret) {
						t.Errorf("log field %s=%q leaks %q", a.Key, s, secret)
					}
				}
			}
		})
	}
}

// Failing collaborators surface as errors, never as a delivered message.
func TestSend_LookupFailures(t *testing.T) {
	boom := errors.New("backend down")
	tests := []struct {
		name string
		mut  func(*rig)
	}{
		{"graph", func(r *rig) { r.social.err = boom }},
		{"directory", func(r *rig) { r.profs.err = boom }},
		{"caller profile missing", func(r *rig) { delete(r.profs.profiles, alice) }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := newRig(t, tt.mut)
			_, err := r.svc.Send(context.Background(), alice, toUser(key1, bob, "hi"))
			if err == nil || apierr.ToConnect(err).Code() != connect.CodeInternal {
				t.Fatalf("err = %v, want internal", err)
			}
			if len(r.repo.sends) != 0 || len(r.events.got) != 0 {
				t.Error("a failed lookup still sent")
			}
		})
	}
}

// An unconfigured service refuses to send rather than panic.
func TestSend_NotConfigured(t *testing.T) {
	svc := New(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), Deps{})
	if _, err := svc.Send(context.Background(), alice, toUser(key1, bob, "hi")); err == nil {
		t.Fatalf("err = %v, want a configuration error", err)
	}
}
