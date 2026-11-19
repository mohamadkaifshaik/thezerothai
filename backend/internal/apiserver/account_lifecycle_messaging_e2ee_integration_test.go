//go:build integration

package apiserver

// The `messaging` deletion step on an end-to-end encrypted conversation (E2EE plan 3 Task 8), the seeded residue sweep
// that proves the guard rows for `commits` and `dmWelcomes` true:
//
//   - one side erased (TestAccountLifecycle_MessagingE2EEOneSideErased): an MLS conversation started over the real Build
//     chain by A's mls_init (commit record (1, 0) and a welcome in B's inbox), a commit by B, a commit by A, a reset by B
//     welcoming A's device (a welcome in A's own inbox), encrypted messages from both sides. After A's deletion the sweep
//     finds nothing of A anywhere, A's dmWelcomes are gone, A's messages are tombstones without ciphertext or commitment
//     but with their pair, A's commit records name DeletedUID, and B still catches up (ListConversationCommits,
//     ListEpochMessages);
//   - both erased (TestAccountLifecycle_MessagingE2EEBothErased): the conversation, its messages and its commits are gone;
//   - a crash after every side effect (TestAccountLifecycle_MessagingE2EECrashAtEverySideEffect), on documents seeded in
//     their stored shapes (the crash chain registers no keys step, so no key device is registered there), ends in the
//     clean run's state.

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1/messagingv1connect"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// e2eeLifeWorld is an encrypted A-B conversation built over the real chain of a lifecycleEnv.
type e2eeLifeWorld struct {
	a, b       testUser
	aDev, bDev string
	conv       string
	msg        messagingv1connect.MessagingServiceClient
}

// newE2EELifecycle builds a lifecycle chain with messaging on and e2ee_dm allowed for two fresh users, and the encrypted
// conversation between them:
//
//	A: mls_init at (1, 1), welcoming B's device       -> record (1, 0) by A, users/B/dmWelcomes, conversation (1, 1)
//	B: an encrypted message at (1, 1)
//	B: commit on (1, 1)                               -> record (1, 1) by B, conversation (1, 2)
//	A: commit on (1, 2)                               -> record (1, 2) by A, conversation (1, 3)
//	B: reset of generation 1, welcoming A's device    -> record (2, 0) by B, users/A/dmWelcomes, conversation (2, 1)
//	A, then B: an encrypted message each at (2, 1)
func newE2EELifecycle(t *testing.T) (*lifecycleEnv, e2eeLifeWorld) {
	t.Helper()
	skipIfNoLifecycleEmulators(t)
	ta, ua := mintToken(t, "")
	tb, ub := mintToken(t, "")
	allow := map[string]struct{}{ua: {}, ub: {}}
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		messagingOn(c)
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.Allowlist, Allowlist: allow}
	})
	e.createProfile(t, ta)
	e.createProfile(t, tb)
	w := e2eeLifeWorld{
		a: testUser{ta, ua}, b: testUser{tb, ub}, aDev: "lifeA-" + ua[:12], bDev: "lifeB-" + ub[:12],
		msg: messagingv1connect.NewMessagingServiceClient(http.DefaultClient, e.url),
	}
	e.follow(t, w.a, w.b)
	e.follow(t, w.b, w.a)
	ctx := context.Background()
	kc := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)
	for _, d := range []struct {
		u   testUser
		dev string
	}{{w.a, w.aDev}, {w.b, w.bDev}} {
		_, err := kc.RegisterKeyDevice(ctx, authed(d.u.token, &keysv1.RegisterKeyDeviceRequest{
			IdempotencyKey: contractKey("life-reg"), DeviceId: d.dev, SignaturePublicKey: bytes.Repeat([]byte{7}, 32),
		}))
		e.call(t, "RegisterKeyDevice", err)
	}
	res, err := w.msg.SendMessage(ctx, authed(w.a.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("life-init"), Target: &messagingv1.SendMessageRequest_RecipientUserId{RecipientUserId: w.b.uid},
		Ciphertext: []byte("ct a 1:1"), ReportCommitment: bytes.Repeat([]byte{1}, 32), MlsGeneration: 1, MlsEpoch: 1,
		MlsInit: &messagingv1.MlsInit{Commit: []byte("init commit"), Welcome: []byte("welcome for b"), WelcomeDeviceIds: []string{w.bDev}},
	}))
	e.call(t, "mls_init", err)
	w.conv = res.Msg.GetConversation().GetId()
	w.sendEnc(t, e, w.b, 1, 1, "ct b 1:1")
	w.commit(t, e, w.b, 1, 1, false, "")
	w.commit(t, e, w.a, 1, 2, false, "")
	w.commit(t, e, w.b, 1, 0, true, w.aDev)
	w.sendEnc(t, e, w.a, 2, 1, "ct a 2:1")
	w.sendEnc(t, e, w.b, 2, 1, "ct b 2:1")
	return e, w
}

