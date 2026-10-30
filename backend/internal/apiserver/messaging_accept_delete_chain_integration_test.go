//go:build integration

package apiserver

// AcceptMessageRequest and DeleteConversation (ADR-0027, ticket W7-9) over the real Build chain on the emulators: the
// account-status, rate-limit and degraded-mode interceptors, the flag classes (Accept per caller and per peer, Delete
// only "not globally off"), the byte-identical NOT_FOUND, the documents each RPC writes, clearedAt applied at once on
// the instance that handled the delete, and the budget table of the RPC doc comments (Accept 3 reads / 2 writes /
// 1 delete, Delete 3 / 1 / 1), asserted with budgettest on the logged fs_reads / fs_writes / fs_deletes of the request
// line. A chain that measures is booted AFTER the data is written, so no cache is warm (cold instance).

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/messaging"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	rpcAccept = "/dzeroth.messaging.v1.MessagingService/AcceptMessageRequest"
	rpcDelete = "/dzeroth.messaging.v1.MessagingService/DeleteConversation"
)

func (e *dmChain) accept(who dmUser, convID string) error {
	_, err := e.msg.AcceptMessageRequest(context.Background(), authed(who.token, &messagingv1.AcceptMessageRequestRequest{
		IdempotencyKey: contractKey("dm-accept"), ConversationId: convID,
	}))
	return err
}

func (e *dmChain) del(who dmUser, convID string) error {
	_, err := e.msg.DeleteConversation(context.Background(), authed(who.token, &messagingv1.DeleteConversationRequest{
		IdempotencyKey: contractKey("dm-delete"), ConversationId: convID,
	}))
	return err
}

// thread is the texts of the first ListMessages page the caller sees, newest first.
func (e *dmChain) thread(t *testing.T, who dmUser, convID string) []string {
	t.Helper()
	r, err := e.msg.ListMessages(context.Background(), authed(who.token, &messagingv1.ListMessagesRequest{ConversationId: convID}))
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	var out []string
	for _, m := range r.Msg.GetMessages() {
		out = append(out, m.GetText())
	}
	return out
}

func (e *dmChain) folder(t *testing.T, who dmUser, f messagingv1.Folder) []string {
	t.Helper()
	r, err := e.msg.ListConversations(context.Background(), authed(who.token, &messagingv1.ListConversationsRequest{Folder: f}))
	if err != nil {
		t.Fatalf("ListConversations: %v", err)
	}
	var out []string
	for _, c := range r.Msg.GetConversations() {
		out = append(out, c.GetId())
	}
	return out
}

// request makes a non-mutual a -> b request of n messages and returns the conversation id.
func (e *dmChain) request(t *testing.T, a, b dmUser, n int) string {
	t.Helper()
	for i := range n {
		e.mustSend(t, a, b, fmt.Sprintf("request %d", i))
	}
	return messaging.ConversationID(a.uid, b.uid)
}

