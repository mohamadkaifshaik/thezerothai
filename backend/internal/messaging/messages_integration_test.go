//go:build integration

package messaging

import (
	"bytes"
	"context"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// chargedProfiles charges the directory read of a cold lookup (1 read) like identity.Directory does on a miss.
type chargedProfiles struct{ inner Profiles }

func (c chargedProfiles) GetProfiles(ctx context.Context, uids []string) (map[string]identityProfile, error) {
	budget.FromContext(ctx).AddReads(1)
	return c.inner.GetProfiles(ctx, uids)
}
func (c chargedProfiles) Forget(uids ...string) { c.inner.Forget(uids...) }

// msgSvc is a second instance (cold caches) whose graph and directory reads are charged, so the budgets below are the
// per-RPC table of ADR-0027 and not only the repo's own reads.
func (e *itEnv) msgSvc() *service {
	svc := e.newService()
	svc.d.Social = chargedSocial{e.social}
	svc.d.Profiles = chargedProfiles{e.profs}
	return svc
}

// listMsgs runs ListMessages under its own counter, pre-charged with the account-status interceptor's 1 read.
func (e *itEnv) listMsgs(svc *service, uid string, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	c.AddReads(1)
	resp, err := svc.ListMessages(ctx, uid, req)
	return resp, c, err
}

func (e *itEnv) mustListMsgs(svc *service, uid string, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, *budget.Counter) {
	e.t.Helper()
	resp, c, err := e.listMsgs(svc, uid, req)
	if err != nil {
		e.t.Fatalf("ListMessages: %v", err)
	}
	return resp, c
}

func (e *itEnv) markRead(svc *service, uid, convID string) (*budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	c.AddReads(1)
	_, err := svc.MarkRead(ctx, uid, &messagingv1.MarkConversationReadRequest{ConversationId: convID})
	return c, err
}

func idsOf(r *messagingv1.ListMessagesResponse) []string {
	out := make([]string, 0, len(r.GetMessages()))
	for _, m := range r.GetMessages() {
		out = append(out, m.GetId())
	}
	return out
}

// Given 45 messages, then 20 / 20 / 5, newest first, no overlap. Budget (ADR-0027 table): first or older page of 20
// 24 reads (interceptor, conversation, query 20, peer, caller graph), 0 writes; a page of 50 is 54.
func TestListMessages_PagesWithinBudget(t *testing.T) {
	e := newIT(t, nil)
	msgs := make([][2]string, 0, 45)
	for i := range 45 {
		sender := alice
		if i%2 == 1 {
			sender = bob
		}
		msgs = append(msgs, [2]string{sender, fmt.Sprintf("message %02d", i)})
	}
	id := e.seedConversation(alice, bob, stateAccepted, base, msgs...)
	svc := e.msgSvc()

	first, c := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	budgettest.Assert(t, "ListMessages first page of 20", c, budgettest.Budget{Reads: 24})
	if c.Reads() != 24 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("first page reads/writes/deletes = %d/%d/%d, want 24/0/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if len(first.Messages) != 20 || first.NextPageToken == "" || first.SinceToken == "" || first.GapPageToken != "" || first.Conversation == nil {
		t.Fatalf("first page: %d messages next=%q since=%q gap=%q conversation=%v", len(first.Messages), first.NextPageToken, first.SinceToken, first.GapPageToken, first.Conversation)
	}
	if first.Messages[0].Text != "message 44" || !first.Messages[0].FromSelf || first.Messages[1].Text != "message 43" || first.Messages[1].FromSelf {
		t.Errorf("newest messages = %+v / %+v", first.Messages[0], first.Messages[1])
	}
	if cv := first.Conversation; cv.Peer.UserId != bob || cv.Peer.Handle != "bob" || !cv.CanReply {
		t.Errorf("conversation = %+v", cv)
	}
	second, c2 := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageToken: first.NextPageToken})
	budgettest.Assert(t, "ListMessages older page", c2, budgettest.Budget{Reads: 24})
	third, c3 := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageToken: second.NextPageToken})
	if len(second.Messages) != 20 || len(third.Messages) != 5 || third.NextPageToken != "" || third.SinceToken != "" || second.SinceToken != "" {
		t.Fatalf("pages: %d / %d, third next=%q", len(second.Messages), len(third.Messages), third.NextPageToken)
	}
	if third.Conversation == nil || c3.Writes() != 0 {
		t.Errorf("older page conversation = %v writes = %d", third.Conversation, c3.Writes())
	}
	seen := map[string]bool{}
	for _, r := range []*messagingv1.ListMessagesResponse{first, second, third} {
		for _, m := range r.Messages {
			if seen[m.Id] {
				t.Fatalf("message %s twice", m.Id)
			}
			seen[m.Id] = true
		}
	}
	if len(seen) != 45 {
		t.Errorf("distinct messages = %d, want 45", len(seen))
	}

	// The maximum page: 54 reads cold.
	_, c50 := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageSize: 50})
	budgettest.Assert(t, "ListMessages page of 50", c50, budgettest.Budget{Reads: 54})
	if c50.Reads() != 49 { // 45 messages: 1 + 1 + 45 + 1 + 1
		t.Errorf("page of 45 reads = %d, want 49", c50.Reads())
	}
	// Warm caches: only the interceptor and the query.
	_, warm := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	if warm.Reads() != 1+20+1+1 { // interceptor + query + peer + graph (the conversation is cached; the fakes charge on every call)
		t.Errorf("warm first page reads = %d, want 23", warm.Reads())
	}
}

