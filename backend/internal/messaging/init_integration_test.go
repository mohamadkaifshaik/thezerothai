//go:build integration

package messaging

// Starting encryption (mls_init, Task 4) on the emulator: the exact documents of a creation and of an upgrade, refusals
// that write nothing and answer before the device check, the replay rule, the welcome replacement, and two inits racing
// on one conversation from real goroutines on separate service instances.

import (
	"context"
	"fmt"
	"slices"
	"sort"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
)

// withDevices registers the ACTIVE device ids of both test users with the fake key directory.
func (e *itEnv) withDevices() {
	e.devices.mu.Lock()
	e.devices.active[alice] = []string{devAlice1, devAlice2}
	e.devices.active[bob] = []string{devBob1, devBob2}
	e.devices.mu.Unlock()
}

// initTo is an mls_init from anyone to `to` (by recipient), with distinct bytes per tag.
func initTo(key, to, tag string, ids ...string) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: to},
		Ciphertext: []byte("ct:" + tag), ReportCommitment: itCommitment, MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("commit:" + tag), Welcome: []byte("welcome:" + tag), WelcomeDeviceIds: ids},
	}
}

// docsIn returns every document of a collection path (relative to the root), by path, with its raw data.
func (e *itEnv) docsIn(path string) map[string]map[string]any {
	e.t.Helper()
	docs, err := e.fs.Collection(path).Documents(context.Background()).GetAll()
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, d := range docs {
		out[d.Ref.ID] = d.Data()
	}
	return out
}

// mlsState is every MLS document of the alice-bob conversation: commits, welcomes of both users and messages.
type mlsState struct {
	commits, aliceWelcomes, bobWelcomes map[string]map[string]any
	msgs                                map[string]MsgDoc
}

