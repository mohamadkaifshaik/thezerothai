//go:build integration

package messaging

// The MLS sync RPCs (Task 6) on the emulator, over real mls_init, commits, resets and encrypted sends: commits listed in
// order across a generation change with the current pair fresh from another instance, leftover records filtered, every
// message of an epoch exactly once across pages, welcomes of exactly one device of the caller, AckWelcomes deleting only
// the caller's own welcomes.

import (
	"bytes"
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func (e *itEnv) listCommitsOn(svc *service, uid, convID string, g, ep uint64, size int32) *messagingv1.ListConversationCommitsResponse {
	e.t.Helper()
	resp, err := svc.ListCommits(context.Background(), uid, &messagingv1.ListConversationCommitsRequest{ConversationId: convID, AfterGeneration: g, AfterEpoch: ep, PageSize: size})
	if err != nil {
		e.t.Fatalf("ListCommits: %v", err)
	}
	return resp
}

// apierrToConnect is err as the client sees it (nil stays nil).
func apierrToConnect(err error) error {
	if err == nil {
		return nil
	}
	return apierr.ToConnect(err)
}

func commitPairs(resp *messagingv1.ListConversationCommitsResponse) []string {
	var out []string
	for _, c := range resp.GetCommits() {
		out = append(out, fmt.Sprintf("%d:%d", c.GetMlsGeneration(), c.GetMlsEpoch()))
	}
	return out
}

// initMLS starts encryption between alice and bob with a real mls_init (welcomes for devBob1 and devAlice2) and returns
// the conversation id; the conversation stands at (1, 1).
func (e *itEnv) initMLS() string {
	e.t.Helper()
	e.withDevices()
	e.mutual(alice, bob)
	resp, err := e.send(alice, initTo(skey(1), bob, "init", devBob1, devAlice2))
	if err != nil {
		e.t.Fatalf("mls_init: %v", err)
	}
	e.tick(time.Second)
	return resp.GetConversation().GetId()
}

// Commits in order across a reset, paged, from_self per user, and the current pair fresh although this instance cached the
// conversation before another instance committed (the one read-only snapshot reads it, never the cache).
func TestSyncIT_CommitsAcrossAResetAndFreshPair(t *testing.T) {
	e := newIT(t, nil)
	convID := e.initMLS()
	reader := e.newService()
	// The reader instance caches the conversation at (1, 1) through ListMessages.
	if _, err := reader.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: convID}); err != nil {
		t.Fatal(err)
	}
	writer := e.newService()
	e.mustCommitIT(writer, bob, commitReq(ckey(1), convID, 1, 1, "c11"))
	e.tick(time.Second)
	e.mustCommitIT(writer, alice, commitReq(ckey(2), convID, 1, 2, "c12"))
	e.tick(time.Second)
	e.mustCommitIT(writer, bob, resetReq(ckey(3), convID, 1, "r1", devAlice1))
	e.tick(time.Second)
	e.mustCommitIT(writer, alice, commitReq(ckey(4), convID, 2, 1, "c21"))
	if c, _ := reader.convs.Get(convID); c.MlsGen != 1 || c.MlsEpoch != 1 {
		t.Fatalf("the reader's cached copy moved: (%d, %d); the test needs a stale cache", c.MlsGen, c.MlsEpoch)
	}

	all := e.listCommitsOn(reader, alice, convID, 0, 0, 0)
	if got := commitPairs(all); !slices.Equal(got, []string{"1:0", "1:1", "1:2", "2:0", "2:1"}) {
		t.Fatalf("commits = %v", got)
	}
	if all.GetMlsGeneration() != 2 || all.GetMlsEpoch() != 2 || all.GetMore() {
		t.Errorf("pair (%d, %d) more %v, want the fresh (2, 2), false", all.GetMlsGeneration(), all.GetMlsEpoch(), all.GetMore())
	}
	wantSelf := map[string]bool{"1:0": true, "1:2": true, "2:1": true} // alice's: the init, (1, 2) and (2, 1)
	for _, c := range all.GetCommits() {
		key := fmt.Sprintf("%d:%d", c.GetMlsGeneration(), c.GetMlsEpoch())
		if c.GetFromSelf() != wantSelf[key] || c.GetCreatedAt() == nil || len(c.GetCommit()) == 0 {
			t.Errorf("commit %s: from_self %v created %v bytes %q", key, c.GetFromSelf(), c.GetCreatedAt(), c.GetCommit())
		}
	}
	if c := all.GetCommits()[3]; !bytes.Equal(c.GetCommit(), []byte("commit:r1")) {
		t.Errorf("reset record bytes = %q", c.GetCommit())
	}
	// Bob sees the opposite from_self.
	for i, c := range e.listCommitsOn(reader, bob, convID, 0, 0, 0).GetCommits() {
		if c.GetFromSelf() == all.GetCommits()[i].GetFromSelf() {
			t.Errorf("commit %d: from_self is not per user", i)
		}
	}
	// Pages of 2 across the generation change: every record once, more on full pages.
	var paged []string
	g, ep := uint64(0), uint64(0)
	for range 4 {
		p := e.listCommitsOn(reader, alice, convID, g, ep, 2)
		paged = append(paged, commitPairs(p)...)
		if p.GetMlsGeneration() != 2 || p.GetMlsEpoch() != 2 {
			t.Errorf("page pair = (%d, %d)", p.GetMlsGeneration(), p.GetMlsEpoch())
		}
		if !p.GetMore() {
			break
		}
		last := p.GetCommits()[len(p.GetCommits())-1]
		g, ep = last.GetMlsGeneration(), last.GetMlsEpoch()
	}
	if !slices.Equal(paged, commitPairs(all)) {
		t.Errorf("paged = %v", paged)
	}
	// A device after the reset's own pair (2, 0) gets (2, 1) only.
	if got := commitPairs(e.listCommitsOn(reader, alice, convID, 2, 0, 0)); !slices.Equal(got, []string{"2:1"}) {
		t.Errorf("after (2, 0) = %v", got)
	}

	// The one NOT_FOUND for a stranger and an unknown id; nothing but the conversation was read for them (no way to see
	// that here except the answer); a plaintext conversation is empty with (0, 0).
	e.addUser("uid-carol", "carol", false)
	_, stranger := reader.ListCommits(context.Background(), "uid-carol", &messagingv1.ListConversationCommitsRequest{ConversationId: convID})
	_, unknown := reader.ListCommits(context.Background(), alice, &messagingv1.ListConversationCommitsRequest{ConversationId: ConversationID(alice, "uid-nobody")})
	if connect.CodeOf(apierrToConnect(stranger)) != connect.CodeNotFound || !bytes.Equal(wireBytes(t, stranger), wireBytes(t, unknown)) {
		t.Errorf("stranger %v / unknown %v", stranger, unknown)
	}
	e.mutual(alice, "uid-carol")
	plain := e.must(alice, toUser(skey(50), "uid-carol", "plain")).GetConversation().GetId()
	if p := e.listCommitsOn(reader, alice, plain, 0, 0, 0); len(p.GetCommits()) != 0 || p.GetMlsGeneration() != 0 || p.GetMlsEpoch() != 0 {
		t.Errorf("plaintext = %v", p)
	}
}