func (w e2eeLifeWorld) sendEnc(t *testing.T, e *lifecycleEnv, from testUser, gen, epoch uint64, ct string) {
	t.Helper()
	_, err := w.msg.SendMessage(context.Background(), authed(from.token, &messagingv1.SendMessageRequest{
		IdempotencyKey: contractKey("life-send"), Target: &messagingv1.SendMessageRequest_ConversationId{ConversationId: w.conv},
		Ciphertext: []byte(ct), ReportCommitment: bytes.Repeat([]byte{2}, 32), MlsGeneration: gen, MlsEpoch: epoch,
	}))
	e.call(t, "encrypted send", err)
}

// commit is CommitConversation by who on (gen, epoch); a reset welcomes welcomeDev.
func (w e2eeLifeWorld) commit(t *testing.T, e *lifecycleEnv, who testUser, gen, epoch uint64, reset bool, welcomeDev string) {
	t.Helper()
	req := &messagingv1.CommitConversationRequest{
		IdempotencyKey: contractKey("life-commit"), ConversationId: w.conv, MlsGeneration: gen, MlsEpoch: epoch,
		Commit: []byte(fmt.Sprintf("commit %d:%d", gen, epoch)), Reset_: reset,
	}
	if welcomeDev != "" {
		req.Welcome, req.WelcomeDeviceIds = []byte("welcome "+welcomeDev[:5]), []string{welcomeDev}
	}
	_, err := w.msg.CommitConversation(context.Background(), authed(who.token, req))
	e.call(t, "CommitConversation", err)
}

// eraseAccount runs u's deletion to completion through the production chain (the job handler, continuations drained).
func (e *lifecycleEnv) eraseAccount(t *testing.T, u testUser, key string) {
	t.Helper()
	msg := e.beginDeletion(t, richAccount{a: u}, key)
	e.pastGate(t, u.uid)
	for code := 0; code != http.StatusNoContent; {
		code = e.deliverJSON(t, msg)
	}
	for _, m := range e.pull(t) {
		if m["kind"] == identity.JobKindAccountDelete {
			for code := 0; code != http.StatusNoContent; {
				code = e.deliver(t, m)
			}
		}
	}
	if fsDocExists(t, e.fs, "users/"+u.uid) {
		t.Fatalf("users/%s survived its own erasure", u.uid[:6])
	}
}

// docsUnder lists the documents of one collection (at most 100: the seeded worlds hold a handful).
func (e *lifecycleEnv) docsUnder(t *testing.T, col *firestore.CollectionRef) []*firestore.DocumentSnapshot {
	t.Helper()
	docs, err := col.Limit(100).Documents(context.Background()).GetAll()
	e.call(t, "list "+col.Path, err)
	return docs
}

