//go:build integration

package apiserver

// W7-6: the `messaging` deletion step on the production job handler with the T16 fault injection. The conversation tree
// of a deleted account is erased in a bounded, resumable sequence of calls (gone mark, tombstones, entries, tree); a kill
// after any side effect must end in the clean run's state. Two shapes: the rich T16 account carries a conversation whose
// peer is gone already (the whole tree is deleted, so the residue sweep stays clean), and the dedicated matrix below
// keeps live peers, whose conversations survive with tombstones.

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
)

// dmSeedBase is the fixed instant of the seeded conversations. It is never compared with the real clock.
var dmSeedBase = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

// dmMsg is one seeded message: sender uid and text, one second apart.
type dmMsg struct{ sender, text string }

// seedConversation writes conversations/{id}, its messages and both participants' entries directly (the stored shapes of
// ADR-0027 D1). requestTo != "" makes it an unaccepted REQUEST whose recipient's entry is in dmRequests. goneUID, when
// set, is the participant that already deleted the account (its entries are absent, as its own eraser left them).
func (e *lifecycleEnv) seedConversation(t *testing.T, a, b, state, requestTo, goneUID string, msgs ...dmMsg) string {
	t.Helper()
	ctx := context.Background()
	id := messaging.ConversationID(a, b)
	parts := []string{a, b}
	slices.Sort(parts)
	conv := map[string]any{"kind": "DIRECT", "participants": parts, "state": state, "requestCount": int64(0), "createdAt": dmSeedBase, "updatedAt": dmSeedBase}
	if requestTo != "" {
		conv["requestFrom"], conv["requestTo"], conv["requestCount"] = other(parts, requestTo), requestTo, int64(len(msgs))
	}
	if goneUID != "" {
		conv["gone"] = []string{goneUID}
	}
	set := func(path string, data map[string]any) {
		t.Helper()
		if _, err := e.fs.Doc(path).Set(ctx, data); err != nil {
			t.Fatalf("seed %s: %v", path, err)
		}
	}
	set("conversations/"+id, conv)
	for i, m := range msgs {
		at := dmSeedBase.Add(time.Duration(i) * time.Second)
		set(fmt.Sprintf("conversations/%s/messages/%032x", id, i+1), map[string]any{
			"senderId": m.sender, "text": m.text, "state": "VISIBLE", "requestHash": "h", "createdAt": at,
		})
	}
	last := msgs[len(msgs)-1]
	for _, uid := range parts {
		if uid == goneUID {
			continue
		}
		folder := "dmInbox"
		if requestTo == uid {
			folder = "dmRequests"
		}
		peer := other(parts, uid)
		set("users/"+uid+"/"+folder+"/"+id, map[string]any{
			"peerId": peer, "peer": map[string]any{"handle": "h-" + peer[:6], "displayName": "Peer", "avatarThumbUrl": "", "verified": false},
			"lastMessageAt": dmSeedBase.Add(time.Duration(len(msgs)) * time.Second),
			"last":          map[string]any{"messageId": "m", "fromSelf": last.sender == uid, "snippet": last.text, "state": "VISIBLE"},
			"unreadCount":   int64(1), "silent": false, "createdAt": dmSeedBase,
		})
	}
	return id
}

func other(parts []string, uid string) string {
	if parts[0] == uid {
		return parts[1]
	}
	return parts[0]
}

// seedGoneConversation gives the account a conversation with a peer that deleted its account already: A's erasure
// deletes the whole tree, so nothing of it may remain.
func (e *lifecycleEnv) seedGoneConversation(t *testing.T, a string) string {
	t.Helper()
	ghost := fmt.Sprintf("ghost-%s", a[:10])
	return e.seedConversation(t, a, ghost, "ACCEPTED", "", ghost, dmMsg{a, "hello ghost"}, dmMsg{ghost, "hello a"}, dmMsg{a, "bye"})
}

