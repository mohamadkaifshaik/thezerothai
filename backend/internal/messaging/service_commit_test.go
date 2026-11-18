package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// CommitConversation (Task 5) over the fake repo, which runs commitTx's order (Commit in fakes_test.go) on the same pure
// rules (commitConvRefusal, isCommitRetry, commitPairStale).

func ckey(n int) string { return fmt.Sprintf("commit-key-%08d", n) }

// commitReq is a normal commit built on (gen, epoch) with bytes "commit:"+tag and, when ids are given, welcome
// "welcome:"+tag for them.
func commitReq(key, convID string, gen, epoch uint64, tag string, ids ...string) *messagingv1.CommitConversationRequest {
	r := &messagingv1.CommitConversationRequest{
		IdempotencyKey: key, ConversationId: convID, MlsGeneration: gen, MlsEpoch: epoch, Commit: []byte("commit:" + tag),
		WelcomeDeviceIds: ids,
	}
	if len(ids) > 0 {
		r.Welcome = []byte("welcome:" + tag)
	}
	return r
}

// resetReq is a reset of generation gen (mls_epoch left 0: ignored) welcoming ids.
func resetReq(key, convID string, gen uint64, tag string, ids ...string) *messagingv1.CommitConversationRequest {
	r := commitReq(key, convID, gen, 0, tag, ids...)
	r.Reset_ = true
	return r
}

// commitConvAt is the alice-bob conversation, ACCEPTED, MLS at (gen, epoch), rev 7.
func commitConvAt(gen, epoch int64, at time.Time) ConvDoc {
	return ConvDoc{
		Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, CreatedAt: at.Add(-time.Hour), UpdatedAt: at.Add(-time.Minute),
		Encryption: encMLS, MlsGen: gen, MlsEpoch: epoch, Rev: 7,
	}
}

// commitRig is e2eeRig with the alice-bob conversation MLS at (gen, epoch).
func commitRig(t *testing.T, gen, epoch int64, mut func(*rig)) (*rig, string) {
	t.Helper()
	convID := ConversationID(alice, bob)
	r := e2eeRig(t, nil, func(r *rig) {
		r.repo.convs[convID] = commitConvAt(gen, epoch, r.now)
		if mut != nil {
			mut(r)
		}
	})
	return r, convID
}

func (r *rig) commit(t *testing.T, uid string, req *messagingv1.CommitConversationRequest) (*messagingv1.CommitConversationResponse, error) {
	t.Helper()
	return r.svc.Commit(verifiedCtx(), uid, req)
}

func (r *rig) mustCommit(t *testing.T, uid string, req *messagingv1.CommitConversationRequest) *messagingv1.CommitConversationResponse {
	t.Helper()
	resp, err := r.commit(t, uid, req)
	if err != nil {
		t.Fatalf("commit: %v", err)
	}
	return resp
}

func wantPair(t *testing.T, resp *messagingv1.CommitConversationResponse, gen, epoch uint64) {
	t.Helper()
	if resp.GetMlsGeneration() != gen || resp.GetMlsEpoch() != epoch {
		t.Errorf("answered pair (%d, %d), want (%d, %d)", resp.GetMlsGeneration(), resp.GetMlsEpoch(), gen, epoch)
	}
}

func wantStale(t *testing.T, err error, gen, epoch int64) {
	t.Helper()
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH,
		map[string]string{"generation": fmt.Sprint(gen), "epoch": fmt.Sprint(epoch)})
	if _, _, meta := reasonOf(t, err); meta["conversation_id"] != "" {
		t.Errorf("STALE_EPOCH of a commit carries conversation_id %q", meta["conversation_id"])
	}
}