// Given a poll with 0 new messages, then 3 reads cold (interceptor, conversation, query min 1), 2 warm; the response has
// no conversation and the poll reads neither the peer profile nor the graph. A new message adds 1 read.
func TestListMessages_PollWithinBudget(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(bob, toUser(skey(1), alice, "hello"))
	id := ConversationID(alice, bob)
	e.tick(time.Minute)
	first, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	if first.SinceToken == "" || first.Conversation == nil {
		t.Fatalf("first = %+v", first)
	}

	poller := e.msgSvc() // a cold instance
	profBefore, graphBefore := e.listProfileCalls(), e.social.calls
	quiet, c := e.mustListMsgs(poller, alice, &messagingv1.ListMessagesRequest{ConversationId: id, SinceToken: first.SinceToken})
	budgettest.Assert(t, "ListMessages poll cold", c, budgettest.Budget{Reads: 3})
	if c.Reads() != 2 && c.Reads() != 3 {
		t.Errorf("poll reads = %d, want 3 (2 + the settle-window message the token trails)", c.Reads())
	}
	if quiet.Conversation != nil || quiet.GapPageToken != "" || quiet.NextPageToken != "" || quiet.SinceToken == "" {
		t.Errorf("quiet poll = %+v", quiet)
	}
	if e.listProfileCalls() != profBefore || e.social.calls != graphBefore {
		t.Error("a poll read the peer profile or the graph")
	}
	// Warm: the conversation comes from the cache.
	_, warm := e.mustListMsgs(poller, alice, &messagingv1.ListMessagesRequest{ConversationId: id, SinceToken: quiet.SinceToken})
	if warm.Reads() > 2 {
		t.Errorf("warm poll reads = %d, want <= 2", warm.Reads())
	}

	// One new message from bob: 1 more read, delivered first.
	e.tick(time.Minute)
	e.must(bob, toUser(skey(2), alice, "again"))
	news, cn := e.mustListMsgs(poller, alice, &messagingv1.ListMessagesRequest{ConversationId: id, SinceToken: quiet.SinceToken})
	if len(news.Messages) == 0 || news.Messages[0].Text != "again" || news.Messages[0].FromSelf {
		t.Fatalf("poll = %+v", news.Messages)
	}
	budgettest.Assert(t, "ListMessages poll with new", cn, budgettest.Budget{Reads: 3 + int64(len(news.Messages))})
}