// requireMessagingGone: nothing of the conversation tree survives.
func (e *lifecycleEnv) requireMessagingGone(t *testing.T, convID string) {
	t.Helper()
	ctx := context.Background()
	if fsDocExists(t, e.fs, "conversations/"+convID) {
		t.Errorf("conversations/%s survived", convID[:8])
	}
	if docs, err := e.fs.Collection("conversations").Doc(convID).Collection("messages").Limit(1).Documents(ctx).GetAll(); err != nil || len(docs) != 0 {
		t.Errorf("conversations/%s/messages survived: %d docs, err %v", convID[:8], len(docs), err)
	}
}

// dmWorld is the dedicated matrix's account A with the three conversations of a user that talks to people.
type dmWorld struct {
	a, b, c        testUser
	acc, req, gone string // conversation ids: accepted with live B, request A received from live C, tree with a gone peer
	roles          map[string]string
}

func (e *lifecycleEnv) dmWorld(t *testing.T) dmWorld {
	t.Helper()
	w := dmWorld{a: e.newUser(t), b: e.newUser(t), c: e.newUser(t)}
	w.acc = e.seedConversation(t, w.a.uid, w.b.uid, "ACCEPTED", "", "",
		dmMsg{w.a.uid, "a1"}, dmMsg{w.b.uid, "b1"}, dmMsg{w.a.uid, "a2"}, dmMsg{w.b.uid, "b2"}, dmMsg{w.a.uid, "a3"})
	w.req = e.seedConversation(t, w.a.uid, w.c.uid, "REQUEST", w.a.uid, "", dmMsg{w.c.uid, "c1"}, dmMsg{w.c.uid, "c2"})
	w.gone = e.seedGoneConversation(t, w.a.uid)
	w.roles = map[string]string{w.a.uid: "A", w.b.uid: "B", w.c.uid: "C"}
	return w
}

// digest describes the messaging documents of the world by role (never by uid), so two runs on different uids compare.
func (e *lifecycleEnv) dmDigest(t *testing.T, w dmWorld) string {
	t.Helper()
	ctx := context.Background()
	role := func(uid string) string {
		if r, ok := w.roles[uid]; ok {
			return r
		}
		if uid == messaging.DeletedUID {
			return "deleted"
		}
		return "ghost"
	}
	var lines []string
	for name, id := range map[string]string{"accepted": w.acc, "request": w.req, "gone": w.gone} {
		snap, err := e.fs.Doc("conversations/" + id).Get(ctx)
		if err != nil || !snap.Exists() {
			lines = append(lines, name+": no conversation document")
		} else {
			g, _ := snap.DataAt("gone")
			var goneRoles []string
			for uid := range stringSet(g) {
				goneRoles = append(goneRoles, role(uid))
			}
			slices.Sort(goneRoles)
			state, _ := snap.DataAt("state")
			lines = append(lines, fmt.Sprintf("%s: state=%v gone=%v", name, state, goneRoles))
		}
		msgs, err := e.fs.Collection("conversations").Doc(id).Collection("messages").OrderBy("createdAt", firestore.Asc).Documents(ctx).GetAll()
		e.call(t, "messages", err)
		for _, m := range msgs {
			d := m.Data()
			lines = append(lines, fmt.Sprintf("%s: msg from=%s state=%v text=%q hash=%q", name, role(fmt.Sprint(d["senderId"])), d["state"], d["text"], d["requestHash"]))
		}
		for _, uid := range []string{w.a.uid, w.b.uid, w.c.uid} {
			for _, folder := range []string{"dmInbox", "dmRequests"} {
				s, err := e.fs.Doc("users/" + uid + "/" + folder + "/" + id).Get(ctx)
				if err != nil || !s.Exists() {
					continue
				}
				peer, _ := s.DataAt("peer.displayName")
				snippet, _ := s.DataAt("last.snippet")
				lstate, _ := s.DataAt("last.state")
				lines = append(lines, fmt.Sprintf("%s: %s/%s peer=%v snippet=%q lastState=%v", name, role(uid), folder, peer, snippet, lstate))
			}
		}
	}
	slices.Sort(lines)
	return strings.Join(lines, "\n")
}