// Flag (messaging per caller; e2ee_dm is not needed) and verified email, before any lookup.
func TestCommit_FlagAndEmailBeforeAnyLookup(t *testing.T) {
	convID := ConversationID(alice, bob)
	t.Run("messaging off for the caller", func(t *testing.T) {
		r, _ := commitRig(t, 1, 1, func(r *rig) {
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{bob: {}}})
		})
		_, err := r.commit(t, alice, commitReq(ckey(1), convID, 1, 1, "c"))
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, map[string]string{"feature": FlagName})
		if r.repo.commitCalls != 0 || r.repo.gets != 0 {
			t.Error("a caller with messaging off reached the repo")
		}
	})
	t.Run("e2ee_dm off for both still commits", func(t *testing.T) {
		r, _ := commitRig(t, 1, 1, func(r *rig) {
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On})
		})
		wantPair(t, r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "c")), 1, 2)
	})
	t.Run("email not verified", func(t *testing.T) {
		r, _ := commitRig(t, 1, 1, func(r *rig) { r.allowAnon = false })
		_, err := r.svc.Commit(context.Background(), alice, commitReq(ckey(1), convID, 1, 1, "c"))
		wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED, nil)
		if r.repo.commitCalls != 0 {
			t.Error("an unverified caller reached the repo")
		}
	})
}

// Step 1: the key, the conversation id and the pair's form are VALIDATION before any lookup; the other fields are not
// (they are answered after retry recognition, see TestCommit_FieldsAnswerAfterRetryAndBeforeThePair).
func TestCommit_Step1BeforeAnyLookup(t *testing.T) {
	convID := ConversationID(alice, bob)
	big := uint64(math.MaxInt64)
	tests := []struct {
		name  string
		req   *messagingv1.CommitConversationRequest
		field string
	}{
		{"short key", commitReq("short", convID, 1, 1, "c"), "idempotency_key"},
		{"bad conversation id", commitReq(ckey(1), "ABC", 1, 1, "c"), "conversation_id"},
		{"generation 0", commitReq(ckey(1), convID, 0, 1, "c"), "mls_generation"},
		{"generation 2^63 - 1", commitReq(ckey(1), convID, big, 1, "c"), "mls_generation"},
		{"generation 2^64 - 1", commitReq(ckey(1), convID, math.MaxUint64, 1, "c"), "mls_generation"},
		{"reset generation 0", resetReq(ckey(1), convID, 0, "c", devBob1), "mls_generation"},
		{"reset generation 2^63 - 1", resetReq(ckey(1), convID, big, "c", devBob1), "mls_generation"},
		{"epoch 0", commitReq(ckey(1), convID, 1, 0, "c"), "mls_epoch"},
		{"epoch 2^63", commitReq(ckey(1), convID, 1, big+1, "c"), "mls_epoch"},
		{"key before conversation id", commitReq("short", "ABC", 0, 0, ""), "idempotency_key"},
		{"conversation id before the pair", commitReq(ckey(1), "ABC", 0, 0, ""), "conversation_id"},
		{"generation before epoch", commitReq(ckey(1), convID, 0, 0, ""), "mls_generation"},
		{"pair before the commit bytes", commitReq(ckey(1), convID, 1, 0, ""), "mls_epoch"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r, _ := commitRig(t, 1, 1, nil)
			_, err := r.commit(t, alice, tc.req)
			wantField(t, err, tc.field)
			if n := r.repo.commitCalls + r.repo.gets + r.social.calls + len(r.devices.calls); n != 0 {
				t.Errorf("step 1 refusal cost %d lookups", n)
			}
		})
	}
	t.Run("pair form edges pass", func(t *testing.T) {
		for _, req := range []*messagingv1.CommitConversationRequest{
			commitReq(ckey(1), convID, big-1, big, "c"), // the largest legal pair: stale here, but past step 1
			resetReq(ckey(2), convID, big-1, "c", devBob1),
		} {
			r, _ := commitRig(t, 1, 1, nil)
			_, err := r.commit(t, alice, req)
			wantStale(t, err, 1, 1)
		}
	})
	t.Run("a reset ignores mls_epoch", func(t *testing.T) {
		for _, e := range []uint64{0, 5, math.MaxUint64} {
			r, _ := commitRig(t, 1, 3, nil)
			req := resetReq(ckey(1), convID, 1, "c", devBob1)
			req.MlsEpoch = e
			wantPair(t, r.mustCommit(t, alice, req), 2, 1)
		}
	})
}