// A poll whose page is full returns gap_page_token; the token pages the gap and stops at the old since position.
func TestListMessages_GapFillOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "old 1"}, [2]string{bob, "old 2"})
	svc := e.msgSvc()
	first, _ := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	// 25 new messages, ten seconds apart (wider than the settle window), after the first page.
	for i := range 25 {
		mid := fmt.Sprintf("%032x", 5000+i)
		if _, err := e.fs.Collection("conversations").Doc(id).Collection("messages").Doc(mid).Set(context.Background(), MsgDoc{
			SenderID: bob, Text: fmt.Sprintf("new %02d", i), State: msgVisible, RequestHash: "h", CreatedAt: base.Add(time.Minute).Add(time.Duration(i) * 10 * time.Second),
		}); err != nil {
			t.Fatal(err)
		}
	}
	poll, _ := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id, SinceToken: first.SinceToken, PageSize: 10})
	if len(poll.Messages) != 10 || poll.GapPageToken == "" || poll.Conversation != nil || poll.Messages[0].Text != "new 24" {
		t.Fatalf("poll = %d messages gap=%q conversation=%v", len(poll.Messages), poll.GapPageToken, poll.Conversation)
	}
	got := idsOf(poll)
	token := poll.GapPageToken
	for token != "" {
		page, _ := e.mustListMsgs(svc, alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageToken: token, PageSize: 10})
		if page.Conversation != nil {
			t.Fatal("a gap fill carries a conversation")
		}
		got = append(got, idsOf(page)...)
		token = page.NextPageToken
	}
	// 25 new messages + the settle-window duplicate of the newest old one (base+1 s is older than 5 s before... the token
	// trails the newest old message by 5 s, so both old messages are inside it): 27 in all, each once.
	seen := map[string]bool{}
	for _, id := range got {
		if seen[id] {
			t.Fatalf("message %s twice in %d", id, len(got))
		}
		seen[id] = true
	}
	if len(got) != 27 {
		t.Errorf("poll + gap fill returned %d messages, want 27", len(got))
	}
}

// Given clearedAt, then older messages are not returned (and are still there for the peer).
func TestListMessages_ClearedAtOnEmulator(t *testing.T) {
	e := newIT(t, nil)
	var msgs [][2]string
	for i := range 10 {
		msgs = append(msgs, [2]string{bob, fmt.Sprintf("m%d", i)})
	}
	id := e.seedConversation(alice, bob, stateAccepted, base, msgs...)
	// Alice cleared the thread between m5 (base+5s) and m6.
	if _, err := e.fs.Collection("conversations").Doc(id).Update(context.Background(), []firestore.Update{{Path: "clearedAt", Value: map[string]time.Time{alice: base.Add(5 * time.Second)}}}); err != nil {
		t.Fatal(err)
	}
	resp, c := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	if len(resp.Messages) != 4 || resp.Messages[3].Text != "m6" || resp.NextPageToken != "" {
		t.Fatalf("alice sees %d messages (last %q) next=%q, want m9..m6", len(resp.Messages), resp.Messages[len(resp.Messages)-1].Text, resp.NextPageToken)
	}
	if c.Reads() != 1+1+4+1+1 {
		t.Errorf("reads = %d, want 8 (the cleared messages are not read)", c.Reads())
	}
	bobView, _ := e.mustListMsgs(e.msgSvc(), bob, &messagingv1.ListMessagesRequest{ConversationId: id})
	if len(bobView.Messages) != 10 {
		t.Errorf("bob sees %d messages, want 10", len(bobView.Messages))
	}
	// A page walk below the clear stops: an older page token on a full first page ends at the clear.
	one, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageSize: 4})
	rest, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id, PageToken: one.NextPageToken, PageSize: 4})
	if len(one.Messages) != 4 || len(rest.Messages) != 0 {
		t.Errorf("walk = %d then %d, want 4 then 0", len(one.Messages), len(rest.Messages))
	}
}