// Given B accepts, then both see the conversation in the Inbox, the state is ACCEPTED, B's unread count is kept, A's
// entry is untouched, A's messages past the old cap land in B's Inbox, and B's reply is a plain accepted-conversation send
// (not a request). The budget on a cold instance is 3 reads / 2 writes / 1 delete; a replay is 2 reads and writes nothing.
func TestMessagingChain_AcceptMovesTheRequest(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 2)
	if req, ok := setup.entry(t, b, a, "dmRequests"); !ok || req["unreadCount"] != int64(2) {
		t.Fatalf("setup: b's dmRequests = %v, %v", req, ok)
	}
	aliceBefore, _ := setup.entry(t, a, b, "dmInbox")

	e := newDMChain(t, nil) // cold
	if err := e.accept(b, id); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	line := e.lineBudget(t, rpcAccept)
	budgettest.Assert(t, "AcceptMessageRequest cold", line, budgettest.Budget{Reads: 4, Writes: 3, Deletes: 1})
	if line.Reads() != 4 || line.Writes() != 3 || line.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 4/3/1", line.Reads(), line.Writes(), line.Deletes())
	}
	t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d", "accept, cold", line.Reads(), line.Writes(), line.Deletes())

	conv, _ := setup.convDoc(t, a, b)
	if conv["state"] != "ACCEPTED" || conv["requestTo"] != b.uid || conv["requestFrom"] != a.uid {
		t.Errorf("conversation = %v", conv)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); ok {
		t.Error("the request entry was not deleted")
	}
	in, ok := setup.entry(t, b, a, "dmInbox")
	if !ok || in["unreadCount"] != int64(2) {
		t.Errorf("b's dmInbox = %v, %v, want the request entry with unreadCount 2", in, ok)
	}
	// W7-25a: the requester's entry loses requestPending and gets the accept changedAt; everything else is untouched.
	after, _ := setup.entry(t, a, b, "dmInbox")
	if aliceBefore["requestPending"] != true || after["requestPending"] != nil {
		t.Errorf("a's requestPending: %v -> %v, want true -> absent", aliceBefore["requestPending"], after["requestPending"])
	}
	for _, m := range []map[string]any{aliceBefore, after} {
		delete(m, "requestPending")
		delete(m, "changedAt")
	}
	if fmt.Sprint(after) != fmt.Sprint(aliceBefore) {
		t.Errorf("a's entry changed beyond the flag and changedAt: %v -> %v", aliceBefore, after)
	}
	for _, who := range []dmUser{a, b} {
		got := newDMChain(t, nil).folder(t, who, messagingv1.Folder_FOLDER_INBOX)
		if len(got) != 1 || got[0] != id {
			t.Errorf("inbox = %v, want the accepted conversation", got)
		}
	}
	if got := newDMChain(t, nil).folder(t, b, messagingv1.Folder_FOLDER_REQUESTS); len(got) != 0 {
		t.Errorf("b's requests = %v, want none", got)
	}

	// The request line: kind, state and the replay flag, never an id or a uid.
	last := e.logs.requestLines(rpcAccept)[0]
	for k, want := range map[string]any{"kind": "accept", "state": "accepted", "replay": false} {
		if last[k] != want {
			t.Errorf("request line %s = %v, want %v", k, last[k], want)
		}
	}
	if raw := fmt.Sprint(last); strings.Contains(raw, a.uid) || strings.Contains(raw, b.uid) || strings.Contains(raw, id) {
		t.Errorf("the request line names a uid or the conversation id: %s", raw)
	}

	// A replay (a lost response): success, no write.
	replay := newDMChain(t, nil)
	if err := replay.accept(b, id); err != nil {
		t.Fatalf("replay: %v", err)
	}
	rl := replay.lineBudget(t, rpcAccept)
	budgettest.Assert(t, "AcceptMessageRequest replay", rl, budgettest.Budget{Reads: 2})
	if rl.Writes() != 0 || rl.Deletes() != 0 {
		t.Errorf("replay wrote %d / deleted %d", rl.Writes(), rl.Deletes())
	}

	// A's messages past the old cap of three land in B's Inbox; B's reply is an ordinary send.
	for i := range 3 {
		setup.mustSend(t, a, b, fmt.Sprintf("after accept %d", i))
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); ok {
		t.Error("a message after the accept recreated the request entry")
	}
	if in, _ := setup.entry(t, b, a, "dmInbox"); in["unreadCount"] != int64(5) {
		t.Errorf("b's unreadCount = %v, want 5", in["unreadCount"])
	}
	setup.mustSend(t, b, a, "hi a")
	if conv, _ := setup.convDoc(t, a, b); conv["state"] != "ACCEPTED" || conv["requestCount"] != int64(2) {
		t.Errorf("conversation after the reply = %v", conv)
	}
}