// Step 2: NOT_FOUND for an unknown conversation and a non-participant (one byte-identical answer), VALIDATION
// conversation_id for a plaintext conversation, CANNOT_MESSAGE (a send's bytes) for a gone peer and a block in either
// direction. Every one comes before retry recognition, the field verdict and the device check: the same bytes whatever
// the devices and fields, and no device lookup.
func TestCommit_Step2Refusals(t *testing.T) {
	convID := ConversationID(alice, bob)
	notFoundBytes := wireBytes(t, notFound())
	cannotBytes := wireBytes(t, cannotMessage())
	variants := map[string]*messagingv1.CommitConversationRequest{
		"good devices":      commitReq(ckey(1), convID, 1, 1, "c", devBob1),
		"unknown device":    commitReq(ckey(1), convID, 1, 1, "c", devCarol1),
		"stale pair":        commitReq(ckey(1), convID, 1, 9, "c", devBob1),
		"bad fields":        {IdempotencyKey: ckey(1), ConversationId: convID, MlsGeneration: 1, MlsEpoch: 1},
		"reset, no devices": resetReq(ckey(1), convID, 1, "c"),
	}
	cases := []struct {
		name   string
		caller string
		mut    func(*rig)
		want   []byte
		field  string
	}{
		{"unknown conversation", alice, func(r *rig) { delete(r.repo.convs, convID) }, notFoundBytes, ""},
		{"non-participant", carolUID, nil, notFoundBytes, ""},
		{"plaintext conversation", alice, func(r *rig) {
			c := r.repo.convs[convID]
			c.Encryption, c.MlsGen, c.MlsEpoch = "", 0, 0
			r.repo.convs[convID] = c
		}, nil, "conversation_id"},
		{"peer gone", alice, func(r *rig) {
			c := r.repo.convs[convID]
			c.Gone = []string{bob}
			r.repo.convs[convID] = c
		}, cannotBytes, ""},
		{"peer blocks the caller", alice, func(r *rig) {
			r.social.snaps[bob] = graph.Snapshot{Following: map[string]bool{alice: true}, Blocked: map[string]bool{alice: true}}
		}, cannotBytes, ""},
		{"caller blocks the peer", alice, func(r *rig) {
			r.social.snaps[alice] = graph.Snapshot{Following: map[string]bool{bob: true}, Blocked: map[string]bool{bob: true}}
		}, cannotBytes, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for vname, req := range variants {
				r, _ := commitRig(t, 1, 1, func(r *rig) {
					r.profs.profiles[carolUID] = activeProfile(carolUID, "carol", r.now.Add(-30*24*time.Hour))
					r.devices.active[carolUID] = []string{devCarol1}
					if tc.mut != nil {
						tc.mut(r)
					}
				})
				// A record of this pair from the caller with these bytes exists: a refusal still beats retry recognition.
				r.repo.commits = map[string]CommitDoc{convID + "/" + commitDocID(1, 1): {Data: []byte("commit:c"), SenderID: tc.caller}}
				before := r.repo.convs[convID]
				_, err := r.commit(t, tc.caller, req)
				if tc.field != "" {
					wantField(t, err, tc.field)
				} else if got := wireBytes(t, err); !bytes.Equal(got, tc.want) {
					t.Errorf("%s: wire = %q, want %q", vname, got, tc.want)
				}
				if len(r.devices.calls) != 0 {
					t.Errorf("%s: device lookups %v before a step-2 refusal", vname, r.devices.calls)
				}
				if after, ok := r.repo.convs[convID]; ok && (after.MlsGen != before.MlsGen || after.MlsEpoch != before.MlsEpoch) {
					t.Errorf("%s: conversation moved on a refusal", vname)
				}
				if len(r.repo.welcomes) != 0 {
					t.Errorf("%s: welcomes stored on a refusal", vname)
				}
			}
		})
	}
	t.Run("same CANNOT_MESSAGE as a send", func(t *testing.T) {
		r, _ := commitRig(t, 1, 1, func(r *rig) {
			r.social.snaps[bob] = graph.Snapshot{Blocked: map[string]bool{alice: true}}
		})
		_, cerr := r.commit(t, alice, commitReq(ckey(1), convID, 1, 1, "c"))
		_, serr := r.svc.Send(verifiedCtx(), alice, encByConvUnit(convID, 1, 1))
		if !bytes.Equal(wireBytes(t, cerr), wireBytes(t, serr)) {
			t.Errorf("commit %q vs send %q", wireBytes(t, cerr), wireBytes(t, serr))
		}
	})
}

