package messaging

import (
	"bytes"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// FEATURE_E2EE_REQUIRED (P6 §1.1, Task 1.A): with the flag effective for the sender or the recipient, every plaintext
// SendMessage is refused with ENCRYPTION_REQUIRED, into a conversation that is not encrypted yet, for a first message or
// a request, and for a post share. The refusal is the send transaction's, after every CANNOT_MESSAGE refusal and before
// any write; it costs no read.

// requiredSpec is FEATURE_E2EE_REQUIRED in mode m, its allowlist uids when m is allowlist.
func requiredSpec(m flags.Mode, uids ...string) flags.Spec {
	s := flags.Spec{Name: E2EERequiredFlag, Mode: m, Allowlist: map[string]struct{}{}}
	for _, u := range uids {
		s.Allowlist[u] = struct{}{}
	}
	return s
}

// requiredRig is a rig with messaging on for everyone, e2ee_dm on for the e2ee uids only (each with one active device),
// e2ee_required as given, coupled as the composition root couples them (e2ee_dm and e2ee_required each need messaging
// only), and mutual follows between alice and bob.
func requiredRig(t *testing.T, required flags.Spec, e2ee []string, mut func(*rig)) *rig {
	t.Helper()
	dm := flags.Spec{Name: keys.FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{}}
	for _, u := range e2ee {
		dm.Allowlist[u] = struct{}{}
	}
	return newRig(t, func(r *rig) {
		r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, dm, required).
			Require(keys.FlagName, FlagName).Require(E2EERequiredFlag, FlagName)
		r.social.snaps[alice] = graph.Snapshot{Following: map[string]bool{bob: true}}
		r.social.snaps[bob] = graph.Snapshot{Following: map[string]bool{alice: true}}
		for _, u := range e2ee {
			r.devices.active[u] = []string{u + "-device-000001"}
		}
		if mut != nil {
			mut(r)
		}
	})
}

// plainConv is an ACCEPTED alice-bob conversation that is not encrypted.
func plainConv() ConvDoc {
	return ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted}
}

// wantRequiredRefusal checks one policy refusal: ENCRYPTION_REQUIRED with exactly meta, the request line's outcome and
// policy fields, and nothing pushed, evicted or stored.
func wantRequiredRefusal(t *testing.T, r *rig, info *logger.RequestInfo, err error, convID string, meta map[string]string) {
	t.Helper()
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, meta)
	if _, _, got := reasonOf(t, err); len(got) != len(meta) {
		t.Errorf("metadata = %v, want exactly %v", got, meta)
	}
	if v, _ := info.Get(fieldOutcome); v != outcomeEncryptionRequired {
		t.Errorf("outcome = %v, want %q", v, outcomeEncryptionRequired)
	}
	if v, _ := info.Get(fieldPolicy); v != policyRequired {
		t.Errorf("policy = %v, want %q", v, policyRequired)
	}
	if len(r.events.got)+len(r.badge.got) != 0 {
		t.Errorf("a refused send pushed %d events / evicted %d badges", len(r.events.got), len(r.badge.got))
	}
	if n := len(r.repo.msgs[convID]); n != 0 {
		t.Errorf("a refused send stored %d messages", n)
	}
}