func (e *itEnv) mlsState(convID string) mlsState {
	e.t.Helper()
	return mlsState{
		commits:       e.docsIn("conversations/" + convID + "/commits"),
		aliceWelcomes: e.docsIn("users/" + alice + "/dmWelcomes"),
		bobWelcomes:   e.docsIn("users/" + bob + "/dmWelcomes"),
		msgs:          e.msgs(convID),
	}
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func asTime(t *testing.T, v any) time.Time {
	t.Helper()
	tm, ok := v.(time.Time)
	if !ok {
		t.Fatalf("%v is not a time", v)
	}
	return tm
}

// checkWelcome asserts one stored welcome's exact fields.
func checkWelcome(t *testing.T, raw map[string]any, convID, device, data string) {
	t.Helper()
	if got := keysOf(raw); !slices.Equal(got, []string{"convId", "createdAt", "data", "deviceId", "epoch", "expireAt", "gen"}) {
		t.Errorf("welcome fields = %v", got)
	}
	if raw["convId"] != convID || raw["deviceId"] != device || raw["gen"] != int64(1) || raw["epoch"] != int64(0) || string(raw["data"].([]byte)) != data {
		t.Errorf("welcome = %v", raw)
	}
	if c, x := asTime(t, raw["createdAt"]), asTime(t, raw["expireAt"]); !x.Equal(c.Add(WelcomeRetention)) {
		t.Errorf("welcome expireAt %v, want createdAt %v + 30 days", x, c)
	}
}

// A first message carrying mls_init creates the conversation as MLS at (1, 1) with the commit record (1, 0), one welcome
// per device under its owner and the message at (1, 1), plus everything a plaintext first message writes (entries, quota,
// push), in one transaction.
func TestInit_CreatesTheConversationExactly(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	resp, err := e.send(alice, initTo(skey(1), bob, "a", devBob1, devAlice2, devBob2))
	if err != nil {
		t.Fatal(err)
	}
	conv := e.docSnap("conversations/" + convID).Data()
	if conv["encryption"] != encMLS || conv["mlsGen"] != int64(1) || conv["mlsEpoch"] != int64(1) || conv["state"] != stateAccepted {
		t.Errorf("conversation = %v", conv)
	}
	st := e.mlsState(convID)
	if len(st.commits) != 1 {
		t.Fatalf("commits = %d, want 1", len(st.commits))
	}
	cm, ok := st.commits[commitDocID(1, 0)]
	if !ok {
		t.Fatalf("commit ids = %v, want %s", st.commits, commitDocID(1, 0))
	}
	if got := keysOf(cm); !slices.Equal(got, []string{"createdAt", "data", "epoch", "expireAt", "gen", "senderId"}) {
		t.Errorf("commit fields = %v", got)
	}
	if string(cm["data"].([]byte)) != "commit:a" || cm["senderId"] != alice || cm["gen"] != int64(1) || cm["epoch"] != int64(0) {
		t.Errorf("commit = %v", cm)
	}
	if c, x := asTime(t, cm["createdAt"]), asTime(t, cm["expireAt"]); !x.Equal(c.Add(CommitRetention)) {
		t.Errorf("commit expireAt %v, want createdAt %v + 30 days", x, c)
	}
	if len(st.bobWelcomes) != 2 || len(st.aliceWelcomes) != 1 {
		t.Fatalf("welcomes bob %d alice %d, want 2 and 1", len(st.bobWelcomes), len(st.aliceWelcomes))
	}
	for owner, set := range map[string]map[string]map[string]any{bob: st.bobWelcomes, alice: st.aliceWelcomes} {
		for id, raw := range set {
			dev, _ := raw["deviceId"].(string)
			if id != welcomeDocID(convID, 1, 0, dev) {
				t.Errorf("%s welcome id %s, want welcomeDocID", owner, id)
			}
			checkWelcome(t, raw, convID, dev, "welcome:a")
		}
	}
	msgID := resp.GetMessage().GetId()
	m := st.msgs[msgID]
	init := &mlsInit{Commit: []byte("commit:a"), Welcome: []byte("welcome:a"), DeviceIDs: []string{devBob1, devAlice2, devBob2}}
	if len(st.msgs) != 1 || m.MlsGen != 1 || m.MlsEpoch != 1 || m.MlsKey != "1:1" || string(m.Ciphertext) != "ct:a" || m.Text != "" ||
		m.RequestHash != encRequestHash(convID, 1, 1, []byte("ct:a"), itCommitment, initDigest(init)) || !m.CtExpireAt.Equal(m.CreatedAt.Add(CiphertextRetention)) {
		t.Errorf("message = %+v", m)
	}
	for _, uid := range []string{alice, bob} {
		if ent, ok := e.entry(uid, dmInboxCollection, convID); !ok || !ent.Last.Encrypted || ent.Last.Snippet != "" || ent.Last.MessageID != msgID {
			t.Errorf("%s entry = %+v, %v", uid, ent, ok)
		}
	}
	if e.dmNew(alice) != 1 || len(e.events.got) != 1 {
		t.Errorf("dmNew %d events %d, want 1 and 1", e.dmNew(alice), len(e.events.got))
	}
	if c := resp.GetConversation(); c.GetEncryption() != messagingv1.ConversationEncryption_CONVERSATION_ENCRYPTION_MLS || c.GetMlsGeneration() != 1 || c.GetMlsEpoch() != 1 {
		t.Errorf("answered conversation = %v", c)
	}
	// The next ordinary send at (1, 1), by conversation id on the same instance (the cache holds the MLS conversation).
	if _, err := e.send(bob, encByConv(skey(2), convID, 1, 1, "reply")); err != nil {
		t.Errorf("ordinary send at (1, 1) after the init: %v", err)
	}
}

// Upgrading a plaintext conversation by conversation id: one update of the conversation (encryption fields and updatedAt;
// state, requestCount and createdAt kept), commit, welcomes and the message; no new-conversation quota, the plaintext
// history untouched.
func TestInit_UpgradesAPlaintextConversation(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.mutual(alice, bob)
	plain := e.must(alice, toUser(skey(1), bob, "plain"))
	convID := plain.GetConversation().GetId()
	before, _ := e.conv(convID)
	plainMsg := e.docSnap("conversations/" + convID + "/messages/" + plain.GetMessage().GetId()).UpdateTime
	e.tick(time.Second)
	if _, err := e.send(bob, &messagingv1.SendMessageRequest{
		IdempotencyKey: skey(2), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID},
		Ciphertext: []byte("ct:b"), ReportCommitment: itCommitment, MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("commit:b"), Welcome: []byte("welcome:b"), WelcomeDeviceIds: []string{devAlice1}},
	}); err != nil {
		t.Fatal(err)
	}
	after, _ := e.conv(convID)
	if !after.encrypted() || after.MlsGen != 1 || after.MlsEpoch != 1 || after.State != before.State || !after.CreatedAt.Equal(before.CreatedAt) ||
		after.RequestCount != before.RequestCount || !after.UpdatedAt.After(before.UpdatedAt) {
		t.Errorf("conversation %+v -> %+v", before, after)
	}
	st := e.mlsState(convID)
	if len(st.commits) != 1 || st.commits[commitDocID(1, 0)]["senderId"] != bob || len(st.aliceWelcomes) != 1 || len(st.bobWelcomes) != 0 || len(st.msgs) != 2 {
		t.Errorf("commits %d welcomes alice %d bob %d msgs %d", len(st.commits), len(st.aliceWelcomes), len(st.bobWelcomes), len(st.msgs))
	}
	if e.dmNew(bob) != 0 {
		t.Errorf("the upgrade charged dm_new_daily")
	}
	if got := e.docSnap("conversations/" + convID + "/messages/" + plain.GetMessage().GetId()).UpdateTime; !got.Equal(plainMsg) {
		t.Error("the plaintext history was rewritten")
	}
	// A plaintext send is now ENCRYPTION_REQUIRED (one-way).
	_, err := e.send(alice, toConv(skey(3), convID, "plain again"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_ENCRYPTION_REQUIRED, nil)
}