// requireDMErased checks what the step must have done for A, independent of any other run. The global T11 residue sweep
// runs too, with no allowlist entry: the surviving peers' copies hold no uid of A (ADR-0027 D11).
func (e *lifecycleEnv) requireDMErased(t *testing.T, w dmWorld) {
	t.Helper()
	ctx := context.Background()
	e.requireNoResidue(t, w.a.uid)
	for _, id := range []string{w.acc, w.req, w.gone} {
		for _, folder := range []string{"dmInbox", "dmRequests"} {
			if fsDocExists(t, e.fs, "users/"+w.a.uid+"/"+folder+"/"+id) {
				t.Errorf("A's %s entry for %s survived", folder, id[:8])
			}
		}
	}
	e.requireMessagingGone(t, w.gone)
	// The accepted conversation: B keeps its 2 messages, A's 3 are tombstones, B's entry is the placeholder.
	msgs, err := e.fs.Collection("conversations").Doc(w.acc).Collection("messages").Documents(ctx).GetAll()
	e.call(t, "messages", err)
	var tombs, intact int
	for _, m := range msgs {
		d := m.Data()
		switch {
		case d["senderId"] == messaging.DeletedUID && d["state"] == "DELETED_ACCOUNT" && d["text"] == "":
			tombs++
		case d["senderId"] == w.b.uid && d["state"] == "VISIBLE" && strings.HasPrefix(fmt.Sprint(d["text"]), "b"):
			intact++
		}
	}
	if tombs != 3 || intact != 2 {
		t.Errorf("accepted conversation: %d tombstones and %d intact, want 3 and 2", tombs, intact)
	}
	if v, _ := e.entryField(t, w.b.uid, "dmInbox", w.acc, "peer.displayName"); v != messaging.DeletedAccountName {
		t.Errorf("B's entry peer = %v, want %q", v, messaging.DeletedAccountName)
	}
	if v, _ := e.entryField(t, w.c.uid, "dmInbox", w.req, "peer.displayName"); v != messaging.DeletedAccountName {
		t.Errorf("C's entry peer = %v, want %q", v, messaging.DeletedAccountName)
	}
}

func (e *lifecycleEnv) entryField(t *testing.T, uid, folder, convID, path string) (any, bool) {
	t.Helper()
	s, err := e.fs.Doc("users/" + uid + "/" + folder + "/" + convID).Get(context.Background())
	if err != nil || !s.Exists() {
		return nil, false
	}
	v, err := s.DataAt(path)
	return v, err == nil
}

