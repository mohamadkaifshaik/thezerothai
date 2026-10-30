//go:build integration

package messaging

import (
	"context"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const carol = "uid-carol"

// chargedSocial charges the caller's graph read the way a cold graph.Reader does (1 read), so the budgets below are the
// per-RPC table of ADR-0027 and not only the repo's own reads.
type chargedSocial struct{ inner Social }

func (c chargedSocial) Snapshot(ctx context.Context, uid string) (graph.Snapshot, error) {
	budget.FromContext(ctx).AddReads(1)
	return c.inner.Snapshot(ctx, uid)
}

// listSvc is a second instance whose graph reads are charged.
func (e *itEnv) listSvc() *service {
	svc := e.newService()
	svc.d.Social = chargedSocial{e.social}
	return svc
}

// list runs ListConversations under its own counter, pre-charged with the account-status interceptor's 1 read.
func (e *itEnv) list(svc *service, uid string, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	c.AddReads(1)
	resp, err := svc.ListConversations(ctx, uid, req)
	return resp, c, err
}

func (e *itEnv) mustList(svc *service, uid string, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, *budget.Counter) {
	e.t.Helper()
	resp, c, err := e.list(svc, uid, req)
	if err != nil {
		e.t.Fatalf("ListConversations: %v", err)
	}
	return resp, c
}

// codeOf is the Connect code the handler boundary would answer for err; 0 for nil.
func codeOf(err error) connect.Code {
	if err == nil {
		return 0
	}
	return apierr.ToConnect(err).Code()
}

func respIDs(r *messagingv1.ListConversationsResponse) []string {
	out := make([]string, 0, len(r.GetConversations()))
	for _, c := range r.GetConversations() {
		out = append(out, c.GetId())
	}
	return out
}

func (e *itEnv) listProfileCalls() int {
	e.profs.mu.Lock()
	defer e.profs.mu.Unlock()
	return e.profs.calls
}

// Given 25 conversations, pages of 20 + 5, newest activity first. Budget (ADR-0027 table): first INBOX page 23 reads
// (interceptor, query 20, caller graph, requests count()), a later page 22 at most, 0 writes.
func TestList_PagesNewestFirstWithinBudget(t *testing.T) {
	e := newIT(t, nil)
	svc := e.listSvc()
	want := make([]string, 0, 25)
	for i := range 25 {
		peer := fmt.Sprintf("peer-%02d", i)
		want = append([]string{ConversationID(alice, peer)}, want...) // newest first
		e.seedConversation(alice, peer, stateAccepted, base.Add(time.Duration(i)*time.Minute), [2]string{peer, "hi " + peer})
	}
	for i := range 3 { // three requests to alice: the count() on the first page
		e.seedConversation(fmt.Sprintf("req-%d", i), alice, stateRequest, base.Add(time.Duration(i)*time.Minute), [2]string{fmt.Sprintf("req-%d", i), "hello"})
	}

	first, c := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	budgettest.Assert(t, "ListConversations first INBOX page of 20", c, budgettest.Budget{Reads: 23})
	if c.Reads() != 23 || c.Writes() != 0 || c.Deletes() != 0 {
		t.Errorf("first page reads/writes/deletes = %d/%d/%d, want 23/0/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if len(first.Conversations) != 20 || first.NextPageToken == "" || first.SinceToken == "" || first.RequestCount != 3 {
		t.Fatalf("first page: %d conversations next=%q since=%q request_count=%d", len(first.Conversations), first.NextPageToken, first.SinceToken, first.RequestCount)
	}
	second, c2 := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: first.NextPageToken})
	budgettest.Assert(t, "ListConversations older INBOX page", c2, budgettest.Budget{Reads: 22})
	if c2.Reads() != 7 { // interceptor 1 + query 5 + graph 1
		t.Errorf("older page of 5 reads = %d, want 7", c2.Reads())
	}
	if len(second.Conversations) != 5 || second.NextPageToken != "" || second.RequestCount != 0 || second.SinceToken != "" {
		t.Fatalf("second page: %d conversations next=%q request_count=%d since=%q", len(second.Conversations), second.NextPageToken, second.RequestCount, second.SinceToken)
	}
	got := append(respIDs(first), respIDs(second)...)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order[%d] = %s, want %s (newest activity first)", i, got[i], want[i])
		}
	}
	p := first.Conversations[0]
	if p.Peer.UserId != "peer-24" || p.Peer.Handle != "h-peer-24" || p.LastMessage.Snippet != "hi peer-24" || p.LastMessage.FromSelf || !p.CanReply {
		t.Errorf("first conversation = %+v", p)
	}

	// REQUESTS: the same rules without the count().
	reqs, c3 := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests})
	budgettest.Assert(t, "ListConversations REQUESTS", c3, budgettest.Budget{Reads: 22})
	if len(reqs.Conversations) != 3 || reqs.RequestCount != 0 || c3.Reads() != 5 {
		t.Errorf("REQUESTS: %d conversations request_count=%d reads=%d, want 3 / 0 / 5", len(reqs.Conversations), reqs.RequestCount, c3.Reads())
	}
}