// TestSendRequired_Matrix: required off / allowlisted for alice / allowlisted for bob / on, x alice (the sender) in the
// e2ee_dm cohort or not, x bob (the recipient) in it (and so able to encrypt) or not, x a new, a plaintext or an MLS
// conversation, x a plaintext or an encrypted request. Plaintext into MLS is ENCRYPTION_REQUIRED as before, without the
// policy field; plaintext elsewhere is refused exactly when e2ee_required is effective for the sender or the recipient
// (effective: e2ee_required and messaging on for that uid, whatever e2ee_dm says: fail closed); an encrypted send at the
// current pair always passes, and
// mls_init keeps its own flag rules.
func TestSendRequired_Matrix(t *testing.T) {
	convID := ConversationID(alice, bob)
	modes := []struct {
		name  string
		spec  flags.Spec
		rawOn map[string]bool // uids the raw flag is on for
	}{
		{"required off", requiredSpec(flags.Off), map[string]bool{}},
		{"required allowlist alice", requiredSpec(flags.Allowlist, alice), map[string]bool{alice: true}},
		{"required allowlist bob", requiredSpec(flags.Allowlist, bob), map[string]bool{bob: true}},
		{"required on", requiredSpec(flags.On), map[string]bool{alice: true, bob: true}},
	}
	convs := []struct {
		name string
		doc  *ConvDoc
	}{
		{"new", nil},
		{"plaintext", func() *ConvDoc { c := plainConv(); return &c }()},
		{"mls", func() *ConvDoc { c := mlsConv(1, 1); return &c }()},
	}
	for _, mode := range modes {
		for _, senderE2EE := range []bool{false, true} {
			for _, peerE2EE := range []bool{false, true} {
				for _, cv := range convs {
					for _, encrypted := range []bool{false, true} {
						name := mode.name + "/sender e2ee " + boolWord(senderE2EE) + "/peer e2ee " + boolWord(peerE2EE) + "/" + cv.name + "/" + map[bool]string{false: "plaintext", true: "encrypted"}[encrypted]
						t.Run(name, func(t *testing.T) {
							var e2ee []string
							if senderE2EE {
								e2ee = append(e2ee, alice)
							}
							if peerE2EE {
								e2ee = append(e2ee, bob)
							}
							r := requiredRig(t, mode.spec, e2ee, func(r *rig) {
								if cv.doc != nil {
									r.repo.convs[convID] = *cv.doc
								}
							})
							req := toUser(key1, bob, "hi")
							switch {
							case encrypted && cv.name == "mls":
								req = encTo(key1, convID, false, 1, 1, "sealed")
							case encrypted:
								req = initSend(key1, "", "sealed", bob+"-device-000001")
							}
							ctx, info := logger.WithRequestInfo(verifiedCtx())
							_, err := r.svc.Send(ctx, alice, req)

							effective := mode.rawOn[alice] || mode.rawOn[bob]
							switch {
							case !encrypted && cv.name == "mls":
								// The existing rule, unchanged: the conversation's own encryption, not the policy.
								wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, map[string]string{"conversation_id": convID})
								if v, ok := info.Get(fieldPolicy); ok {
									t.Errorf("policy = %v on the conversation rule, want absent", v)
								}
							case !encrypted && effective:
								wantRequiredRefusal(t, r, info, err, convID, map[string]string{"conversation_id": convID})
								if len(r.repo.sends) != 1 || !r.repo.sends[0].EncryptionRequired {
									t.Errorf("SendParams.EncryptionRequired not set (sends %d)", len(r.repo.sends))
								}
							case !encrypted:
								if err != nil {
									t.Fatalf("plaintext send refused with required not effective: %v", err)
								}
								if r.repo.sends[0].EncryptionRequired {
									t.Error("SendParams.EncryptionRequired set with required not effective")
								}
							case cv.name == "mls":
								if err != nil {
									t.Fatalf("an encrypted send at the current pair was refused: %v", err)
								}
							case !senderE2EE:
								wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": keys.FlagName})
							case !peerE2EE:
								wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
							default:
								if err != nil {
									t.Fatalf("mls_init refused: %v", err)
								}
							}
							if !encrypted {
								// A plaintext send never asks the key directory: the policy reads only flags in memory.
								if n := len(r.devices.calls) + len(r.devices.allCalls); n != 0 {
									t.Errorf("a plaintext send made %d device lookups", n)
								}
							}
						})
					}
				}
			}
		}
	}
}

func boolWord(b bool) string {
	if b {
		return "in"
	}
	return "out"
}