// initByConv is an mls_init by conversation id (the upgrade of an existing NONE conversation), welcoming ids.
func initByConv(key, convID, tag string, ids ...string) *messagingv1.SendMessageRequest {
	return &messagingv1.SendMessageRequest{
		IdempotencyKey: key, Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: convID},
		Ciphertext: []byte("ct:" + tag), ReportCommitment: itCommitment, MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("commit:" + tag), Welcome: []byte("welcome:" + tag), WelcomeDeviceIds: ids},
	}
}

// The upgrade stamps updatedAt strictly after the one its transaction read (commitStamp), whichever arm of the existing
// conversation's update it takes: a plain upgrade, the requester's next message in a REQUEST (requestCount + 1) and the
// recipient's accepting reply. The clock does not move between the plaintext send and the init: the tie. A stamp equal to
// the old one would let the 60 s instance cache keep the NONE copy (putConv keeps a copy unless the newcomer is newer).
func TestInit_UpgradeStampsStrictlyLater(t *testing.T) {
	for _, tc := range []struct {
		name       string
		mutual     bool
		from       string
		ids        []string
		wantState  string
		wantReqCnt int64
	}{
		{"plain upgrade", true, bob, []string{devAlice1}, stateAccepted, 0},
		{"requester's next message", false, alice, []string{devBob1}, stateRequest, 2},
		{"recipient's accepting reply", false, bob, []string{devAlice1}, stateAccepted, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.withDevices()
			if tc.mutual {
				e.mutual(alice, bob)
			} else {
				e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
			}
			convID := e.must(alice, toUser(skey(1), bob, "plain")).GetConversation().GetId()
			before, _ := e.conv(convID)
			if _, err := e.send(tc.from, initByConv(skey(2), convID, "u", tc.ids...)); err != nil {
				t.Fatal(err)
			}
			after, _ := e.conv(convID)
			if !after.encrypted() || after.State != tc.wantState || after.RequestCount != tc.wantReqCnt {
				t.Errorf("conversation = %+v", after)
			}
			if !after.UpdatedAt.After(before.UpdatedAt) {
				t.Errorf("updatedAt %v -> %v, want strictly later", before.UpdatedAt, after.UpdatedAt)
			}
		})
	}
}