func encByConvUnit(convID string, gen, epoch uint64) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{
		IdempotencyKey: key1, Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID},
		Ciphertext: []byte("ct"), ReportCommitment: testCommitment, MlsGeneration: gen, MlsEpoch: epoch,
	}
}

// A normal commit moves (g, e) to (g, e + 1), stores the record (g, e) and one welcome per device labelled (g, e),
// replaces each device's earlier welcome, and leaves rev alone; the cache gets the new pair. No welcome is fine.
func TestCommit_StoresTheCommit(t *testing.T) {
	r, convID := commitRig(t, 2, 4, nil)
	before := r.repo.convs[convID]
	// An earlier welcome of devBob1 for this conversation (an older pair) and one for another conversation.
	r.repo.welcomes = []fakeWelcome{
		{Owner: bob, ID: "old", WelcomeDoc: WelcomeDoc{DeviceID: devBob1, ConvID: convID, Gen: 2, Epoch: 1}},
		{Owner: bob, ID: "other-conv", WelcomeDoc: WelcomeDoc{DeviceID: devBob1, ConvID: "other", Gen: 1, Epoch: 0}},
	}
	resp := r.mustCommit(t, alice, commitReq(ckey(1), convID, 2, 4, "c", devBob1, devAlice2))
	wantPair(t, resp, 2, 5)
	got := r.repo.convs[convID]
	if got.MlsGen != 2 || got.MlsEpoch != 5 || got.Rev != before.Rev || got.Encryption != encMLS {
		t.Errorf("conversation = %+v", got)
	}
	if !got.UpdatedAt.Equal(r.now) {
		t.Errorf("updatedAt = %v, want %v", got.UpdatedAt, r.now)
	}
	rec, ok := r.repo.commits[convID+"/"+commitDocID(2, 4)]
	if !ok || string(rec.Data) != "commit:c" || rec.SenderID != alice || rec.Gen != 2 || rec.Epoch != 4 || !rec.ExpireAt.Equal(rec.CreatedAt.Add(CommitRetention)) {
		t.Errorf("record = %+v (found %v)", rec, ok)
	}
	if len(r.repo.commits) != 1 {
		t.Errorf("records = %d, want 1", len(r.repo.commits))
	}
	want := map[string]string{bob + "|" + devBob1: welcomeDocID(convID, 2, 4, devBob1), alice + "|" + devAlice2: welcomeDocID(convID, 2, 4, devAlice2), bob + "|other-conv": "other-conv"}
	if len(r.repo.welcomes) != len(want) {
		t.Fatalf("welcomes = %+v", r.repo.welcomes)
	}
	for _, w := range r.repo.welcomes {
		if w.ConvID == "other" {
			continue
		}
		k := w.Owner + "|" + w.DeviceID
		if want[k] != w.ID || w.Gen != 2 || w.Epoch != 4 || string(w.Data) != "welcome:c" {
			t.Errorf("welcome %s = %+v", k, w)
		}
	}
	if c, ok := r.svc.convs.Get(convID); !ok || c.MlsEpoch != 5 {
		t.Errorf("cache = %+v, %v; want the new pair", c, ok)
	}

	// A commit without a welcome (a remove or a self-update) looks up no device.
	calls := len(r.devices.calls)
	wantPair(t, r.mustCommit(t, bob, commitReq(ckey(2), convID, 2, 5, "remove")), 2, 6)
	if len(r.devices.calls) != calls {
		t.Error("a commit without a welcome looked up devices")
	}
	// The caller's own other device only: fine for a commit.
	wantPair(t, r.mustCommit(t, alice, commitReq(ckey(3), convID, 2, 6, "self", devAlice2)), 2, 7)
}