// Tombstones keep their state and lose their text; an erased sender is never from_self; an erased peer reads
// "Deleted account" and the thread is read-only.
func TestListMessages_TombstonesAndDeletedPeer(t *testing.T) {
	e := newIT(t, nil)
	id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "visible"}, [2]string{bob, "to remove"}, [2]string{bob, "to erase"})
	docs, err := e.fs.Collection("conversations").Doc(id).Collection("messages").OrderBy("createdAt", firestore.Asc).Documents(context.Background()).GetAll()
	if err != nil || len(docs) != 3 {
		t.Fatalf("seeded messages: %v %d", err, len(docs))
	}
	if _, err := docs[1].Ref.Update(context.Background(), []firestore.Update{{Path: "text", Value: ""}, {Path: "state", Value: msgRemoved}}); err != nil {
		t.Fatal(err)
	}
	if _, err := docs[2].Ref.Update(context.Background(), []firestore.Update{{Path: "text", Value: ""}, {Path: "state", Value: msgDeletedAccount}, {Path: "senderId", Value: DeletedUID}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.fs.Collection("conversations").Doc(id).Update(context.Background(), []firestore.Update{{Path: "participants", Value: []string{alice, DeletedUID}}, {Path: "gone", Value: []string{DeletedUID}}}); err != nil {
		t.Fatal(err)
	}
	before := e.listProfileCalls()
	resp, _ := e.mustListMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: id})
	if e.listProfileCalls() != before {
		t.Error("an erased peer was looked up")
	}
	m := resp.Messages
	if len(m) != 3 || m[0].State != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT || m[0].Text != "" || m[0].FromSelf ||
		m[1].State != messagingv1.MessageState_MESSAGE_STATE_REMOVED || m[1].Text != "" ||
		m[2].State != messagingv1.MessageState_MESSAGE_STATE_VISIBLE || m[2].Text != "visible" {
		t.Fatalf("messages = %+v", m)
	}
	if cv := resp.Conversation; cv.Peer.DisplayName != DeletedAccountName || cv.Peer.UserId != "" || cv.CanReply {
		t.Errorf("conversation = %+v", cv)
	}
}

// Given a non-participant, then the same bytes as an unknown id, after at most 2 reads and without reading messages.
func TestListMessages_NotFoundByteIdentical(t *testing.T) {
	e := newIT(t, nil)
	id := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "private"})
	e.addUser(carol, "carol", false)
	unknown := ConversationID(alice, "uid-nobody")

	_, cNon, errNon := e.listMsgs(e.msgSvc(), carol, &messagingv1.ListMessagesRequest{ConversationId: id})
	_, cUnk, errUnk := e.listMsgs(e.msgSvc(), carol, &messagingv1.ListMessagesRequest{ConversationId: unknown})
	_, _, errUnkAlice := e.listMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: unknown})
	for name, err := range map[string]error{"non-participant": errNon, "unknown": errUnk, "unknown, participant elsewhere": errUnkAlice} {
		if codeOf(err) != connect.CodeNotFound {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
	}
	if !bytes.Equal(wireBytes(t, errNon), wireBytes(t, errUnk)) || !bytes.Equal(wireBytes(t, errNon), wireBytes(t, errUnkAlice)) {
		t.Errorf("NOT_FOUND bytes differ: %q / %q / %q", wireBytes(t, errNon), wireBytes(t, errUnk), wireBytes(t, errUnkAlice))
	}
	for name, c := range map[string]*budget.Counter{"non-participant": cNon, "unknown": cUnk} {
		budgettest.Assert(t, "ListMessages NOT_FOUND "+name, c, budgettest.Budget{Reads: 2})
	}
	// Malformed: VALIDATION, 0 reads.
	_, cBad, errBad := e.listMsgs(e.msgSvc(), alice, &messagingv1.ListMessagesRequest{ConversationId: "nope"})
	if codeOf(errBad) != connect.CodeInvalidArgument || cBad.Reads() != 1 {
		t.Errorf("malformed id: err = %v reads = %d, want INVALID_ARGUMENT with only the interceptor's read", errBad, cBad.Reads())
	}
}