// Two upgrades of one existing NONE conversation at once, both by conversation id (alice welcoming bob's device, bob
// welcoming alice's), each on its own instance, 6 rounds of three kinds with per-round expectations:
//   - "together": both released at once; either may win;
//   - "second inside first": the second released from inside the first's transaction, after its conversation read; either
//     may win (it depends on which transaction commits first);
//   - "second after first committed": the second released the moment the first's transaction committed: the first wins.
//
// Every round: exactly one winner; the loser is STALE_EPOCH (1, 1) with NO conversation_id metadata (it addressed the
// conversation by id) and wrote nothing (no message, no welcome, the one commit record and the conversation's pair are the
// winner's); the plaintext history stays. A busy answer is retried with the same request (then STALE_EPOCH).
func TestInit_ConcurrentUpgradesOneWins(t *testing.T) {
	kinds := []string{"together", "second inside first", "second after first committed"}
	tally := map[string]int{}
	for round := range 6 {
		kind := kinds[round%3]
		e := newIT(t, nil)
		e.withDevices()
		e.mutual(alice, bob)
		plain := e.must(alice, toUser(skey(1), bob, "plain"))
		convID := plain.GetConversation().GetId()
		e.tick(time.Second)
		froms := [2]string{alice, bob}
		reqs := [2]*messagingv1.SendMessageRequest{initByConv(skey(10), convID, "a", devBob1), initByConv(skey(11), convID, "b", devAlice1)}
		start, second := make(chan struct{}), make(chan struct{})
		var once sync.Once
		release := func() { once.Do(func() { close(second) }) }
		var first *service
		switch round % 3 {
		case 0:
			first = e.newService()
			release()
		case 1:
			first = e.signalledService(release)
		case 2:
			first = e.afterCommitService(release)
		}
		svcs := [2]*service{first, e.newService()}
		var errs [2]error
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			_, errs[0] = e.sendOn(svcs[0], froms[0], reqs[0])
			release() // ended without reaching its seam: let the second run anyway
		}()
		go func() {
			defer wg.Done()
			<-start
			<-second
			_, errs[1] = e.sendOn(svcs[1], froms[1], reqs[1])
		}()
		close(start)
		wg.Wait()
		for i := range errs {
			if outcome(errs[i]) == "busy" {
				tally["busy"]++
				_, errs[i] = e.sendOn(svcs[i], froms[i], reqs[i])
			}
		}
		winner := -1
		for i, err := range errs {
			if err == nil {
				if winner >= 0 {
					t.Fatalf("round %d (%s): both upgrades succeeded", round, kind)
				}
				winner = i
				continue
			}
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "1", "epoch": "1"})
			if _, _, meta := reasonOf(t, err); len(meta) != 2 {
				t.Errorf("round %d (%s): STALE_EPOCH metadata = %v, want only the pair (addressed by conversation id)", round, kind, meta)
			}
		}
		if winner < 0 {
			t.Fatalf("round %d (%s): no upgrade won: %v", round, kind, errs)
		}
		if kind == "second after first committed" && winner != 0 {
			t.Errorf("round %d: the upgrade released after the first committed won", round)
		}
		tally[fmt.Sprintf("%s: winner %d", kind, winner)]++
		w, l := winner, 1-winner
		st := e.mlsState(convID)
		rec := st.commits[commitDocID(1, 0)]
		if len(st.commits) != 1 || rec["senderId"] != froms[w] || string(rec["data"].([]byte)) != string(reqs[w].GetMlsInit().GetCommit()) {
			t.Errorf("round %d: commits = %v, want only the winner's (1, 0)", round, st.commits)
		}
		loserWelcomes := st.aliceWelcomes
		if l == 0 {
			loserWelcomes = st.bobWelcomes
		}
		if len(loserWelcomes) != 0 || len(st.aliceWelcomes)+len(st.bobWelcomes) != 1 {
			t.Errorf("round %d: welcomes alice %d bob %d, want only the winner's one", round, len(st.aliceWelcomes), len(st.bobWelcomes))
		}
		if _, ok := st.msgs[MessageID(froms[l], reqs[l].GetIdempotencyKey())]; ok {
			t.Errorf("round %d: the loser's message was stored", round)
		}
		if _, ok := st.msgs[MessageID(froms[w], reqs[w].GetIdempotencyKey())]; !ok || len(st.msgs) != 2 {
			t.Errorf("round %d: messages = %d, want the plaintext one and the winner's", round, len(st.msgs))
		}
		if c, _ := e.conv(convID); !c.encrypted() || c.MlsGen != 1 || c.MlsEpoch != 1 {
			t.Errorf("round %d: conversation = %+v", round, c)
		}
	}
	t.Logf("tally %v", tally)
}