// A reset of the current generation g: the record (g + 1, 0), welcomes labelled (g + 1, 0), the conversation at (g + 1, 1);
// it must address at least one ACTIVE device of the PEER; a single-device caller (no other own device) can reset.
func TestCommit_Reset(t *testing.T) {
	t.Run("stored", func(t *testing.T) {
		r, convID := commitRig(t, 3, 9, func(r *rig) { r.devices.active[alice] = []string{devAlice1} })
		resp := r.mustCommit(t, alice, resetReq(ckey(1), convID, 3, "r", devBob2))
		wantPair(t, resp, 4, 1)
		got := r.repo.convs[convID]
		if got.MlsGen != 4 || got.MlsEpoch != 1 || got.Rev != 7 {
			t.Errorf("conversation = %+v", got)
		}
		if rec, ok := r.repo.commits[convID+"/"+commitDocID(4, 0)]; !ok || rec.Gen != 4 || rec.Epoch != 0 || string(rec.Data) != "commit:r" {
			t.Errorf("reset record = %+v, %v", rec, ok)
		}
		if len(r.repo.welcomes) != 1 || r.repo.welcomes[0].Gen != 4 || r.repo.welcomes[0].Epoch != 0 || r.repo.welcomes[0].Owner != bob ||
			r.repo.welcomes[0].ID != welcomeDocID(convID, 4, 0, devBob2) {
			t.Errorf("welcomes = %+v", r.repo.welcomes)
		}
	})
	t.Run("only the caller's devices", func(t *testing.T) {
		r, convID := commitRig(t, 1, 2, nil)
		_, err := r.commit(t, alice, resetReq(ckey(1), convID, 1, "r", devAlice2))
		wantField(t, err, "welcome_device_ids")
		if len(r.repo.commits) != 0 || r.repo.convs[convID].MlsGen != 1 {
			t.Error("a refused reset wrote")
		}
	})
	t.Run("an inactive peer device", func(t *testing.T) {
		r, convID := commitRig(t, 1, 2, nil)
		_, err := r.commit(t, alice, resetReq(ckey(1), convID, 1, "r", "bob-device-retired"))
		wantField(t, err, "welcome_device_ids")
	})
	t.Run("wrong generation", func(t *testing.T) {
		for _, g := range []uint64{1, 3} {
			r, convID := commitRig(t, 2, 5, nil)
			_, err := r.commit(t, alice, resetReq(ckey(1), convID, g, "r", devBob1))
			wantStale(t, err, 2, 5)
			if len(r.repo.commits) != 0 || len(r.repo.welcomes) != 0 {
				t.Error("a stale reset wrote")
			}
		}
	})
	t.Run("a second reset of the same generation", func(t *testing.T) {
		r, convID := commitRig(t, 1, 2, nil)
		r.mustCommit(t, alice, resetReq(ckey(1), convID, 1, "first", devBob1))
		_, err := r.commit(t, bob, resetReq(ckey(2), convID, 1, "second", devAlice1))
		wantStale(t, err, 2, 1)
	})
}