// Given B deletes, then B's folders lack the conversation, clearedAt[B] is set, the state stays REQUEST (A's cap still
// applies), and the budget on a cold instance is 3 reads / 1 write / 1 delete. Given the same instance lists the thread
// afterwards, B sees nothing at once, while A still sees everything; A's next message recreates B's request entry with
// only that message visible. A repeat of the delete is success with no write.
func TestMessagingChain_DeleteAppliesAtOnce(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 3)

	e := newDMChain(t, nil) // cold, and the instance that handles every call below
	if got := e.thread(t, b, id); len(got) != 3 {
		t.Fatalf("b reads %v before the delete, want 3 (this also caches the conversation on e)", got)
	}
	if err := e.del(b, id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	line := e.lineBudget(t, rpcDelete)
	// The account-status read is cached on e (warm), and Delete always reads the conversation and the entry fresh in its
	// transaction, so this is 2 reads, below the cold figure of 3 measured next.
	t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d", "delete, warm instance", line.Reads(), line.Writes(), line.Deletes())
	if line.Writes() != 1 || line.Deletes() != 1 {
		t.Errorf("writes/deletes = %d/%d, want 1/1", line.Writes(), line.Deletes())
	}
	if got := e.thread(t, b, id); len(got) != 0 {
		t.Errorf("the deleting instance still shows %v to b", got)
	}
	if got := newDMChain(t, nil).thread(t, a, id); len(got) != 3 {
		t.Errorf("a reads %v, want 3 (delete for me removes nothing for the peer)", got)
	}
	conv, _ := setup.convDoc(t, a, b)
	cleared, _ := conv["clearedAt"].(map[string]any)
	if conv["state"] != "REQUEST" || conv["requestCount"] != int64(3) || cleared[b.uid] == nil || cleared[a.uid] != nil {
		t.Errorf("conversation = %v, want REQUEST, count 3, clearedAt[b] only", conv)
	}
	for _, f := range []string{"dmInbox", "dmRequests"} {
		if _, ok := setup.entry(t, b, a, f); ok {
			t.Errorf("b still has a %s entry", f)
		}
	}
	if got := e.folder(t, b, messagingv1.Folder_FOLDER_REQUESTS); len(got) != 0 {
		t.Errorf("b's requests = %v", got)
	}
	if n := setup.messageCount(t, a, b); n != 3 {
		t.Errorf("messages = %d, want 3", n)
	}
	// A's cap still applies to a request that was deleted.
	_, err := e.send(a, b, contractKey("dm"), "a fourth request")
	d := wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)

	// Cold budget of a first delete (a new request, cold instance) and of a repeat.
	a2 := setup.user(t)
	id3 := setup.request(t, a2, b, 1)
	cold := newDMChain(t, nil)
	if err := cold.del(b, id3); err != nil {
		t.Fatal(err)
	}
	cl := cold.lineBudget(t, rpcDelete)
	budgettest.Assert(t, "DeleteConversation cold", cl, budgettest.Budget{Reads: 3, Writes: 1, Deletes: 1})
	if cl.Reads() != 3 || cl.Writes() != 1 || cl.Deletes() != 1 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 3/1/1", cl.Reads(), cl.Writes(), cl.Deletes())
	}
	t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d", "delete, cold", cl.Reads(), cl.Writes(), cl.Deletes())
	last := cold.logs.requestLines(rpcDelete)[0]
	for k, want := range map[string]any{"kind": "delete", "state": "request", "folder": "requests", "replay": false} {
		if last[k] != want {
			t.Errorf("request line %s = %v, want %v", k, last[k], want)
		}
	}
	if raw := fmt.Sprint(last); strings.Contains(raw, a2.uid) || strings.Contains(raw, b.uid) || strings.Contains(raw, id3) {
		t.Errorf("the request line names a uid or the conversation id: %s", raw)
	}
	repeat := newDMChain(t, nil)
	if err := repeat.del(b, id3); err != nil {
		t.Fatalf("repeat: %v", err)
	}
	rl := repeat.lineBudget(t, rpcDelete)
	budgettest.Assert(t, "DeleteConversation repeat", rl, budgettest.Budget{Reads: 3})
	if rl.Writes() != 0 || rl.Deletes() != 0 {
		t.Errorf("repeat wrote %d / deleted %d", rl.Writes(), rl.Deletes())
	}

	// A later message of the peer recreates the deleted entry and shows only newer messages. The request above is capped for a,
	// so this part uses an accepted (mutual) conversation.
	c := setup.user(t)
	setup.mutual(t, b, c)
	setup.mustSend(t, c, b, "old")
	id4 := messaging.ConversationID(b.uid, c.uid)
	same := newDMChain(t, nil)
	if got := same.thread(t, b, id4); len(got) != 1 {
		t.Fatalf("setup: %v", got)
	}
	if err := same.del(b, id4); err != nil {
		t.Fatal(err)
	}
	if got := same.thread(t, b, id4); len(got) != 0 {
		t.Errorf("b reads %v right after the delete on the same instance", got)
	}
	setup.mustSend(t, c, b, "new")
	ent, ok := setup.entry(t, b, c, "dmInbox")
	if !ok || ent["unreadCount"] != int64(1) {
		t.Errorf("b's recreated entry = %v, %v", ent, ok)
	}
	if got := newDMChain(t, nil).thread(t, b, id4); len(got) != 1 || got[0] != "new" {
		t.Errorf("b reads %v, want only the newer message", got)
	}
	if got := newDMChain(t, nil).thread(t, c, id4); len(got) != 2 {
		t.Errorf("c reads %v, want both", got)
	}
}