func TestAccountLifecycle_MessagingE2EEOneSideErased(t *testing.T) {
	e, w := newE2EELifecycle(t)
	ctx := context.Background()
	// The seed has what the sweep must not find afterwards: A's commit records, A's welcome, B's welcome sent by A.
	commitsCol := e.fs.Collection("conversations").Doc(w.conv).Collection("commits")
	if n := len(e.docsUnder(t, commitsCol)); n != 4 {
		t.Fatalf("seeded %d commit records, want 4", n)
	}
	for _, u := range []testUser{w.a, w.b} {
		if n := len(e.docsUnder(t, e.fs.Collection("users").Doc(u.uid).Collection("dmWelcomes"))); n != 1 {
			t.Fatalf("seeded %d welcomes for %s, want 1", n, u.uid[:6])
		}
	}

	e.eraseAccount(t, w.a, "e2ee-one-side-delete")
	e.requireNoResidue(t, w.a.uid)

	if left := e.docsUnder(t, e.fs.Collection("users").Doc(w.a.uid).Collection("dmWelcomes")); len(left) != 0 {
		t.Errorf("users/{A}/dmWelcomes kept %d documents", len(left))
	}
	// B's welcome from A's init holds no uid of A (deviceId is B's, convId a hash): it stays until its 30-day expiry.
	if left := e.docsUnder(t, e.fs.Collection("users").Doc(w.b.uid).Collection("dmWelcomes")); len(left) != 1 {
		t.Errorf("users/{B}/dmWelcomes has %d documents, want B's welcome kept", len(left))
	}
	// A's messages: tombstones with no ciphertext, commitment or ctExpireAt, ctRemoved, the pair and mlsKey kept. B's intact.
	var tombs, intact int
	for _, m := range e.docsUnder(t, e.fs.Collection("conversations").Doc(w.conv).Collection("messages")) {
		d := m.Data()
		switch d["senderId"] {
		case messaging.DeletedUID:
			tombs++
			for _, gone := range []string{"ciphertext", "commitment", "ctExpireAt"} {
				if _, has := d[gone]; has {
					t.Errorf("A's tombstone %s kept %s", m.Ref.ID[:8], gone)
				}
			}
			if d["state"] != "DELETED_ACCOUNT" || d["ctRemoved"] != true || d["mlsKey"] == nil || d["mlsGen"] == nil || d["mlsEpoch"] == nil {
				t.Errorf("A's tombstone %s = state %v ctRemoved %v mlsKey %v mlsGen %v mlsEpoch %v", m.Ref.ID[:8], d["state"], d["ctRemoved"], d["mlsKey"], d["mlsGen"], d["mlsEpoch"])
			}
		case w.b.uid:
			intact++
			if ct, ok := d["ciphertext"].([]byte); d["state"] != "VISIBLE" || !ok || len(ct) == 0 || d["ctRemoved"] != nil {
				t.Errorf("B's message %s was touched: %v", m.Ref.ID[:8], d)
			}
		}
	}
	if tombs != 2 || intact != 2 {
		t.Errorf("messages: %d tombstones of A and %d intact of B, want 2 and 2", tombs, intact)
	}
	senders := map[string]string{}
	for _, c := range e.docsUnder(t, commitsCol) {
		s, _ := c.DataAt("senderId")
		senders[c.Ref.ID] = fmt.Sprint(s)
	}
	wantSenders := map[string]string{
		"0000000001_0000000000": messaging.DeletedUID, "0000000001_0000000001": w.b.uid,
		"0000000001_0000000002": messaging.DeletedUID, "0000000002_0000000000": w.b.uid,
	}
	for id, want := range wantSenders {
		if senders[id] != want {
			t.Errorf("commit %s senderId is not the expected one (deleted placeholder %v)", id, want == messaging.DeletedUID)
		}
	}

	// The survivor still catches up: every commit, from_self only on B's own, and the tombstones in their epoch's set.
	cs, err := w.msg.ListConversationCommits(ctx, authed(w.b.token, &messagingv1.ListConversationCommitsRequest{ConversationId: w.conv}))
	if err != nil {
		t.Fatalf("B's ListConversationCommits after A's deletion: %v", err)
	}
	var got []string
	for _, c := range cs.Msg.GetCommits() {
		got = append(got, fmt.Sprintf("%d:%d self=%v", c.GetMlsGeneration(), c.GetMlsEpoch(), c.GetFromSelf()))
	}
	if want := []string{"1:0 self=false", "1:1 self=true", "1:2 self=false", "2:0 self=true"}; !slices.Equal(got, want) || cs.Msg.GetMlsGeneration() != 2 || cs.Msg.GetMlsEpoch() != 1 {
		t.Errorf("B's commits = %v at (%d, %d), want %v at (2, 1)", got, cs.Msg.GetMlsGeneration(), cs.Msg.GetMlsEpoch(), want)
	}
	for _, p := range [][2]uint64{{1, 1}, {2, 1}} {
		em, err := w.msg.ListEpochMessages(ctx, authed(w.b.token, &messagingv1.ListEpochMessagesRequest{ConversationId: w.conv, MlsGeneration: p[0], MlsEpoch: p[1]}))
		if err != nil {
			t.Fatalf("B's ListEpochMessages (%d, %d) after A's deletion: %v", p[0], p[1], err)
		}
		var rows []string
		for _, m := range em.Msg.GetMessages() {
			rows = append(rows, fmt.Sprintf("self=%v %v removed=%v ct=%d", m.GetFromSelf(), m.GetState(), m.GetCiphertextRemoved(), len(m.GetCiphertext())))
		}
		slices.Sort(rows)
		want := []string{
			"self=false MESSAGE_STATE_DELETED_ACCOUNT removed=true ct=0",
			fmt.Sprintf("self=true MESSAGE_STATE_VISIBLE removed=false ct=%d", len("ct b 1:1")),
		}
		if !slices.Equal(rows, want) {
			t.Errorf("epoch (%d, %d) = %v, want %v", p[0], p[1], rows, want)
		}
	}
}