// Given a since token and one new message, then that entry returns. The token trails the newest entry by the 5 s settle
// window, so the previous newest comes back once as well when the new message lands in another conversation (the client
// dedupes by id): 4 reads when the new message is in the newest conversation, 5 when it is in another one (W7-37: the
// requests count() rides every INBOX since refresh).
func TestList_SinceReturnsTheMovedEntry(t *testing.T) {
	e := newIT(t, nil)
	e.addUser(carol, "carol", false)
	e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true, carol: true}})
	e.setSocial(bob, graph.Snapshot{Following: map[string]bool{alice: true}})
	e.setSocial(carol, graph.Snapshot{Following: map[string]bool{alice: true}})
	svc := e.listSvc()
	e.must(bob, toUser(skey(1), alice, "first from bob"))
	e.tick(time.Minute)
	e.must(carol, toUser(skey(2), alice, "first from carol"))
	bobConv, carolConv := ConversationID(alice, bob), ConversationID(alice, carol)

	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if got := respIDs(first); len(got) != 2 || got[0] != carolConv || got[1] != bobConv {
		t.Fatalf("first page = %v", got)
	}

	// W7-37: a request that arrives after the first page is counted by the refresh.
	e.seedConversation("req-late", alice, stateRequest, base, [2]string{"req-late", "hello"})

	// Nothing new: the entry the token trails (carol) is the one row read.
	quiet, cq := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	budgettest.Assert(t, "ListConversations since, nothing new", cq, budgettest.Budget{Reads: 4})
	if quiet.RequestCount != 1 {
		t.Errorf("since refresh request_count = %d, want 1 (the request created after the first page)", quiet.RequestCount)
	}
	if got := respIDs(quiet); len(got) != 1 || got[0] != carolConv {
		t.Fatalf("quiet refresh = %v, want only the settle-window entry", got)
	}

	// One new message in the newest conversation: exactly that entry.
	e.tick(time.Minute)
	e.must(carol, toUser(skey(3), alice, "carol again"))
	ref, c := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	budgettest.Assert(t, "ListConversations since", c, budgettest.Budget{Reads: 4})
	if c.Reads() != 4 || c.Writes() != 0 {
		t.Errorf("since reads/writes = %d/%d, want 4/0", c.Reads(), c.Writes())
	}
	if got := respIDs(ref); len(got) != 1 || got[0] != carolConv {
		t.Fatalf("refresh = %v, want exactly the entry that moved", got)
	}
	if cv := ref.Conversations[0]; cv.LastMessage.Snippet != "carol again" || cv.UnreadCount != 2 || ref.RequestCount != 1 || ref.NextPageToken != "" {
		t.Errorf("moved entry = %+v request_count=%d next=%q", cv, ref.RequestCount, ref.NextPageToken)
	}

	// A new message in the other conversation: that entry plus the settle-window one.
	e.tick(time.Minute)
	e.must(bob, toUser(skey(4), alice, "bob again"))
	other, c4 := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: ref.SinceToken})
	if got := respIDs(other); len(got) != 2 || got[0] != bobConv || got[1] != carolConv {
		t.Fatalf("refresh = %v, want bob's entry then carol's (settle window)", got)
	}
	budgettest.Assert(t, "ListConversations since, 2 rows", c4, budgettest.Budget{Reads: 5})
}

// Given a request from a blocked (or muted, or blocking) account, then it is absent from REQUESTS, the INBOX is not
// touched, and both tokens still advance (a hidden newest entry gives an empty page with a next_page_token).
func TestList_RequestsHideBlockedMutedBlockingPeers(t *testing.T) {
	tests := []struct {
		name string
		snap graph.Snapshot
	}{
		{"caller blocks", graph.Snapshot{Blocked: map[string]bool{carol: true}}},
		{"caller mutes", graph.Snapshot{Muted: map[string]bool{carol: true}}},
		{"peer blocks the caller", graph.Snapshot{BlockedBy: map[string]bool{carol: true}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.addUser(carol, "carol", false)
			svc := e.listSvc()
			e.must(bob, toUser(skey(1), alice, "from bob"))
			e.tick(time.Minute)
			e.must(carol, toUser(skey(2), alice, "from carol")) // the newest request
			bobConv, carolConv := ConversationID(alice, bob), ConversationID(alice, carol)
			e.setSocial(alice, tt.snap)

			page1, c := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests, PageSize: 1})
			if len(page1.Conversations) != 0 {
				t.Fatalf("hidden request shown: %v", respIDs(page1))
			}
			if page1.NextPageToken == "" || page1.SinceToken == "" {
				t.Fatalf("a short page must still carry next_page_token and since_token: %+v", page1)
			}
			budgettest.Assert(t, "REQUESTS page of 1", c, budgettest.Budget{Reads: 3})
			page2, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests, PageSize: 1, PageToken: page1.NextPageToken})
			if got := respIDs(page2); len(got) != 1 || got[0] != bobConv {
				t.Fatalf("page 2 = %v, want bob's request", got)
			}
			// The since token advanced past the hidden entry: a refresh shows only what is new and visible.
			e.tick(time.Minute)
			e.must(bob, toUser(skey(3), alice, "bob again"))
			ref, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests, SinceToken: page1.SinceToken})
			for _, id := range respIDs(ref) {
				if id == carolConv {
					t.Fatalf("hidden request returned by the refresh: %v", respIDs(ref))
				}
			}
			if len(ref.Conversations) == 0 || ref.Conversations[0].Id != bobConv {
				t.Fatalf("refresh = %v, want bob's request", respIDs(ref))
			}
		})
	}
}