// An unknown id, a non-participant, the requester calling Accept on its own request and a conversation that never was a
// request all answer the same NOT_FOUND bytes, after the interceptor's read and the conversation's, writing nothing; a
// malformed id is VALIDATION after the interceptor's read alone.
func TestMessagingChain_AcceptDeleteNotFoundIsByteIdentical(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b, c, d := setup.user(t), setup.user(t), setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 1)
	setup.mutual(t, a, d)
	setup.mustSend(t, a, d, "mutual")
	mutualID := messaging.ConversationID(a.uid, d.uid)
	unknown := messaging.ConversationID(a.uid, "uid-nobody")
	// A request the recipient already deleted for themselves: still a REQUEST for them, but their entry is gone, so Accept is the
	// same NOT_FOUND after one more read (interceptor, conversation, the missing entry).
	e2, f2 := setup.user(t), setup.user(t)
	deletedID := setup.request(t, e2, f2, 1)
	if err := setup.del(f2, deletedID); err != nil {
		t.Fatal(err)
	}

	type call struct {
		name  string
		rpc   string
		reads int64
		run   func(e *dmChain) error
	}
	calls := []call{
		{"accept: the requester", rpcAccept, 2, func(e *dmChain) error { return e.accept(a, id) }},
		{"accept: a non-participant", rpcAccept, 2, func(e *dmChain) error { return e.accept(c, id) }},
		{"accept: an unknown id", rpcAccept, 2, func(e *dmChain) error { return e.accept(a, unknown) }},
		{"accept: never a request", rpcAccept, 2, func(e *dmChain) error { return e.accept(d, mutualID) }},
		{"delete: a non-participant", rpcDelete, 2, func(e *dmChain) error { return e.del(c, id) }},
		{"delete: an unknown id", rpcDelete, 2, func(e *dmChain) error { return e.del(a, unknown) }},
		{"accept: a request the recipient deleted", rpcAccept, 3, func(e *dmChain) error { return e.accept(f2, deletedID) }},
	}
	var first string
	for i, tc := range calls {
		e := newDMChain(t, nil)
		err := tc.run(e)
		wireError(t, err, connect.CodeNotFound)
		got := wireBytes(t, err)
		if i == 0 {
			first = got
		} else if got != first {
			t.Errorf("%s: NOT_FOUND bytes differ:\n got  %q\n want %q", tc.name, got, first)
		}
		line := e.lineBudget(t, tc.rpc)
		budgettest.Assert(t, tc.name, line, budgettest.Budget{Reads: tc.reads})
		if line.Writes() != 0 || line.Deletes() != 0 {
			t.Errorf("%s: wrote %d / deleted %d", tc.name, line.Writes(), line.Deletes())
		}
	}
	if conv, _ := setup.convDoc(t, a, b); conv["state"] != "REQUEST" || conv["clearedAt"] != nil {
		t.Errorf("a refused call changed the conversation: %v", conv)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); !ok {
		t.Error("b's request entry is gone")
	}
	for _, uid := range []dmUser{a, c} {
		if _, ok := setup.entry(t, uid, b, "dmRequests"); ok {
			t.Errorf("%s got a request entry", uid.uid)
		}
	}
	if _, ok := setup.convDoc(t, a, dmUser{uid: "uid-nobody"}); ok {
		t.Error("an unknown id created a conversation")
	}

	e := newDMChain(t, nil)
	for name, run := range map[string]func() error{
		"accept": func() error { return e.accept(a, "nope") },
		"delete": func() error { return e.del(a, "nope") },
	} {
		err := run()
		dt := wireError(t, err, connect.CodeInvalidArgument)
		assertReason(t, dt, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
		if dt.GetMetadata()["field"] != "conversation_id" {
			t.Errorf("%s: field = %q", name, dt.GetMetadata()["field"])
		}
	}
	budgettest.Assert(t, "malformed ids", e.lineBudget(t, rpcDelete), budgettest.Budget{Reads: 1})
}