// plaintext to a NONE conversation is refused when required is on for the sender, and for the recipient only; addressed
// by conversation id the answer carries no metadata.
func TestSendRequired_SenderOrRecipient(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, tc := range []struct {
		name     string
		required flags.Spec
		req      *messagingv1.SendMessageRequest
		meta     map[string]string
	}{
		{"for the sender, by recipient", requiredSpec(flags.Allowlist, alice), toUser(key1, bob, "hi"), map[string]string{"conversation_id": convID}},
		{"for the sender, by conversation id", requiredSpec(flags.Allowlist, alice), toConv(key1, convID, "hi"), map[string]string{}},
		{"for the recipient, by recipient", requiredSpec(flags.Allowlist, bob), toUser(key1, bob, "hi"), map[string]string{"conversation_id": convID}},
		{"for the recipient, by conversation id", requiredSpec(flags.Allowlist, bob), toConv(key1, convID, "hi"), map[string]string{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, tc.required, []string{alice, bob}, func(r *rig) { r.repo.convs[convID] = plainConv() })
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, err := r.svc.Send(ctx, alice, tc.req)
			wantRequiredRefusal(t, r, info, err, convID, tc.meta)
			if got := r.repo.convs[convID]; got.Encryption != "" || got.RequestCount != 0 {
				t.Errorf("conversation changed: %+v", got)
			}
		})
	}
}

// A first message (no conversation yet) and a message request (no follow-back) are refused the same way, and the refusal
// comes before the new conversation's recipient read (the fake's in-transaction users read is never made).
func TestSendRequired_FirstMessageAndRequest(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, tc := range []struct {
		name string
		mut  func(*rig)
	}{
		{"first message, mutual", nil},
		{"message request", func(r *rig) { r.social.snaps[bob] = graph.Snapshot{} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, requiredSpec(flags.On), []string{alice, bob}, func(r *rig) {
				r.repo.sendRes = SendResult{Created: true}
				if tc.mut != nil {
					tc.mut(r)
				}
			})
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hello"))
			wantRequiredRefusal(t, r, info, err, convID, map[string]string{"conversation_id": convID})
			if _, ok := r.repo.convs[convID]; ok {
				t.Error("a refused first message created the conversation")
			}
			if r.txProfs.txCalls != 0 {
				t.Errorf("the refusal came after %d recipient users reads, want none", r.txProfs.txCalls)
			}
		})
	}
}

// A plaintext post share (shared_post_id, no ciphertext) is refused under required, after its post check, recording no
// share.
func TestSendRequired_PostShareRefused(t *testing.T) {
	convID := ConversationID(alice, bob)
	r := newShareRig(t, flags.Spec{Name: postsFlagName, Mode: flags.On}, flags.Spec{Name: PostShareFlagName, Mode: flags.On},
		flags.Spec{Name: keys.FlagName, Mode: flags.On}, requiredSpec(flags.On))
	r.social.snaps[alice] = graph.Snapshot{Following: map[string]bool{bob: true}}
	r.social.snaps[bob] = graph.Snapshot{Following: map[string]bool{alice: true}}
	ctx, info := logger.WithRequestInfo(verifiedCtx())
	_, err := r.svc.Send(ctx, alice, sharing(key1, bob, "look", postOrig))
	wantRequiredRefusal(t, r.rig, info, err, convID, map[string]string{"conversation_id": convID})
	if len(r.shares.calls) != 0 {
		t.Errorf("a refused share was recorded: %v", r.shares.calls)
	}
}

// Ciphertext and mls_init still pass under required: an encrypted send at the current pair of an MLS conversation, and an
// mls_init into a new or a plaintext conversation.
func TestSendRequired_CiphertextAndInitPass(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, tc := range []struct {
		name string
		conv *ConvDoc
		req  *messagingv1.SendMessageRequest
	}{
		{"ciphertext into MLS", func() *ConvDoc { c := mlsConv(2, 3); return &c }(), encTo(key1, convID, true, 2, 3, "sealed")},
		{"mls_init into a new conversation", nil, initSend(key1, "", "sealed", bob+"-device-000001")},
		{"mls_init into a plaintext conversation", func() *ConvDoc { c := plainConv(); return &c }(), initSend(key1, convID, "sealed", bob+"-device-000001")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, requiredSpec(flags.On), []string{alice, bob}, func(r *rig) {
				if tc.conv != nil {
					r.repo.convs[convID] = *tc.conv
				}
			})
			if _, err := r.svc.Send(verifiedCtx(), alice, tc.req); err != nil {
				t.Fatalf("refused under required: %v", err)
			}
		})
	}
}