func TestAccountLifecycle_MessagingE2EEBothErased(t *testing.T) {
	e, w := newE2EELifecycle(t)
	e.eraseAccount(t, w.a, "e2ee-both-delete-a")
	e.eraseAccount(t, w.b, "e2ee-both-delete-b")
	if fsDocExists(t, e.fs, "conversations/"+w.conv) {
		t.Error("the conversation document survived both erasures")
	}
	for _, sub := range []string{"messages", "commits"} {
		if left := e.docsUnder(t, e.fs.Collection("conversations").Doc(w.conv).Collection(sub)); len(left) != 0 {
			t.Errorf("conversations/{id}/%s kept %d documents", sub, len(left))
		}
	}
	for _, u := range []testUser{w.a, w.b} {
		if left := e.docsUnder(t, e.fs.Collection("users").Doc(u.uid).Collection("dmWelcomes")); len(left) != 0 {
			t.Errorf("users/%s/dmWelcomes kept %d documents", u.uid[:6], len(left))
		}
		e.requireNoResidue(t, u.uid)
	}
}

// e2eeSeedWorld is the crash matrix's account A: an MLS conversation with the live B and an MLS tree whose peer is gone,
// in their stored shapes.
type e2eeSeedWorld struct {
	a, b      testUser
	acc, gone string
	roles     map[string]string
}

// e2eeSeed writes the encrypted fields onto conversation id: MLS at (gen, epoch), the commit records (pair -> sender),
// and one encrypted message per sender given, at mlsKey "gen:epoch".
func (e *lifecycleEnv) e2eeSeed(t *testing.T, id string, gen, epoch int64, commits map[[2]int64]string, encFrom ...string) {
	t.Helper()
	ctx := context.Background()
	_, err := e.fs.Doc("conversations/"+id).Update(ctx, []firestore.Update{{Path: "encryption", Value: "MLS"}, {Path: "mlsGen", Value: gen}, {Path: "mlsEpoch", Value: epoch}})
	e.call(t, "seed encryption", err)
	for p, sender := range commits {
		at := dmSeedBase.Add(time.Duration(p[0]*100+p[1]) * time.Minute)
		_, err := e.fs.Doc(fmt.Sprintf("conversations/%s/commits/%010d_%010d", id, p[0], p[1])).Set(ctx, map[string]any{
			"data": []byte("opaque commit"), "senderId": sender, "gen": p[0], "epoch": p[1], "createdAt": at, "expireAt": at.Add(30 * 24 * time.Hour),
		})
		e.call(t, "seed commit", err)
	}
	for i, sender := range encFrom {
		at := dmSeedBase.Add(time.Hour + time.Duration(i)*time.Second)
		_, err := e.fs.Doc(fmt.Sprintf("conversations/%s/messages/%032x", id, 0xe0+i)).Set(ctx, map[string]any{
			"senderId": sender, "text": "", "state": "VISIBLE", "requestHash": "h", "createdAt": at,
			"ciphertext": []byte("opaque ct"), "commitment": bytes.Repeat([]byte{3}, 32), "mlsGen": gen, "mlsEpoch": epoch,
			"mlsKey": fmt.Sprintf("%d:%d", gen, epoch), "ctExpireAt": at.Add(30 * 24 * time.Hour),
		})
		e.call(t, "seed encrypted message", err)
	}
}