// The flag classes (ADR-0027 D6, F6): Accept needs the flag on for the caller (FEATURE_DISABLED, the interceptor's read
// only) and for the peer (CANNOT_MESSAGE, the bytes of any other refusal); Delete needs only "not globally off", so a
// caller dropped from an allowlist, or at percent 0, can still clean up, and global off hides both.
func TestMessagingChain_AcceptDeleteFlagModes(t *testing.T) {
	setup := newDMChain(t, nil)
	allow := func(uids ...dmUser) flags.Spec {
		m := map[string]struct{}{}
		for _, u := range uids {
			m[u.uid] = struct{}{}
		}
		return flags.Spec{Name: "messaging", Mode: flags.Allowlist, Allowlist: m}
	}
	// refusal is the bytes of a SendMessage refused for a recipient outside the cohort.
	s1, s2 := setup.user(t), setup.user(t)
	refusing := newDMChain(t, func(c *config.Config) { c.FeatureMessaging = allow(s1) })
	_, serr := refusing.send(s1, s2, contractKey("dm"), "hi")
	wireError(t, serr, connect.CodeFailedPrecondition)
	cannot := wireBytes(t, serr)

	tests := []struct {
		name       string
		spec       func(a, b dmUser) flags.Spec
		wantAccept string // ok | disabled | cannot
		wantDelete string // ok | disabled
	}{
		{"off", func(a, b dmUser) flags.Spec { return flags.Spec{Name: "messaging", Mode: flags.Off} }, "disabled", "disabled"},
		{"allowlist: both", func(a, b dmUser) flags.Spec { return allow(a, b) }, "ok", "ok"},
		{"allowlist: only the caller", func(a, b dmUser) flags.Spec { return allow(b) }, "cannot", "ok"},
		{"allowlist: only the peer (the caller was dropped)", func(a, b dmUser) flags.Spec { return allow(a) }, "disabled", "ok"},
		{"allowlist: nobody", func(a, b dmUser) flags.Spec { return allow() }, "disabled", "ok"},
		{"percent 0", func(a, b dmUser) flags.Spec { return flags.Spec{Name: "messaging", Mode: flags.Percent} }, "disabled", "ok"},
		{"percent 100", func(a, b dmUser) flags.Spec { return flags.Spec{Name: "messaging", Mode: flags.Percent, Percent: 100} }, "ok", "ok"},
		{"on", func(a, b dmUser) flags.Spec { return flags.Spec{Name: "messaging", Mode: flags.On} }, "ok", "ok"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, b := setup.user(t), setup.user(t)
			id := setup.request(t, a, b, 1)
			spec := tt.spec(a, b)
			setSpec := func(c *config.Config) { c.FeatureMessaging = spec }

			ea := newDMChain(t, setSpec)
			err := ea.accept(b, id)
			switch tt.wantAccept {
			case "ok":
				if err != nil {
					t.Fatalf("Accept: %v", err)
				}
				if conv, _ := setup.convDoc(t, a, b); conv["state"] != "ACCEPTED" {
					t.Errorf("state = %v", conv["state"])
				}
			case "disabled":
				d := wireError(t, err, connect.CodeFailedPrecondition)
				assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if d.GetMetadata()["feature"] != "messaging" {
					t.Errorf("feature = %q", d.GetMetadata()["feature"])
				}
				line := ea.lineBudget(t, rpcAccept)
				budgettest.Assert(t, "AcceptMessageRequest flag off", line, budgettest.Budget{Reads: 1})
				if line.Writes() != 0 || line.Deletes() != 0 {
					t.Errorf("a disabled Accept wrote %d / deleted %d", line.Writes(), line.Deletes())
				}
			case "cannot":
				wireError(t, err, connect.CodeFailedPrecondition)
				if got := wireBytes(t, err); got != cannot {
					t.Errorf("CANNOT_MESSAGE bytes differ from a refused send:\n got  %q\n want %q", got, cannot)
				}
				line := ea.lineBudget(t, rpcAccept)
				budgettest.Assert(t, "AcceptMessageRequest peer off", line, budgettest.Budget{Reads: 2})
				if line.Writes() != 0 || line.Deletes() != 0 {
					t.Errorf("a refused Accept wrote %d / deleted %d", line.Writes(), line.Deletes())
				}
				if conv, _ := setup.convDoc(t, a, b); conv["state"] != "REQUEST" {
					t.Errorf("state = %v after a refused accept", conv["state"])
				}
			}

			// Delete: a fresh request, so the accept above cannot have moved the entry.
			a2, b2 := setup.user(t), setup.user(t)
			id2 := setup.request(t, a2, b2, 1)
			spec = tt.spec(a2, b2)
			ed := newDMChain(t, setSpec)
			err = ed.del(b2, id2)
			if tt.wantDelete == "ok" {
				if err != nil {
					t.Fatalf("Delete: %v", err)
				}
				if _, ok := setup.entry(t, b2, a2, "dmRequests"); ok {
					t.Error("the entry survived the delete")
				}
				if conv, _ := setup.convDoc(t, a2, b2); conv["clearedAt"] == nil {
					t.Error("clearedAt not set")
				}
				return
			}
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			line := ed.lineBudget(t, rpcDelete)
			budgettest.Assert(t, "DeleteConversation flag off", line, budgettest.Budget{Reads: 1})
			if line.Writes() != 0 || line.Deletes() != 0 {
				t.Errorf("a disabled Delete wrote %d / deleted %d", line.Writes(), line.Deletes())
			}
			if _, ok := setup.entry(t, b2, a2, "dmRequests"); !ok {
				t.Error("a disabled Delete removed the entry")
			}
		})
	}
}