// Given MarkConversationRead, then unreadCount is 0 and lastReadAt set on the caller's own entry only, the badge cache is
// evicted, and the cost is the interceptor's 1 read and 1 write.
func TestMarkRead_WritesOwnEntryOnly(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	e.must(bob, toUser(skey(1), alice, "one"))
	e.tick(time.Second)
	e.must(bob, toUser(skey(2), alice, "two"))
	id := ConversationID(alice, bob)
	if ent, _ := e.entry(alice, dmInboxCollection, id); ent.UnreadCount != 2 {
		t.Fatalf("setup: unreadCount = %d, want 2", ent.UnreadCount)
	}
	before, _ := e.entry(bob, dmInboxCollection, id)

	svc := e.newService()
	e.tick(time.Minute)
	c, err := e.markRead(svc, alice, id)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "MarkConversationRead", c, budgettest.Budget{Reads: 1, Writes: 1})
	if c.Reads() != 1 || c.Writes() != 1 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 1/1/0", c.Reads(), c.Writes(), c.Deletes())
	}
	got, _ := e.entry(alice, dmInboxCollection, id)
	if got.UnreadCount != 0 || !got.LastReadAt.Equal(e.now().Truncate(time.Microsecond)) {
		t.Errorf("alice's entry: unreadCount = %d lastReadAt = %v", got.UnreadCount, got.LastReadAt)
	}
	if got.PeerID != bob || got.Last.Snippet != "two" || got.LastMessageAt.IsZero() {
		t.Errorf("the update touched other fields: %+v", got)
	}
	after, _ := e.entry(bob, dmInboxCollection, id)
	if after != before {
		t.Errorf("bob's entry changed: %+v -> %+v", before, after)
	}
	svcBadge := e.badge.got
	if len(svcBadge) == 0 || svcBadge[len(svcBadge)-1][0] != alice {
		t.Errorf("badge evictions = %v, want a last eviction of alice", svcBadge)
	}

	// A later message counts from zero again (the Increment still applies).
	e.tick(time.Second)
	e.must(bob, toUser(skey(3), alice, "three"))
	if ent, _ := e.entry(alice, dmInboxCollection, id); ent.UnreadCount != 1 {
		t.Errorf("unreadCount after a new message = %d, want 1", ent.UnreadCount)
	}
}

// A request sits in dmRequests: mark-read finds it there. A missing entry (unknown id, non-participant, deleted for the
// caller) is success with 0 writes and creates nothing.
func TestMarkRead_RequestsFolderAndMissingEntry(t *testing.T) {
	e := newIT(t, nil)
	e.must(bob, toUser(skey(1), alice, "request")) // not mutual: lands in alice's dmRequests
	id := ConversationID(alice, bob)
	if ent, ok := e.entry(alice, dmRequestsCollection, id); !ok || ent.UnreadCount != 1 {
		t.Fatalf("setup: requests entry = %+v ok=%v", ent, ok)
	}
	c, err := e.markRead(e.newService(), alice, id)
	if err != nil || c.Writes() != 1 {
		t.Fatalf("err = %v writes = %d, want success with 1 write", err, c.Writes())
	}
	if ent, _ := e.entry(alice, dmRequestsCollection, id); ent.UnreadCount != 0 || ent.LastReadAt.IsZero() {
		t.Errorf("requests entry = %+v", ent)
	}
	if _, ok := e.entry(alice, dmInboxCollection, id); ok {
		t.Error("mark-read created an inbox entry")
	}

	e.addUser(carol, "carol", false)
	for name, tt := range map[string]struct{ uid, id string }{
		"non-participant": {carol, id},
		"unknown id":      {alice, ConversationID(alice, "uid-nobody")},
	} {
		c, err := e.markRead(e.newService(), tt.uid, tt.id)
		if err != nil {
			t.Fatalf("%s: err = %v, want success", name, err)
		}
		budgettest.Assert(t, "MarkConversationRead "+name, c, budgettest.Budget{Reads: 1})
		if c.Writes() != 0 {
			t.Errorf("%s: writes = %d, want 0", name, c.Writes())
		}
		if _, ok := e.entry(tt.uid, dmInboxCollection, tt.id); ok {
			t.Errorf("%s: an entry was created", name)
		}
		if _, ok := e.entry(tt.uid, dmRequestsCollection, tt.id); ok {
			t.Errorf("%s: a requests entry was created", name)
		}
	}
	if _, ok := e.entry(carol, dmInboxCollection, id); ok {
		t.Error("carol got an entry in alice and bob's conversation")
	}
}