// Required off keeps today's behaviour: a plaintext first message, request and reply all pass, and the transaction is not
// asked to refuse.
func TestSendRequired_OffKeepsToday(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, mode := range []flags.Spec{requiredSpec(flags.Off), requiredSpec(flags.Allowlist), requiredSpec(flags.Percent)} {
		for name, conv := range map[string]*ConvDoc{"new": nil, "plaintext": func() *ConvDoc { c := plainConv(); return &c }()} {
			t.Run(string(mode.Mode)+"/"+name, func(t *testing.T) {
				r := requiredRig(t, mode, []string{alice, bob}, func(r *rig) {
					if conv != nil {
						r.repo.convs[convID] = *conv
					}
				})
				if _, err := r.svc.Send(verifiedCtx(), alice, toUser(key1, bob, "hi")); err != nil {
					t.Fatalf("send: %v", err)
				}
				if r.repo.sends[0].EncryptionRequired {
					t.Error("EncryptionRequired set with the flag not on for either user")
				}
			})
		}
	}
}

// The refusal comes after CanMessage's rules: a blocked pair (either way), the recipient's DM policy, a recipient without
// messaging and a gone peer still answer the one CANNOT_MESSAGE bytes, so only someone allowed to message a user learns
// that user's cohort.
func TestSendRequired_AfterCanMessage(t *testing.T) {
	convID := ConversationID(alice, bob)
	ref := cannotMessage()
	seedPlain := func(r *rig) { r.repo.convs[convID] = plainConv() }
	blockedByBob := func(r *rig) { r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}} }
	aliceBlocks := func(r *rig) { r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}} }
	bobOff := func(r *rig) {
		r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{alice: {}}},
			flags.Spec{Name: keys.FlagName, Mode: flags.On}, requiredSpec(flags.On))
	}
	both := func(fs ...func(*rig)) func(*rig) {
		return func(r *rig) {
			for _, f := range fs {
				f(r)
			}
		}
	}
	for _, tc := range []struct {
		name string
		mut  func(*rig)
		req  *messagingv1.SendMessageRequest
	}{
		{"the recipient blocked the caller, new conversation", blockedByBob, toUser(key1, bob, "hi")},
		{"the recipient blocked the caller, by conversation id", both(seedPlain, blockedByBob), toConv(key1, convID, "hi")},
		{"the caller blocked the recipient, new conversation", aliceBlocks, toUser(key1, bob, "hi")},
		{"the caller blocked the recipient, by conversation id", both(seedPlain, aliceBlocks), toConv(key1, convID, "hi")},
		{"the recipient's DM policy, new conversation", func(r *rig) {
			r.social.snaps[bob] = graph.Snapshot{}
			p := r.profs.profiles[bob]
			p.DMPolicy = identity.DMPolicyFollowingOnly
			r.profs.profiles[bob] = p
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}, flags.Spec{Name: keys.FlagName, Mode: flags.On},
				requiredSpec(flags.On), flags.Spec{Name: identity.DMPolicyFlag, Mode: flags.On})
		}, toUser(key1, bob, "hi")},
		{"the recipient's messaging is off, new conversation", bobOff, toUser(key1, bob, "hi")},
		{"the recipient's messaging is off, by conversation id", both(seedPlain, bobOff), toConv(key1, convID, "hi")},
		{"the peer is gone, by recipient", func(r *rig) {
			c := plainConv()
			c.Gone = []string{bob}
			r.repo.convs[convID] = c
		}, toUser(key1, bob, "hi")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, requiredSpec(flags.On), []string{alice, bob}, tc.mut)
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, err := r.svc.Send(ctx, alice, tc.req)
			if !bytes.Equal(wireBytes(t, err), wireBytes(t, ref)) {
				t.Fatalf("got %v, want the CANNOT_MESSAGE bytes", err)
			}
			if v, ok := info.Get(fieldPolicy); ok {
				t.Errorf("policy = %v on a CANNOT_MESSAGE refusal, want absent", v)
			}
		})
	}
}