// Records of an earlier conversation with the same id are filtered: one at or after the current pair, one created before
// the conversation (seeded directly, as the eraser leaves them until Task 8 deletes commits with the tree).
func TestSyncIT_CommitsLeftoversFiltered(t *testing.T) {
	e := newIT(t, nil)
	convID := e.initMLS()
	e.mustCommitIT(e.svc, bob, commitReq(ckey(1), convID, 1, 1, "c11"))
	conv, _ := e.conv(convID)
	old := conv.CreatedAt.Add(-72 * time.Hour)
	for _, p := range [][2]int64{{1, 2}, {1, 9}, {3, 0}} { // at the current pair (1, 2), and beyond it
		e.putCommitDoc(convID, p[0], p[1], old)
	}
	resp := e.listCommitsOn(e.svc, alice, convID, 0, 0, 0)
	if got := commitPairs(resp); !slices.Equal(got, []string{"1:0", "1:1"}) || resp.GetMlsEpoch() != 2 {
		t.Errorf("commits = %v pair (%d, %d), want 1:0 1:1 at (1, 2)", got, resp.GetMlsGeneration(), resp.GetMlsEpoch())
	}
	// Below the current pair but older than the conversation: a pair this incarnation skipped with a reset.
	e.mustCommitIT(e.svc, alice, resetReq(ckey(2), convID, 1, "r", devBob1))
	e.putCommitDoc(convID, 1, 5, old)
	if got := commitPairs(e.listCommitsOn(e.svc, alice, convID, 0, 0, 0)); !slices.Equal(got, []string{"1:0", "1:1", "2:0"}) {
		t.Errorf("after the reset = %v, want 1:0 1:1 2:0", got)
	}
}