// An init to someone who does not follow back opens a request exactly like a plaintext first message: the recipient's entry
// in dmRequests, no push, requestCount 1; the requester's next encrypted messages count, and the fourth is
// request_unanswered.
func TestInit_RequestConversationAndTheCap(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
	convID := ConversationID(alice, bob)
	resp, err := e.send(alice, initTo(skey(1), bob, "r", devBob1))
	if err != nil {
		t.Fatal(err)
	}
	c, _ := e.conv(convID)
	if c.State != stateRequest || c.RequestCount != 1 || !c.encrypted() || resp.GetConversation().GetState() != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST {
		t.Errorf("conversation = %+v", c)
	}
	if _, ok := e.entry(bob, dmRequestsCollection, convID); !ok {
		t.Error("the recipient's entry is not in dmRequests")
	}
	if own, _ := e.entry(alice, dmInboxCollection, convID); !own.RequestPending {
		t.Error("the requester's entry is not requestPending")
	}
	if len(e.events.got) != 0 {
		t.Error("a request pushed")
	}
	for i := 2; i <= 3; i++ {
		e.tick(time.Second)
		if _, err := e.send(alice, encByConv(skey(i), convID, 1, 1, fmt.Sprint(i))); err != nil {
			t.Fatalf("message %d: %v", i, err)
		}
	}
	_, err = e.send(alice, encByConv(skey(4), convID, 1, 1, "4"))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, map[string]string{"limit": "request_unanswered"})
	if c, _ := e.conv(convID); c.RequestCount != 3 {
		t.Errorf("requestCount = %d, want 3", c.RequestCount)
	}
}

// Refusals write nothing, and every existing one answers before the device check with the same bytes whatever the
// devices: a recipient's block (in the transaction), the request cap, dm_new_daily. Bad devices alone are VALIDATION
// welcome_device_ids, writing nothing (not even the quota).
func TestInit_RefusalsWriteNothingAndComeFirst(t *testing.T) {
	convID := ConversationID(alice, bob)
	nothing := func(t *testing.T, e *itEnv) {
		t.Helper()
		st := e.mlsState(convID)
		if len(st.commits)+len(st.aliceWelcomes)+len(st.bobWelcomes) != 0 {
			t.Errorf("stored commits %d welcomes %d/%d", len(st.commits), len(st.aliceWelcomes), len(st.bobWelcomes))
		}
		if c, ok := e.conv(convID); ok && c.encrypted() {
			t.Error("the conversation became MLS")
		}
	}
	t.Run("bad devices alone", func(t *testing.T) {
		e := newIT(t, nil)
		e.withDevices()
		e.mutual(alice, bob)
		_, err := e.send(alice, initTo(skey(1), bob, "x", devAlice1))
		wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "welcome_device_ids"})
		nothing(t, e)
		if docs := e.treeDocs(convID); len(docs) != 0 || e.dmNew(alice) != 0 {
			t.Errorf("written: %v, dmNew %d", docs, e.dmNew(alice))
		}
		if _, ok := e.entry(alice, dmInboxCollection, convID); ok {
			t.Error("an entry was written")
		}
	})
	cases := map[string]struct {
		setup  func(e *itEnv)
		reason commonv1.ErrorReason
	}{
		"recipient blocks (in the transaction)": {func(e *itEnv) {
			e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
			e.writeGraphDoc(bob, graph.Snapshot{Blocked: map[string]bool{alice: true}})
		}, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE},
		"request cap": {func(e *itEnv) {
			e.seedConversation(alice, bob, stateRequest, e.now().Add(-time.Hour), [2]string{alice, "1"}, [2]string{alice, "2"}, [2]string{alice, "3"})
		}, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED},
		"dm_new_daily": {func(e *itEnv) { e.mutual(alice, bob) }, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			var answers [][]byte
			for _, ids := range [][]string{{devBob1}, {devAlice1}} {
				e := newIT(t, func(e *itEnv) {
					if name == "dm_new_daily" {
						e.limits.DMNewPerDay = 0
					}
				})
				e.withDevices()
				tc.setup(e)
				_, err := e.send(alice, initTo(skey(1), bob, "x", ids...))
				if _, reason, _ := reasonOf(t, err); reason != tc.reason {
					t.Fatalf("devices %v: %v, want %v", ids, err, tc.reason)
				}
				answers = append(answers, wireBytes(t, err))
				nothing(t, e)
			}
			if string(answers[0]) != string(answers[1]) {
				t.Errorf("the refusal depends on the devices: %q vs %q", answers[0], answers[1])
			}
		})
	}
}