// e2eeWelcome writes one welcome for owner's device about conversation id, in the stored shape (no uid in it).
func (e *lifecycleEnv) e2eeWelcome(t *testing.T, owner, id, docID string, gen, epoch int64) {
	t.Helper()
	at := dmSeedBase.Add(2 * time.Hour)
	_, err := e.fs.Doc("users/"+owner+"/dmWelcomes/"+docID).Set(context.Background(), map[string]any{
		"deviceId": "seed-device-" + docID[:6], "convId": id, "gen": gen, "epoch": epoch, "data": []byte("opaque welcome"),
		"createdAt": at, "expireAt": at.Add(30 * 24 * time.Hour),
	})
	e.call(t, "seed welcome", err)
}

func (e *lifecycleEnv) e2eeSeedWorld(t *testing.T) e2eeSeedWorld {
	t.Helper()
	w := e2eeSeedWorld{a: e.newUser(t), b: e.newUser(t)}
	a, b := w.a.uid, w.b.uid
	w.acc = e.seedConversation(t, a, b, "ACCEPTED", "", "", dmMsg{a, "a plain"}, dmMsg{b, "b plain"})
	e.e2eeSeed(t, w.acc, 2, 1, map[[2]int64]string{{1, 0}: a, {1, 1}: b, {1, 2}: a, {2, 0}: b}, a, b, a)
	w.gone = e.seedGoneConversation(t, a)
	ghost := fmt.Sprintf("ghost-%s", a[:10])
	e.e2eeSeed(t, w.gone, 1, 2, map[[2]int64]string{{1, 0}: a, {1, 1}: ghost}, a, ghost)
	e.e2eeWelcome(t, a, w.acc, strings.Repeat("a", 32), 2, 0)  // B's reset welcomed A's device
	e.e2eeWelcome(t, a, w.gone, strings.Repeat("c", 32), 1, 0) // the gone tree's init welcomed A's device
	e.e2eeWelcome(t, b, w.acc, strings.Repeat("b", 32), 1, 0)  // A's init welcomed B's device
	w.roles = map[string]string{a: "A", b: "B", ghost: "ghost", messaging.DeletedUID: "deleted"}
	return w
}