// A requester who deleted the account leaves a conversation the recipient cannot accept (CANNOT_MESSAGE) but can still
// delete: clean-up stays possible.
func TestMessagingChain_ErasedRequesterCannotBeAcceptedButCanBeDeleted(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 1)
	if _, err := setup.fs.Doc("conversations/"+id).Update(context.Background(), goneUpdate(a.uid)); err != nil {
		t.Fatal(err)
	}
	e := newDMChain(t, nil)
	err := e.accept(b, id)
	wireError(t, err, connect.CodeFailedPrecondition)
	assertReason(t, wireError(t, err, connect.CodeFailedPrecondition), commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE)
	if line := e.lineBudget(t, rpcAccept); line.Writes() != 0 || line.Deletes() != 0 {
		t.Errorf("a refused Accept wrote %d / deleted %d", line.Writes(), line.Deletes())
	}
	if err := newDMChain(t, nil).del(b, id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); ok {
		t.Error("the entry survived the delete")
	}
}

// DEGRADED_MODE=readonly refuses both mutations in the interceptor, before any handler or read: the request line shows 0
// reads, 0 writes and 0 deletes (not even the account-status read).
func TestMessagingChain_DegradedReadonlyRefusesAcceptAndDelete(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 1)
	e := newDMChain(t, func(c *config.Config) { c.Degraded = config.DegradedReadonly })
	for _, tc := range []struct {
		name string
		rpc  string
		run  func() error
	}{
		{"accept", rpcAccept, func() error { return e.accept(b, id) }},
		{"delete", rpcDelete, func() error { return e.del(b, id) }},
	} {
		d := wireError(t, tc.run(), connect.CodeUnavailable)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_DEGRADED_MODE)
		line := e.lineBudget(t, tc.rpc)
		budgettest.Assert(t, tc.name+" under readonly", line, budgettest.Budget{})
		if line.Reads() != 0 || line.Writes() != 0 || line.Deletes() != 0 {
			t.Errorf("%s under readonly: reads/writes/deletes = %d/%d/%d, want 0/0/0", tc.name, line.Reads(), line.Writes(), line.Deletes())
		}
	}
	if conv, _ := setup.convDoc(t, a, b); conv["state"] != "REQUEST" || conv["clearedAt"] != nil {
		t.Errorf("a refused call changed the conversation: %v", conv)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); !ok {
		t.Error("b's request entry is gone")
	}
}

const rpcMarkRead = "/dzeroth.messaging.v1.MessagingService/MarkConversationRead"

func (e *dmChain) delKey(who dmUser, convID, key string) error {
	_, err := e.msg.DeleteConversation(context.Background(), authed(who.token, &messagingv1.DeleteConversationRequest{IdempotencyKey: key, ConversationId: convID}))
	return err
}