// An init into a conversation that is already MLS is STALE_EPOCH with its pair (even (1, 1)) and writes nothing; with bad
// devices the device check answers first.
func TestInit_IntoMLSIsStaleEpoch(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	convID, _ := e.startMLSConversation(1, 1)
	before := e.snapshotState(convID)
	_, err := e.send(alice, initTo(skey(1), bob, "late", devBob1))
	wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH, map[string]string{"generation": "1", "epoch": "1", "conversation_id": convID})
	_, err = e.send(alice, initTo(skey(2), bob, "late", devAlice1))
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "welcome_device_ids"})
	before.check(t)
	if st := e.mlsState(convID); len(st.commits)+len(st.aliceWelcomes)+len(st.bobWelcomes) != 0 {
		t.Error("a refused init stored a commit or a welcome")
	}
}

// A retried init is a replay that writes nothing: immediately, after a device went inactive (the device check would
// refuse) and after the epoch moved (STALE_EPOCH would refuse). The same key with another welcome is VALIDATION
// idempotency_key.
func TestInit_ReplayWinsAndWritesNothing(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	req := initTo(skey(1), bob, "a", devBob1, devAlice2)
	first := e.must(alice, req)
	commitAt := e.docSnap("conversations/" + convID + "/commits/" + commitDocID(1, 0)).UpdateTime
	retry := func(name string) {
		t.Helper()
		before := e.snapshotState(convID)
		again, err := e.send(alice, initTo(skey(1), bob, "a", devAlice2, devBob1))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if again.GetMessage().GetId() != first.GetMessage().GetId() {
			t.Errorf("%s: answered another message", name)
		}
		before.check(t)
		st := e.mlsState(convID)
		if len(st.commits) != 1 || len(st.bobWelcomes) != 1 || len(st.aliceWelcomes) != 1 {
			t.Errorf("%s: commits %d welcomes %d/%d", name, len(st.commits), len(st.bobWelcomes), len(st.aliceWelcomes))
		}
		if got := e.docSnap("conversations/" + convID + "/commits/" + commitDocID(1, 0)).UpdateTime; !got.Equal(commitAt) {
			t.Errorf("%s: the commit was rewritten", name)
		}
	}
	retry("immediate")
	e.devices.mu.Lock()
	e.devices.active[bob] = nil
	e.devices.mu.Unlock()
	retry("device went inactive")
	e.devices.mu.Lock()
	e.devices.active[bob] = []string{devBob1}
	e.devices.mu.Unlock()
	e.makeConvMLSForTest(convID, 1, 3)
	retry("epoch moved")
	other := initTo(skey(1), bob, "a", devBob1, devAlice2)
	other.MlsInit.Welcome = []byte("another welcome")
	_, err := e.send(alice, other)
	wantAPI(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_VALIDATION, map[string]string{"field": "idempotency_key"})
}