// TestAccountLifecycle_MessagingCrashAtEverySideEffect: kill the instance after each side effect of a deletion of an
// account with an accepted conversation, a received request and a tree whose peer is gone, and require the clean run's
// end state: tombstones for the live peers, nothing of the gone peer's tree, no entry of A's.
func TestAccountLifecycle_MessagingCrashAtEverySideEffect(t *testing.T) {
	if testing.Short() {
		t.Skip("seeds one account per crash point")
	}
	e := newLifecycleEnvCfg(t, nil, relaxLimits)

	clean := e.dmWorld(t)
	cleanPlan := &crashPlan{}
	cc := e.newCrashChain(t, cleanPlan)
	msg := e.beginDeletion(t, richAccount{a: clean.a}, "dm-crash-clean-0001")
	e.pastGate(t, clean.a.uid)
	if deaths, _ := cc.pump(t, msg); deaths != 0 {
		t.Fatalf("clean run had %d deaths", deaths)
	}
	e.requireDMErased(t, clean)
	want := e.dmDigest(t, clean)
	total := cleanPlan.n
	messagingOps := 0
	for _, op := range cleanPlan.ops {
		if op == "step.messaging" {
			messagingOps++
		}
	}
	t.Logf("clean run: %d side effects, %d of them messaging step calls; ops %v", total, messagingOps, cleanPlan.ops)
	if messagingOps < 10 {
		t.Fatalf("only %d messaging step calls: the scenario no longer reaches every phase", messagingOps)
	}
	assertDMOrder(t, cleanPlan.ops)

	for k := 1; k <= total; k++ {
		t.Run(fmt.Sprintf("death after side effect %02d (%s)", k, cleanPlan.ops[k-1]), func(t *testing.T) {
			w := e.dmWorld(t)
			plan := &crashPlan{at: k}
			cc := e.newCrashChain(t, plan)
			msg := e.beginDeletion(t, richAccount{a: w.a}, fmt.Sprintf("dm-crash-delete-%04d", k))
			e.pastGate(t, w.a.uid)
			if deaths, _ := cc.pump(t, msg); deaths != 1 {
				t.Fatalf("deaths = %d, want exactly 1 (ran %d side effects, clean run %d)", deaths, plan.n, total)
			}
			assertDMOrder(t, plan.ops)
			e.requireDMErased(t, w)
			if got := e.dmDigest(t, w); got != want {
				t.Errorf("end state differs from the clean run.\n--- clean\n%s\n--- death after op %d (%s)\n%s", want, k, plan.ops[k-1], got)
			}
		})
	}
}

// assertDMOrder is assertOrder for an account with no export: the Auth disable first, the messaging step after the
// posts and graph steps and before the identity step (it ran once the step list reached it), the Auth user, and
// users/{uid} last with nothing after it.
func assertDMOrder(t *testing.T, ops []string) {
	t.Helper()
	first := func(op string) int { return slices.Index(ops, op) }
	chain := []string{"auth.UpdateUser", "step.posts", "step.graph", "step.messaging", "repo.DeleteQuotas", "auth.DeleteUser", "repo.DeleteUserDoc"}
	for _, op := range chain {
		if first(op) < 0 {
			t.Fatalf("%q never happened: %v", op, ops)
		}
	}
	for i := 1; i < len(chain); i++ {
		if first(chain[i-1]) > first(chain[i]) {
			t.Errorf("%q came after %q: %v", chain[i-1], chain[i], ops)
		}
	}
	if last := slices.Index(ops, "repo.DeleteUserDoc"); last != len(ops)-1 {
		t.Errorf("operations after users/{uid} was deleted: %v", ops[last+1:])
	}
}

// TestAccountLifecycle_MessagingBothDeleted: the peer deletes the account after A did (or A after the peer): the second
// erasure removes the whole tree, through the production chain.
func TestAccountLifecycle_MessagingBothDeleted(t *testing.T) {
	e := newLifecycleEnvCfg(t, nil, relaxLimits)
	w := e.dmWorld(t)
	for i, u := range []testUser{w.a, w.b} {
		msg := e.beginDeletion(t, richAccount{a: u}, fmt.Sprintf("dm-both-delete-%04d", i))
		e.pastGate(t, u.uid)
		for code := 0; code != http.StatusNoContent; {
			code = e.deliverJSON(t, msg)
		}
		// A delivery that ran out of work budget chained a continuation: drain until the job is done.
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
	e.requireMessagingGone(t, w.acc)
	for _, uid := range []string{w.a.uid, w.b.uid} {
		if fsDocExists(t, e.fs, "users/"+uid+"/dmInbox/"+w.acc) {
			t.Errorf("%s's inbox entry survived", uid[:6])
		}
	}
	// Neither uid appears anywhere: A's conversation with the live C was scrubbed by A's own erasure (ADR-0027 D11).
	e.requireNoResidue(t, w.a.uid)
	e.requireNoResidue(t, w.b.uid)
}