// Step 3: a retry (same user, identical bytes, record exists and the conversation moved past it) answers the CURRENT pair
// and writes nothing, before the field verdict, the device check and the pair; anything else is not a retry.
func TestCommit_Retry(t *testing.T) {
	t.Run("commit after another commit landed", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, nil)
		req := commitReq(ckey(1), convID, 1, 1, "a", devBob1)
		r.mustCommit(t, alice, req)
		r.mustCommit(t, bob, commitReq(ckey(2), convID, 1, 2, "b"))
		// The welcomed device went inactive since: the retry still succeeds (retry beats the device check).
		r.devices.active[bob] = []string{devBob2}
		calls, welcomes := len(r.devices.calls), len(r.repo.welcomes)
		wantPair(t, r.mustCommit(t, alice, req), 1, 3)
		if len(r.repo.commits) != 2 || len(r.repo.welcomes) != welcomes || len(r.devices.calls) != calls {
			t.Errorf("a retry wrote or looked up: records %d welcomes %d device calls %d", len(r.repo.commits), len(r.repo.welcomes), len(r.devices.calls)-calls)
		}
		// The same key does not matter: the record's pair is the natural key.
		retry := commitReq(ckey(99), convID, 1, 1, "a", devBob1)
		wantPair(t, r.mustCommit(t, alice, retry), 1, 3)
	})
	t.Run("reset after another commit landed", func(t *testing.T) {
		r, convID := commitRig(t, 1, 4, nil)
		req := resetReq(ckey(1), convID, 1, "r", devBob1)
		r.mustCommit(t, alice, req)
		r.mustCommit(t, bob, commitReq(ckey(2), convID, 2, 1, "b"))
		wantPair(t, r.mustCommit(t, alice, req), 2, 2)
		if len(r.repo.commits) != 2 {
			t.Errorf("records = %d", len(r.repo.commits))
		}
	})
	t.Run("not a retry", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, nil)
		r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "a"))
		// Other bytes from the same user, and the same bytes from the other user: STALE_EPOCH.
		_, err := r.commit(t, alice, commitReq(ckey(2), convID, 1, 1, "other"))
		wantStale(t, err, 1, 2)
		_, err = r.commit(t, bob, commitReq(ckey(3), convID, 1, 1, "a"))
		wantStale(t, err, 1, 2)
		// The same bytes as a reset of the current generation: another record ((2, 0)), so not a retry; a new reset.
		wantPair(t, r.mustCommit(t, alice, resetReq(ckey(4), convID, 1, "a", devBob1)), 2, 1)
	})
	t.Run("a retry beats the field verdict", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, nil)
		r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "a"))
		bad := commitReq(ckey(1), convID, 1, 1, "a")
		bad.Welcome = []byte("w") // a welcome without device ids: VALIDATION, were it not a retry
		wantPair(t, r.mustCommit(t, alice, bad), 1, 2)
	})
	t.Run("a record at the current pair is a leftover, never a retry", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, nil)
		r.repo.commits = map[string]CommitDoc{convID + "/" + commitDocID(1, 1): {Data: []byte("commit:a"), SenderID: alice}}
		wantPair(t, r.mustCommit(t, alice, commitReq(ckey(1), convID, 1, 1, "a")), 1, 2)
		if r.repo.convs[convID].MlsEpoch != 2 {
			t.Error("the commit was answered as a retry of a leftover record")
		}
	})
}