// One stored welcome per (conversation, device): an earlier welcome of an addressed device for this conversation is
// replaced (deleted, or overwritten when it has the very id the new one gets), while a welcome of the same device for
// another conversation and of a device not addressed stay. (For mls_init an earlier welcome exists only when a
// conversation was deleted and recreated; the helper is shared with commits and resets.)
func TestInit_ReplacesEarlierWelcomes(t *testing.T) {
	e := newIT(t, nil)
	e.withDevices()
	e.mutual(alice, bob)
	ctx := context.Background()
	convID, otherConv := ConversationID(alice, bob), ConversationID(bob, "uid-dave")
	seed := func(id, conv, dev string) {
		if _, err := e.fs.Collection("users").Doc(bob).Collection(dmWelcomesCollection).Doc(id).Set(ctx, WelcomeDoc{
			DeviceID: dev, ConvID: conv, Gen: 1, Epoch: 7, Data: []byte("old"), CreatedAt: e.now(), ExpireAt: e.now().Add(WelcomeRetention),
		}); err != nil {
			t.Fatal(err)
		}
	}
	olderID, sameID := welcomeDocID(convID, 1, 7, devBob1), welcomeDocID(convID, 1, 0, devBob2)
	seed(olderID, convID, devBob1)
	seed(sameID, convID, devBob2)
	seed(welcomeDocID(otherConv, 1, 7, devBob1), otherConv, devBob1)
	seed("unaddressed000000000000000000000", convID, "bob-device-retired")
	if _, err := e.send(alice, initTo(skey(1), bob, "n", devBob1, devBob2)); err != nil {
		t.Fatal(err)
	}
	got := e.docsIn("users/" + bob + "/dmWelcomes")
	if _, ok := got[olderID]; ok {
		t.Error("the earlier welcome of an addressed device was kept")
	}
	checkWelcome(t, got[welcomeDocID(convID, 1, 0, devBob1)], convID, devBob1, "welcome:n")
	checkWelcome(t, got[sameID], convID, devBob2, "welcome:n")
	if _, ok := got[welcomeDocID(otherConv, 1, 7, devBob1)]; !ok {
		t.Error("the device's welcome for another conversation was deleted")
	}
	if _, ok := got["unaddressed000000000000000000000"]; !ok {
		t.Error("a welcome of a device not addressed was deleted")
	}
	if len(got) != 4 {
		t.Errorf("bob's welcomes = %d, want 4", len(got))
	}
}

// raceInit is one racer: who sends what, on its own service instance.
type raceInit struct {
	from string
	req  *messagingv1.SendMessageRequest
}