// A plaintext message stored before required was switched on replays under its key (no write, no push); the same key with
// other text is the reused-key answer.
func TestSendRequired_ReplayWins(t *testing.T) {
	convID := ConversationID(alice, bob)
	msgID := MessageID(alice, key1)
	stored := MsgDoc{SenderID: alice, Text: "hi", State: msgVisible, RequestHash: requestHash(convID, "hi", "")}
	for _, tc := range []struct {
		name   string
		text   string
		reused bool
	}{
		{"same request", "hi", false},
		{"same key, other text", "other", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, requiredSpec(flags.On), []string{alice, bob}, func(r *rig) {
				r.repo.convs[convID] = plainConv()
				r.repo.msgs = map[string][]MessageRow{convID: {{ID: msgID, MsgDoc: stored}}}
			})
			resp, err := r.svc.Send(verifiedCtx(), alice, toConv(key1, convID, tc.text))
			if tc.reused {
				wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if resp.GetMessage().GetId() != msgID || resp.GetMessage().GetText() != "hi" || len(r.events.got) != 0 {
				t.Errorf("replay = %v, events %d", resp.GetMessage(), len(r.events.got))
			}
		})
	}
}

// The refusal fails closed (6-1 security review M2): with e2ee_required effective and e2ee_dm off (killed or narrowed),
// plaintext is still refused, for the sender and for the recipient; mls_init is refused by its own e2ee_dm rule, so the
// pair can exchange nothing. Turning e2ee_dm off never reopens plaintext; the lever that does is e2ee_required itself.
func TestSendRequired_FailsClosedWithoutE2EEDM(t *testing.T) {
	convID := ConversationID(alice, bob)
	for _, tc := range []struct {
		name     string
		e2ee     []string // e2ee_dm cohort
		required flags.Spec
	}{
		{"e2ee_dm off for everyone, required for the sender", nil, requiredSpec(flags.Allowlist, alice)},
		{"e2ee_dm off for everyone, required for the recipient", nil, requiredSpec(flags.Allowlist, bob)},
		{"e2ee_dm narrowed away from the required sender", []string{bob}, requiredSpec(flags.Allowlist, alice)},
		{"e2ee_dm narrowed away from the required recipient", []string{alice}, requiredSpec(flags.Allowlist, bob)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for name, conv := range map[string]*ConvDoc{"new": nil, "plaintext": func() *ConvDoc { c := plainConv(); return &c }()} {
				t.Run(name, func(t *testing.T) {
					r := requiredRig(t, tc.required, tc.e2ee, func(r *rig) {
						if conv != nil {
							r.repo.convs[convID] = *conv
						}
					})
					ctx, info := logger.WithRequestInfo(verifiedCtx())
					_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hi"))
					wantRequiredRefusal(t, r, info, err, convID, map[string]string{"conversation_id": convID})
				})
			}
			// mls_init: refused by e2ee_dm (caller off: FEATURE_DISABLED; recipient off: CANNOT_MESSAGE), as today.
			r := requiredRig(t, tc.required, tc.e2ee, nil)
			_, err := r.svc.Send(verifiedCtx(), alice, initSend(key1, "", "sealed", bob+"-device-000001"))
			if err == nil {
				t.Fatal("mls_init passed with e2ee_dm off for a participant")
			}
		})
	}
}

// Required on with messaging off for the sender: messaging refuses first (FEATURE_DISABLED "messaging", before any read);
// with messaging off for the recipient: the one CANNOT_MESSAGE. The policy never answers in either case.
func TestSendRequired_MessagingOffAnswersFirst(t *testing.T) {
	for _, tc := range []struct {
		name   string
		reason commonv1.ErrorReason
		allow  string // the only uid with messaging on
	}{
		{"sender off", commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, bob},
		{"recipient off", commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, alice},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := requiredRig(t, requiredSpec(flags.On), []string{alice, bob}, func(r *rig) {
				r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{tc.allow: {}}},
					flags.Spec{Name: keys.FlagName, Mode: flags.On}, requiredSpec(flags.On)).
					Require(keys.FlagName, FlagName).Require(E2EERequiredFlag, FlagName)
			})
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, err := r.svc.Send(ctx, alice, toUser(key1, bob, "hi"))
			_, reason, _ := reasonOf(t, err)
			if reason != tc.reason {
				t.Fatalf("reason = %v (%v), want %v", reason, err, tc.reason)
			}
			if v, ok := info.Get(fieldPolicy); ok {
				t.Errorf("policy = %v, want absent", v)
			}
		})
	}
}