// putCommitDoc writes a commit record directly (a leftover of an earlier conversation with this id).
func (e *itEnv) putCommitDoc(convID string, gen, epoch int64, at time.Time) {
	e.t.Helper()
	if _, err := e.fs.Collection("conversations").Doc(convID).Collection(commitsCollection).Doc(commitDocID(gen, epoch)).Set(context.Background(), CommitDoc{
		Data: []byte("leftover"), SenderID: bob, Gen: gen, Epoch: epoch, CreatedAt: at, ExpireAt: at.Add(CommitRetention),
	}); err != nil {
		e.t.Fatal(err)
	}
}

// Every message of one epoch exactly once across pages, in id order, nothing of another epoch or generation (the same epoch
// number of another generation included); a cleared message is still returned; a swept message has no ciphertext and
// ciphertext_removed; a non-participant gets the one NOT_FOUND.
func TestSyncIT_EpochMessages(t *testing.T) {
	e := newIT(t, nil)
	convID := e.initMLS() // the init's own message is at (1, 1)
	want := map[string]bool{}
	n := 1
	send := func(from string, g, ep uint64) string {
		n++
		resp, err := e.send(from, encByConv(skey(n), convID, g, ep, fmt.Sprintf("ct %d", n)))
		if err != nil {
			t.Fatalf("send %d at (%d, %d): %v", n, g, ep, err)
		}
		e.tick(time.Millisecond)
		return resp.GetMessage().GetId()
	}
	for i := range 3 {
		send([]string{alice, bob}[i%2], 1, 1)
	}
	e.mustCommitIT(e.svc, bob, commitReq(ckey(1), convID, 1, 1, "c11"))
	for i := range 23 {
		want[send([]string{alice, bob}[i%2], 1, 2)] = true
	}
	e.mustCommitIT(e.svc, alice, resetReq(ckey(2), convID, 1, "r", devBob1))
	e.mustCommitIT(e.svc, alice, commitReq(ckey(3), convID, 2, 1, "c21"))
	for range 4 {
		send(alice, 2, 2) // (2, 2): the same epoch number in the next generation
	}
	// Alice deletes the conversation for herself: every message so far is at or before her clearedAt.
	if _, err := e.svc.Delete(verifiedCtx(), alice, &messagingv1.DeleteConversationRequest{IdempotencyKey: "delete-key-00000001", ConversationId: convID}); err != nil {
		t.Fatal(err)
	}
	// One message of (1, 2) swept by the retention job (seeded: the sweep is Task 9).
	var swept string
	for id := range want {
		swept = id
		break
	}
	if _, err := e.fs.Collection("conversations").Doc(convID).Collection(messagesCollection).Doc(swept).Update(context.Background(), []firestore.Update{
		{Path: "ctRemoved", Value: true}, {Path: "ciphertext", Value: firestore.Delete}, {Path: "commitment", Value: firestore.Delete},
	}); err != nil {
		t.Fatal(err)
	}

	reader := e.newService()
	got := map[string]int{}
	var order []string
	tok, pages := "", 0
	for {
		resp, err := reader.ListEpochMessages(context.Background(), alice, &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: 1, MlsEpoch: 2, PageSize: 10, PageToken: tok})
		if err != nil {
			t.Fatal(err)
		}
		pages++
		for _, m := range resp.GetMessages() {
			got[m.GetId()]++
			order = append(order, m.GetId())
			if m.GetMlsGeneration() != 1 || m.GetMlsEpoch() != 2 || m.GetText() != "" || m.GetSharedPost() != nil {
				t.Errorf("message %s: pair (%d, %d) text %q", m.GetId(), m.GetMlsGeneration(), m.GetMlsEpoch(), m.GetText())
			}
			if m.GetId() == swept {
				if !m.GetCiphertextRemoved() || len(m.GetCiphertext()) != 0 || len(m.GetReportCommitment()) != 0 || m.GetState() != messagingv1.MessageState_MESSAGE_STATE_VISIBLE {
					t.Errorf("swept message = %v", m)
				}
			} else if m.GetCiphertextRemoved() || len(m.GetCiphertext()) == 0 || len(m.GetReportCommitment()) != CommitmentBytes {
				t.Errorf("message %s lost its ciphertext", m.GetId())
			}
		}
		if tok = resp.GetNextPageToken(); tok == "" {
			break
		}
		if pages > 5 {
			t.Fatal("paging does not end")
		}
	}
	if len(got) != len(want) || pages != 3 {
		t.Errorf("got %d distinct messages in %d pages, want %d in 3", len(got), pages, len(want))
	}
	for id, c := range got {
		if c != 1 || !want[id] {
			t.Errorf("message %s returned %d times (of the epoch: %v)", id, c, want[id])
		}
	}
	if !slices.IsSorted(order) {
		t.Error("not in message id order")
	}
	// ListMessages hides the cleared messages; ListEpochMessages does not.
	if lm, _ := reader.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: convID}); len(lm.GetMessages()) != 0 {
		t.Errorf("ListMessages after the delete = %d messages", len(lm.GetMessages()))
	}
	// (2, 2) has its own four; (1, 1) the init message and three more.
	for _, p := range []struct {
		g, ep uint64
		want  int
	}{{2, 2, 4}, {1, 1, 4}, {2, 1, 0}, {3, 2, 0}} {
		resp, err := reader.ListEpochMessages(context.Background(), bob, &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: p.g, MlsEpoch: p.ep, PageSize: 50})
		if err != nil || len(resp.GetMessages()) != p.want || resp.GetNextPageToken() != "" {
			t.Errorf("(%d, %d) = %d messages, %v; want %d", p.g, p.ep, len(resp.GetMessages()), err, p.want)
		}
	}
	e.addUser("uid-carol", "carol", false)
	_, stranger := reader.ListEpochMessages(context.Background(), "uid-carol", &messagingv1.ListEpochMessagesRequest{ConversationId: convID, MlsGeneration: 1, MlsEpoch: 2})
	_, lmStranger := reader.ListMessages(context.Background(), "uid-carol", &messagingv1.ListMessagesRequest{ConversationId: convID})
	if connect.CodeOf(apierrToConnect(stranger)) != connect.CodeNotFound || !bytes.Equal(wireBytes(t, stranger), wireBytes(t, lmStranger)) {
		t.Errorf("stranger = %v, want ListMessages' NOT_FOUND", stranger)
	}
}