// Two inits on one pair of users at once (from each side, or from two devices of one side with different keys), each on
// its own instance, several rounds on fresh data (even rounds released together; odd rounds release the second from
// inside the first one's transaction, after its conversation read, so they certainly overlap): exactly one wins; the loser is STALE_EPOCH (1, 1)
// with metadata conversation_id (it addressed the recipient), or busy and then, retried with its key, STALE_EPOCH; one
// commit record (the winner's), welcomes only from the winner, one message (the winner's), the loser charged no
// dm_new_daily.
func TestInit_ConcurrentInitsOneWins(t *testing.T) {
	patterns := map[string]func() [2]raceInit{
		"A to B and B to A": func() [2]raceInit {
			return [2]raceInit{{alice, initTo(skey(1), bob, "alice", devBob1, devAlice2)}, {bob, initTo(skey(2), alice, "bob", devAlice1)}}
		},
		"A to B twice": func() [2]raceInit {
			return [2]raceInit{{alice, initTo(skey(1), bob, "dev1", devBob1)}, {alice, initTo(skey(2), bob, "dev2", devBob1, devBob2, devAlice1)}}
		},
	}
	const rounds = 6
	for name, mk := range patterns {
		t.Run(name, func(t *testing.T) {
			wins, firsts := map[int]int{}, map[string]int{}
			for round := 0; round < rounds; round++ {
				e := newIT(t, nil)
				e.withDevices()
				e.mutual(alice, bob)
				convID := ConversationID(alice, bob)
				racers := mk()
				// Even rounds release both together. Odd rounds release the second init from INSIDE the first one's
				// transaction (right after its conversation read, through the in-transaction graph reader), so the two
				// transactions certainly overlap: the window the conversation read must protect.
				start, second := make(chan struct{}), make(chan struct{})
				var once sync.Once
				release := func() { once.Do(func() { close(second) }) }
				var first *service
				if round%2 == 1 {
					base := e.txSocial
					e.txSocial = signalTxSocial{TxReader: base, fire: release}
					first = e.newService()
					e.txSocial = base
				} else {
					first = e.newService()
					release()
				}
				svcs := [2]*service{first, e.newService()}
				var errs [2]error
				var wg sync.WaitGroup
				wg.Add(2)
				go func() {
					defer wg.Done()
					<-start
					_, errs[0] = e.sendOn(svcs[0], racers[0].from, racers[0].req)
					release() // ended without reaching its transaction body: let the second run anyway
				}()
				go func() {
					defer wg.Done()
					<-start
					<-second
					_, errs[1] = e.sendOn(svcs[1], racers[1].from, racers[1].req)
				}()
				close(start)
				wg.Wait()
				for i := range errs {
					first := outcome(errs[i])
					if errs[i] != nil {
						if _, reason, _ := reasonOf(t, errs[i]); reason == commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH {
							first = "stale"
						}
					}
					firsts[first]++
					if outcome(errs[i]) == "busy" { // outcome unknown: the client retries with the same key
						_, errs[i] = e.sendOn(svcs[i], racers[i].from, racers[i].req)
					}
				}
				winner := -1
				for i, err := range errs {
					if err == nil {
						if winner >= 0 {
							t.Fatalf("round %d: both inits succeeded", round)
						}
						winner = i
						continue
					}
					wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_STALE_EPOCH,
						map[string]string{"generation": "1", "epoch": "1", "conversation_id": convID})
				}
				if winner < 0 {
					t.Fatalf("round %d: no init won: %v", round, errs)
				}
				wins[winner]++
				w, l := racers[winner], racers[1-winner]
				tag := string(w.req.GetCiphertext())[len("ct:"):]
				st := e.mlsState(convID)
				if len(st.commits) != 1 || st.commits[commitDocID(1, 0)]["senderId"] != w.from || string(st.commits[commitDocID(1, 0)]["data"].([]byte)) != "commit:"+tag {
					t.Errorf("round %d: commits = %v", round, st.commits)
				}
				all := map[string]map[string]any{}
				for id, raw := range st.aliceWelcomes {
					all["alice/"+id] = raw
				}
				for id, raw := range st.bobWelcomes {
					all["bob/"+id] = raw
				}
				if len(all) != len(w.req.GetMlsInit().GetWelcomeDeviceIds()) {
					t.Errorf("round %d: welcomes = %d, want the winner's %d", round, len(all), len(w.req.GetMlsInit().GetWelcomeDeviceIds()))
				}
				for id, raw := range all {
					if string(raw["data"].([]byte)) != "welcome:"+tag {
						t.Errorf("round %d: welcome %s is not the winner's", round, id)
					}
				}
				if _, ok := st.msgs[MessageID(w.from, w.req.GetIdempotencyKey())]; !ok || len(st.msgs) != 1 {
					t.Errorf("round %d: messages = %d, want only the winner's", round, len(st.msgs))
				}
				if _, ok := st.msgs[MessageID(l.from, l.req.GetIdempotencyKey())]; ok {
					t.Errorf("round %d: the loser's message was stored", round)
				}
				if l.from != w.from && e.dmNew(l.from) != 0 {
					t.Errorf("round %d: the loser was charged dm_new_daily", round)
				}
				if e.dmNew(w.from) != 1 {
					t.Errorf("round %d: the winner's dmNew = %d, want 1", round, e.dmNew(w.from))
				}
				if c, _ := e.conv(convID); !c.encrypted() || c.MlsGen != 1 || c.MlsEpoch != 1 {
					t.Errorf("round %d: conversation = %+v", round, c)
				}
			}
			t.Logf("%s: winner index tally %v; first answers %v", name, wins, firsts)
		})
	}
}