// Step 4 then 5: the field verdict answers after step 2 and retry recognition but before the device check and the pair;
// the device check answers before STALE_EPOCH.
func TestCommit_FieldsAnswerAfterRetryAndBeforeThePair(t *testing.T) {
	tooBigWelcome := bytes.Repeat([]byte{1}, MaxWelcomeBytes+1)
	tests := []struct {
		name  string
		edit  func(*messagingv1.CommitConversationRequest)
		field string
	}{
		{"empty commit", func(q *messagingv1.CommitConversationRequest) { q.Commit = nil }, "commit"},
		{"commit too big", func(q *messagingv1.CommitConversationRequest) { q.Commit = bytes.Repeat([]byte{1}, MaxCommitBytes+1) }, "commit"},
		{"welcome without ids", func(q *messagingv1.CommitConversationRequest) { q.Welcome = []byte("w") }, "welcome_device_ids"},
		{"ids without welcome", func(q *messagingv1.CommitConversationRequest) { q.WelcomeDeviceIds = []string{devBob1} }, "welcome_device_ids"},
		{"welcome too big", func(q *messagingv1.CommitConversationRequest) {
			q.Welcome, q.WelcomeDeviceIds = tooBigWelcome, []string{devBob1}
		}, "welcome"},
		{"11 ids", func(q *messagingv1.CommitConversationRequest) {
			q.Welcome = []byte("w")
			for i := range 11 {
				q.WelcomeDeviceIds = append(q.WelcomeDeviceIds, fmt.Sprintf("device-%012d", i))
			}
		}, "welcome_device_ids"},
		{"duplicate ids", func(q *messagingv1.CommitConversationRequest) {
			q.Welcome, q.WelcomeDeviceIds = []byte("w"), []string{devBob1, devBob1}
		}, "welcome_device_ids"},
		{"malformed id", func(q *messagingv1.CommitConversationRequest) {
			q.Welcome, q.WelcomeDeviceIds = []byte("w"), []string{"short"}
		}, "welcome_device_ids"},
		{"reset without welcome", func(q *messagingv1.CommitConversationRequest) { q.Reset_ = true }, "welcome_device_ids"},
		{"unknown device (the device check)", func(q *messagingv1.CommitConversationRequest) {
			q.Welcome, q.WelcomeDeviceIds = []byte("w"), []string{devCarol1}
		}, "welcome_device_ids"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// The pair is stale too (the conversation is at (1, 5)): the field answer comes first.
			r, convID := commitRig(t, 1, 5, nil)
			req := commitReq(ckey(1), convID, 1, 1, "c")
			tc.edit(req)
			_, err := r.commit(t, alice, req)
			wantField(t, err, tc.field)
			if r.repo.commitCalls != 1 {
				t.Errorf("the field verdict was answered before the transaction (%d repo calls)", r.repo.commitCalls)
			}
			if len(r.repo.commits) != 0 || len(r.repo.welcomes) != 0 || r.repo.convs[convID].MlsEpoch != 5 {
				t.Error("a refusal wrote")
			}
		})
	}
	t.Run("field errors look up no device", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, nil)
		req := commitReq(ckey(1), convID, 1, 1, "c", devBob1)
		req.Commit = nil
		_, err := r.commit(t, alice, req)
		wantField(t, err, "commit")
		if len(r.devices.calls) != 0 {
			t.Errorf("device lookups %v", r.devices.calls)
		}
	})
	t.Run("stale with good devices", func(t *testing.T) {
		r, convID := commitRig(t, 1, 5, nil)
		_, err := r.commit(t, alice, commitReq(ckey(1), convID, 1, 4, "c", devBob1))
		wantStale(t, err, 1, 5)
	})
	t.Run("a device lookup failure is an internal error, not a verdict", func(t *testing.T) {
		r, convID := commitRig(t, 1, 1, func(r *rig) { r.devices.err = errors.New("directory down") })
		_, err := r.commit(t, alice, commitReq(ckey(1), convID, 1, 1, "c", devBob1))
		if code, _, _ := reasonOf(t, err); code != connect.CodeInternal {
			t.Errorf("code = %v, want internal", code)
		}
	})
}

// Contention is the usual "busy" (safe to retry: the record's pair is the natural key), not an internal error.
func TestCommit_ContentionIsBusy(t *testing.T) {
	r, convID := commitRig(t, 1, 1, func(r *rig) { r.repo.commitErr = fmt.Errorf("messaging: commit: %w", store.ErrContended) })
	_, err := r.commit(t, alice, commitReq(ckey(1), convID, 1, 1, "c"))
	if code, _, _ := reasonOf(t, err); code != connect.CodeUnavailable {
		t.Errorf("code = %v (%v), want unavailable (busy)", code, err)
	}
}