// DeleteConversation stores the digest of its key as conversations.clearedKey.{caller} with clearedAt, and a retry with the same
// key is a replay even after the peer's next message recreated the entry (ADR-0027 2026-10-29 note): through the whole chain,
// the retry writes nothing, keeps the entry and the new message, and the request line says replay.
func TestMessagingChain_DeleteRetryWithTheSameKey(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 1)
	const k1, k2 = "chain-delete-key-00000001", "chain-delete-key-00000002"
	if err := setup.delKey(b, id, k1); err != nil {
		t.Fatal(err)
	}
	if line := setup.lineBudget(t, rpcDelete); line.Writes() != 1 || line.Deletes() != 1 {
		t.Errorf("the delete wrote %d / deleted %d, want 1 / 1 (the key adds no write)", line.Writes(), line.Deletes())
	}
	conv, _ := setup.convDoc(t, a, b)
	keys, _ := conv["clearedKey"].(map[string]any)
	if len(keys) != 1 || keys[b.uid] == nil || keys[b.uid] == "" {
		t.Fatalf("clearedKey = %v, want only b's digest", conv["clearedKey"])
	}
	// The response was lost; a's next message recreates b's request entry.
	setup.mustSend(t, a, b, "after the delete")

	e := newDMChain(t, nil) // a cold instance
	if err := e.delKey(b, id, k1); err != nil {
		t.Fatalf("retry: %v", err)
	}
	line := e.lineBudget(t, rpcDelete)
	budgettest.Assert(t, "DeleteConversation retry with the same key", line, budgettest.Budget{Reads: 3})
	if line.Writes() != 0 || line.Deletes() != 0 {
		t.Errorf("the retry wrote %d / deleted %d", line.Writes(), line.Deletes())
	}
	t.Logf("MSGBUDGET case=%q reads=%d writes=%d deletes=%d", "delete, retry with the same key", line.Reads(), line.Writes(), line.Deletes())
	if last := e.logs.requestLines(rpcDelete)[0]; last["replay"] != true || last["kind"] != "delete" {
		t.Errorf("request line = %v, want kind=delete replay=true", last)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); !ok {
		t.Error("the retry deleted the recreated entry")
	}
	if got := e.thread(t, b, id); len(got) != 1 || got[0] != "after the delete" {
		t.Errorf("b reads %v, want the newer message", got)
	}
	// A new key is a real delete.
	if err := newDMChain(t, nil).delKey(b, id, k2); err != nil {
		t.Fatal(err)
	}
	if _, ok := setup.entry(t, b, a, "dmRequests"); ok {
		t.Error("a delete under a new key left the entry")
	}
	if got := newDMChain(t, nil).thread(t, b, id); len(got) != 0 {
		t.Errorf("b reads %v after the second delete", got)
	}
}

// A malformed idempotency_key is VALIDATION idempotency_key on Accept, Delete and MarkConversationRead alike, after the
// interceptor's read alone, writing nothing (Accept and MarkConversationRead do not store the key; Delete stores its digest).
func TestMessagingChain_MalformedKeyIsValidation(t *testing.T) {
	setup := newDMChain(t, nil)
	a, b := setup.user(t), setup.user(t)
	id := setup.request(t, a, b, 1)
	ctx := context.Background()
	for _, key := range []string{"", "short", "has spaces in the key!!", strings.Repeat("k", 65)} {
		e := newDMChain(t, nil)
		for _, tc := range []struct {
			name string
			rpc  string
			run  func() error
		}{
			{"accept", rpcAccept, func() error {
				_, err := e.msg.AcceptMessageRequest(ctx, authed(b.token, &messagingv1.AcceptMessageRequestRequest{IdempotencyKey: key, ConversationId: id}))
				return err
			}},
			{"delete", rpcDelete, func() error { return e.delKey(b, id, key) }},
			{"mark read", rpcMarkRead, func() error {
				_, err := e.msg.MarkConversationRead(ctx, authed(b.token, &messagingv1.MarkConversationReadRequest{IdempotencyKey: key, ConversationId: id}))
				return err
			}},
		} {
			d := wireError(t, tc.run(), connect.CodeInvalidArgument)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
			if d.GetMetadata()["field"] != "idempotency_key" {
				t.Errorf("%s with key %q: field = %q", tc.name, key, d.GetMetadata()["field"])
			}
			line := e.lineBudget(t, tc.rpc)
			if line.Reads() > 1 || line.Writes() != 0 || line.Deletes() != 0 {
				t.Errorf("%s with key %q: reads/writes/deletes = %d/%d/%d, want at most the interceptor's 1 read and no write", tc.name, key, line.Reads(), line.Writes(), line.Deletes())
			}
		}
	}
	if conv, _ := setup.convDoc(t, a, b); conv["state"] != "REQUEST" || conv["clearedAt"] != nil {
		t.Errorf("a refused call changed the conversation: %v", conv)
	}
	if req, ok := setup.entry(t, b, a, "dmRequests"); !ok || req["unreadCount"] != int64(1) {
		t.Errorf("b's request entry = %v %v, want it intact", req, ok)
	}
}