// INBOX keeps every entry: a block either way makes it read-only (can_reply false), a mute keeps it replyable and
// shows the entry's silent marker.
func TestList_InboxKeepsBlockedWithoutReply(t *testing.T) {
	e := newIT(t, nil)
	e.addUser(carol, "carol", false)
	e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true, carol: true}, Muted: map[string]bool{carol: true}})
	e.setSocial(bob, graph.Snapshot{Following: map[string]bool{alice: true}})
	e.setSocial(carol, graph.Snapshot{Following: map[string]bool{alice: true}})
	svc := e.listSvc()
	e.must(bob, toUser(skey(1), alice, "from bob"))
	e.tick(time.Minute)
	e.must(alice, toUser(skey(2), carol, "to carol")) // alice muted carol: the flag lands on alice's entry
	byID := func(r *messagingv1.ListConversationsResponse) map[string]*messagingv1.Conversation {
		m := map[string]*messagingv1.Conversation{}
		for _, c := range r.Conversations {
			m[c.Id] = c
		}
		return m
	}
	bobConv, carolConv := ConversationID(alice, bob), ConversationID(alice, carol)

	resp, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	m := byID(resp)
	if len(m) != 2 || !m[bobConv].CanReply || !m[carolConv].CanReply || !m[carolConv].Silent || m[bobConv].Silent {
		t.Fatalf("plain: %+v", m)
	}

	for name, snap := range map[string]graph.Snapshot{
		"caller blocks bob":     {Blocked: map[string]bool{bob: true}, Muted: map[string]bool{carol: true}},
		"bob blocks the caller": {BlockedBy: map[string]bool{bob: true}, Muted: map[string]bool{carol: true}},
	} {
		e.setSocial(alice, snap)
		resp, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		m := byID(resp)
		if len(m) != 2 {
			t.Fatalf("%s: INBOX shows %d entries, want both", name, len(m))
		}
		if m[bobConv].CanReply || !m[carolConv].CanReply {
			t.Errorf("%s: can_reply bob=%v carol=%v, want false / true", name, m[bobConv].CanReply, m[carolConv].CanReply)
		}
	}
}

// Given a foreign or tampered token, then VALIDATION with 0 reads (the counter is not pre-charged here).
func TestList_ForeignOrTamperedTokenCostsNothing(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	svc := e.listSvc()
	for i := range 3 {
		e.tick(time.Minute)
		e.must(bob, toUser(skey(i), alice, "m"))
	}
	e.seedConversation(alice, "peer-a", stateAccepted, base, [2]string{"peer-a", "x"})
	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageSize: 1})
	if first.NextPageToken == "" {
		t.Fatal("no next page token")
	}
	flip := func(s string) string { b := []byte(s); b[len(b)/2] ^= 1; return string(b) }
	cases := []struct {
		name string
		uid  string
		req  *messagingv1.ListConversationsRequest
	}{
		{"another user's page token", bob, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: first.NextPageToken}},
		{"another user's since token", bob, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken}},
		{"another folder", alice, &messagingv1.ListConversationsRequest{Folder: requests, PageToken: first.NextPageToken}},
		{"tampered page token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: flip(first.NextPageToken)}},
		{"tampered since token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: flip(first.SinceToken)}},
		{"both tokens", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: first.NextPageToken, SinceToken: first.SinceToken}},
		{"no folder", alice, &messagingv1.ListConversationsRequest{}},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			ctx, c := budget.WithCounter(context.Background())
			_, err := svc.ListConversations(ctx, tt.uid, tt.req)
			if codeOf(err) != connect.CodeInvalidArgument {
				t.Fatalf("err = %v, want INVALID_ARGUMENT", err)
			}
			budgettest.Assert(t, tt.name, c, budgettest.Budget{})
			if c.Reads() != 0 {
				t.Errorf("reads = %d, want 0", c.Reads())
			}
		})
	}
	// An expired token (31 days on) is the same VALIDATION.
	e.tick(31 * 24 * time.Hour)
	ctx, c := budget.WithCounter(context.Background())
	_, err := svc.ListConversations(ctx, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if codeOf(err) != connect.CodeInvalidArgument || c.Reads() != 0 {
		t.Errorf("expired since token: err = %v reads = %d", err, c.Reads())
	}
}