// Welcomes of exactly one device of the caller: never another device's, never another user's; a foreign device id is
// refused; AckWelcomes deletes only the caller's own welcome, a foreign id deletes nothing, and a replay is a success.
func TestSyncIT_Welcomes(t *testing.T) {
	e := newIT(t, nil)
	convID := e.initMLS() // welcomes: bob/devBob1, alice/devAlice2, both labelled (1, 0)
	e.mustCommitIT(e.svc, bob, commitReq(ckey(1), convID, 1, 1, "add", devBob2))
	ctx := context.Background()
	list := func(uid, dev string) []*messagingv1.Welcome {
		t.Helper()
		resp, err := e.svc.ListWelcomes(ctx, uid, &messagingv1.ListWelcomesRequest{DeviceId: dev})
		if err != nil {
			t.Fatalf("ListWelcomes(%s): %v", dev, err)
		}
		return resp.GetWelcomes()
	}
	b1, b2, a2 := list(bob, devBob1), list(bob, devBob2), list(alice, devAlice2)
	if len(b1) != 1 || len(b2) != 1 || len(a2) != 1 || len(list(alice, devAlice1)) != 0 {
		t.Fatalf("welcomes b1 %d b2 %d a2 %d", len(b1), len(b2), len(a2))
	}
	if w := b1[0]; w.GetConversationId() != convID || w.GetMlsGeneration() != 1 || w.GetMlsEpoch() != 0 || string(w.GetWelcome()) != "welcome:init" {
		t.Errorf("bob's init welcome = %v", w)
	}
	if w := b2[0]; w.GetMlsGeneration() != 1 || w.GetMlsEpoch() != 1 || string(w.GetWelcome()) != "welcome:add" {
		t.Errorf("bob's commit welcome = %v", w)
	}
	// Another user's device, an unknown one: VALIDATION device_id, nothing listed.
	for _, dev := range []string{devBob1, "never-registered-0001"} {
		_, err := e.svc.ListWelcomes(ctx, alice, &messagingv1.ListWelcomesRequest{DeviceId: dev})
		if _, reason, meta := reasonOf(t, err); reason.String() != "ERROR_REASON_VALIDATION" || meta["field"] != "device_id" {
			t.Errorf("alice lists %s: %v", dev, err)
		}
	}
	// An inactive but registered device of the caller is accepted.
	e.devices.mu.Lock()
	e.devices.active[bob] = []string{devBob2}
	e.devices.registered = map[string][]string{bob: {devBob1}}
	e.devices.mu.Unlock()
	if len(list(bob, devBob1)) != 1 {
		t.Error("an inactive registered device lost its welcome list")
	}
	// Bob acknowledges his devBob1 welcome AND alice's welcome id (foreign: not under his path), through devBob2.
	ack := &messagingv1.AckWelcomesRequest{IdempotencyKey: "ack-key-0000000001", DeviceId: devBob2, Ids: []string{b1[0].GetId(), a2[0].GetId()}}
	for range 2 {
		if _, err := e.svc.AckWelcomes(ctx, bob, ack); err != nil {
			t.Fatalf("AckWelcomes: %v", err)
		}
	}
	if len(list(bob, devBob1)) != 0 || len(list(bob, devBob2)) != 1 || len(list(alice, devAlice2)) != 1 {
		t.Errorf("after the ack: b1 %d b2 %d a2 %d, want 0 1 1", len(list(bob, devBob1)), len(list(bob, devBob2)), len(list(alice, devAlice2)))
	}
	if n := len(e.docsIn("users/" + alice + "/dmWelcomes")); n != 1 {
		t.Errorf("alice's welcome documents = %d, want 1 (a foreign ack deletes nothing)", n)
	}
	// Alice cannot acknowledge through bob's device.
	_, err := e.svc.AckWelcomes(ctx, alice, &messagingv1.AckWelcomesRequest{IdempotencyKey: "ack-key-0000000002", DeviceId: devBob2, Ids: []string{a2[0].GetId()}})
	if _, _, meta := reasonOf(t, err); meta["field"] != "device_id" {
		t.Errorf("ack through another user's device = %v", err)
	}
}