// e2eeDigest describes the world's messaging documents by role, so two runs on different uids compare.
func (e *lifecycleEnv) e2eeDigest(t *testing.T, w e2eeSeedWorld) string {
	t.Helper()
	ctx := context.Background()
	role := func(v any) string {
		if r, ok := w.roles[fmt.Sprint(v)]; ok {
			return r
		}
		return "?"
	}
	var lines []string
	for name, id := range map[string]string{"accepted": w.acc, "gone": w.gone} {
		snap, err := e.fs.Doc("conversations/" + id).Get(ctx)
		if err != nil || !snap.Exists() {
			lines = append(lines, name+": no conversation document")
		} else {
			d := snap.Data()
			var parts []string
			for uid := range stringSet(d["participants"]) {
				parts = append(parts, role(uid))
			}
			slices.Sort(parts)
			lines = append(lines, fmt.Sprintf("%s: participants=%v encryption=%v pair=%v:%v", name, parts, d["encryption"], d["mlsGen"], d["mlsEpoch"]))
		}
		for _, m := range e.docsUnder(t, e.fs.Collection("conversations").Doc(id).Collection("messages")) {
			d := m.Data()
			_, ct := d["ciphertext"]
			_, cm := d["commitment"]
			_, exp := d["ctExpireAt"]
			lines = append(lines, fmt.Sprintf("%s: msg %s from=%s state=%v text=%q ct=%v commitment=%v ctExpireAt=%v ctRemoved=%v mlsKey=%v",
				name, m.Ref.ID[24:], role(d["senderId"]), d["state"], d["text"], ct, cm, exp, d["ctRemoved"], d["mlsKey"]))
		}
		for _, c := range e.docsUnder(t, e.fs.Collection("conversations").Doc(id).Collection("commits")) {
			s, _ := c.DataAt("senderId")
			lines = append(lines, fmt.Sprintf("%s: commit %s from=%s", name, c.Ref.ID, role(s)))
		}
	}
	for _, u := range []testUser{w.a, w.b} {
		for _, d := range e.docsUnder(t, e.fs.Collection("users").Doc(u.uid).Collection("dmWelcomes")) {
			lines = append(lines, fmt.Sprintf("welcome of %s: %s", role(u.uid), d.Ref.ID[:4]))
		}
	}
	slices.Sort(lines)
	return strings.Join(lines, "\n")
}

// requireE2EEErased checks what A's erasure must leave, independent of any other run.
func (e *lifecycleEnv) requireE2EEErased(t *testing.T, w e2eeSeedWorld) {
	t.Helper()
	e.requireNoResidue(t, w.a.uid)
	e.requireMessagingGone(t, w.gone)
	if left := e.docsUnder(t, e.fs.Collection("conversations").Doc(w.gone).Collection("commits")); len(left) != 0 {
		t.Errorf("the gone tree kept %d commit records", len(left))
	}
	if left := e.docsUnder(t, e.fs.Collection("users").Doc(w.a.uid).Collection("dmWelcomes")); len(left) != 0 {
		t.Errorf("users/{A}/dmWelcomes kept %d documents", len(left))
	}
}

// TestAccountLifecycle_MessagingE2EECrashAtEverySideEffect: kill the instance after each side effect of the deletion of an
// account with an encrypted conversation (live peer) and an encrypted tree whose peer is gone, and require the clean
// run's end state.
func TestAccountLifecycle_MessagingE2EECrashAtEverySideEffect(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds one account per crash point")
	}
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	clean := e.e2eeSeedWorld(t)
	cleanPlan := &crashPlan{}
	cc := e.newCrashChain(t, cleanPlan)
	msg := e.beginDeletion(t, richAccount{a: clean.a}, "e2ee-crash-clean-0001")
	e.pastGate(t, clean.a.uid)
	if deaths, _ := cc.pump(t, msg); deaths != 0 {
		t.Fatalf("clean run had %d deaths", deaths)
	}
	e.requireE2EEErased(t, clean)
	want := e.e2eeDigest(t, clean)
	total := cleanPlan.n
	t.Logf("clean run: %d side effects; ops %v\nend state:\n%s", total, cleanPlan.ops, want)
	assertDMOrder(t, cleanPlan.ops)

	for k := 1; k <= total; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k, cleanPlan.ops[k-1]), func(t *testing.T) {
			w := e.e2eeSeedWorld(t)
			plan := &crashPlan{at: k}
			cc := e.newCrashChain(t, plan)
			msg := e.beginDeletion(t, richAccount{a: w.a}, fmt.Sprintf("e2ee-crash-delete-%04d", k))
			e.pastGate(t, w.a.uid)
			if deaths, _ := cc.pump(t, msg); deaths != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d; ops run: %v)", deaths, plan.n, total, plan.ops)
			}
			assertDMOrder(t, plan.ops)
			e.requireE2EEErased(t, w)
			if got := e.e2eeDigest(t, w); got != want {
				t.Errorf("end state differs from the clean run.\n--- clean\n%s\n--- death after op %d (%s)\n%s", want, k, plan.ops[k-1], got)
			}
		})
	}
}