// Given messaging allowlist-off for the caller (not globally off), the list still works; SendMessage does not.
func TestList_WorksForACallerOutsideTheAllowlist(t *testing.T) {
	e := newIT(t, func(e *itEnv) {
		e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{bob: {}}})
	})
	e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "hello"})
	svc := e.listSvc()
	resp, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(resp.Conversations) != 1 {
		t.Fatalf("listed %d, want 1", len(resp.Conversations))
	}
	if _, _, err := e.sendOn(svc, alice, toUser(skey(1), bob, "x")); err == nil {
		t.Fatal("SendMessage must still need the flag for the caller")
	}
	off := newIT(t, func(e *itEnv) { e.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}) })
	_, c, err := off.list(off.listSvc(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if err == nil || c.Reads() != 1 { // only the pre-charged interceptor read
		t.Fatalf("globally off: err = %v reads = %d, want FEATURE_DISABLED and 0 Firestore reads", err, c.Reads())
	}
}

// Given a peer that deleted the account (the real eraser ran), the entry reads "Deleted account" in both folders, can
// not be replied to, and the directory is never asked about it.
func TestList_ErasedPeerIsDeletedAccount(t *testing.T) {
	e := newIT(t, nil)
	e.addUser(carol, "carol", false)
	e.mutual(alice, bob)
	e.setSocial(alice, graph.Snapshot{Following: map[string]bool{bob: true}})
	svc := e.listSvc()
	e.must(bob, toUser(skey(1), alice, "from bob, accepted"))
	e.tick(time.Minute)
	e.must(carol, toUser(skey(2), alice, "from carol, a request"))
	e.runEraserFor(bob)
	e.runEraserFor(carol)

	before := e.listProfileCalls()
	for _, f := range []messagingv1.Folder{inbox, requests} {
		resp, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: f})
		if len(resp.Conversations) != 1 {
			t.Fatalf("%v: %d conversations, want the erased peer's one", f, len(resp.Conversations))
		}
		c := resp.Conversations[0]
		if c.Peer.DisplayName != DeletedAccountName || c.Peer.UserId != "" || c.Peer.Handle != "" || c.Peer.AvatarUrl != "" || c.CanReply {
			t.Errorf("%v: peer = %+v can_reply = %v", f, c.Peer, c.CanReply)
		}
		if c.LastMessage.State != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT || c.LastMessage.Snippet != "" {
			t.Errorf("%v: last = %+v", f, c.LastMessage)
		}
	}
	if e.listProfileCalls() != before {
		t.Errorf("the directory was called during the list; an erased peer is never looked up")
	}
	for _, h := range e.uidHits(bob) {
		t.Errorf("bob's uid remains: %s", h)
	}
}

// W7-37: an EMPTY INBOX since refresh (no row, so no graph read) still carries the current request_count: 3 reads
// (interceptor, query min 1, count()), and an older page or REQUESTS never carries it.
func TestList_EmptySinceRefreshCarriesRequestCount(t *testing.T) {
	e := newIT(t, nil)
	svc := e.listSvc()
	first, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if first.RequestCount != 0 || first.SinceToken == "" {
		t.Fatalf("first page: request_count=%d since=%q", first.RequestCount, first.SinceToken)
	}
	now := e.tick(time.Minute)
	e.seedConversation("req-0", alice, stateRequest, now, [2]string{"req-0", "hello"})
	e.seedConversation("req-1", alice, stateRequest, now, [2]string{"req-1", "hello"})
	ref, c := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	budgettest.Assert(t, "ListConversations empty INBOX since", c, budgettest.Budget{Reads: 3})
	if len(ref.Conversations) != 0 || ref.RequestCount != 2 {
		t.Errorf("empty refresh: rows=%d request_count=%d, want 0 and 2", len(ref.Conversations), ref.RequestCount)
	}
	reqs, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests})
	rsince, _ := e.mustList(svc, alice, &messagingv1.ListConversationsRequest{Folder: requests, SinceToken: reqs.SinceToken})
	if reqs.RequestCount != 0 || rsince.RequestCount != 0 {
		t.Errorf("REQUESTS request_count = %d / %d, want 0", reqs.RequestCount, rsince.RequestCount)
	}
}