// The request line carries kind, conversation_hash, reset and replay only: no bytes, device ids or uids.
func TestCommit_RequestLineHasNoSecrets(t *testing.T) {
	for name, ids := range map[string][]string{"stored": {devBob1, devAlice2}, "refused": {devCarol1}} {
		t.Run(name, func(t *testing.T) {
			r, convID := commitRig(t, 1, 1, nil)
			ctx, info := logger.WithRequestInfo(verifiedCtx())
			_, _ = r.svc.Commit(ctx, alice, commitReq(ckey(1), convID, 1, 1, "secret", ids...))
			if v, ok := info.Get(fieldKind); !ok || v != kindCommit {
				t.Errorf("kind = %v, %v", v, ok)
			}
			if v, ok := info.Get(fieldReset); !ok || v != false {
				t.Errorf("reset = %v, %v", v, ok)
			}
			for _, a := range info.Fields() {
				for _, sec := range append([]string{"secret", "commit:", "welcome:", alice, bob, convID}, ids...) {
					if strings.Contains(a.Value.String(), sec) || strings.Contains(a.Key, sec) {
						t.Errorf("request field %s=%q contains %q", a.Key, a.Value.String(), sec)
					}
				}
			}
		})
	}
}

// The pure rules on their own.
func TestCommitRules(t *testing.T) {
	conv := ConvDoc{Participants: sortedPair(alice, bob), Encryption: encMLS, MlsGen: 2, MlsEpoch: 3}
	rec := &CommitDoc{Data: []byte("x"), SenderID: alice}
	for _, tc := range []struct {
		name       string
		gen, epoch int64
		rec        *CommitDoc
		uid        string
		data       string
		want       bool
	}{
		{"past pair, same user and bytes", 2, 2, rec, alice, "x", true},
		{"earlier generation", 1, 9, rec, alice, "x", true},
		{"current pair (a leftover)", 2, 3, rec, alice, "x", false},
		{"future pair", 3, 0, rec, alice, "x", false},
		{"other user", 2, 2, rec, bob, "x", false},
		{"other bytes", 2, 2, rec, alice, "y", false},
		{"no record", 2, 2, nil, alice, "x", false},
	} {
		if got := isCommitRetry(conv, tc.rec, tc.uid, []byte(tc.data), tc.gen, tc.epoch); got != tc.want {
			t.Errorf("%s: isCommitRetry = %v", tc.name, got)
		}
	}
	if g, e := commitRecordPair(CommitParams{Gen: 2, Epoch: 3}); g != 2 || e != 3 {
		t.Errorf("record pair = (%d, %d)", g, e)
	}
	if g, e := commitRecordPair(CommitParams{Gen: 2, Epoch: 3, Reset: true}); g != 3 || e != 0 {
		t.Errorf("reset record pair = (%d, %d)", g, e)
	}
	if g, e := commitNextPair(CommitParams{Gen: 2, Epoch: 3}); g != 2 || e != 4 {
		t.Errorf("next pair = (%d, %d)", g, e)
	}
	if g, e := commitNextPair(CommitParams{Gen: 2, Reset: true}); g != 3 || e != 1 {
		t.Errorf("reset next pair = (%d, %d)", g, e)
	}
	if _, err := commitConvRefusal(&ConvDoc{Participants: []string{alice}, Encryption: encMLS}, alice); !errors.Is(err, ErrNotFound) {
		t.Errorf("one-person conversation: %v", err)
	}
	// NONE answers before gone (the proto's listed order).
	if _, err := commitConvRefusal(&ConvDoc{Participants: sortedPair(alice, bob), Gone: []string{bob}}, alice); !errors.Is(err, errNotEncrypted) {
		t.Errorf("NONE and gone: %v", err)
	}
	// assignWelcomeTargets: a commit may address only the caller's devices; a reset may not.
	if _, ok := assignWelcomeTargets([]string{devAlice2}, alice, bob, []string{devAlice2}, []string{devBob1}, false); !ok {
		t.Error("commit with the caller's device refused")
	}
	if _, ok := assignWelcomeTargets([]string{devAlice2}, alice, bob, []string{devAlice2}, []string{devBob1}, true); ok {
		t.Error("reset without a peer device accepted")
	}
}
