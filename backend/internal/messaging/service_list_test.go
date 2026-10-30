package messaging

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/notifications"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const (
	inbox    = messagingv1.Folder_FOLDER_INBOX
	requests = messagingv1.Folder_FOLDER_REQUESTS
)

// entryAt builds an entry whose peer is peerID, active n x 10 seconds (wider than the 5 s settle window) after the rig's base time.
func (r *rig) entryAt(peerID string, n int) EntryRow {
	at := r.now.Add(-time.Hour).Add(time.Duration(n) * 10 * time.Second)
	return EntryRow{ID: ConversationID(alice, peerID), EntryDoc: EntryDoc{
		PeerID: peerID, Peer: PeerDoc{Handle: "h-" + peerID, DisplayName: "Name " + peerID, AvatarThumbURL: "https://img/" + peerID, Verified: true},
		LastMessageAt: at, ChangedAt: at, Last: LastDoc{MessageID: "m", Snippet: "hello " + peerID, State: msgVisible}, UnreadCount: 2,
	}}
}

func (r *rig) put(uid, folder string, rows ...EntryRow) {
	if r.repo.entries == nil {
		r.repo.entries = map[string][]EntryRow{}
	}
	k := entryKey(uid, folder)
	r.repo.entries[k] = append(r.repo.entries[k], rows...)
}

func (r *rig) list(t *testing.T, uid string, req *messagingv1.ListConversationsRequest) *messagingv1.ListConversationsResponse {
	t.Helper()
	resp, err := r.svc.ListConversations(context.Background(), uid, req)
	if err != nil {
		t.Fatalf("ListConversations: %v", err)
	}
	return resp
}

func convIDs(resp *messagingv1.ListConversationsResponse) []string {
	out := make([]string, 0, len(resp.GetConversations()))
	for _, c := range resp.GetConversations() {
		out = append(out, c.GetId())
	}
	return out
}

func wantField(t *testing.T, err error, field string) {
	t.Helper()
	code, reason, meta := reasonOf(t, err)
	if code != connect.CodeInvalidArgument || reason != commonv1.ErrorReason_ERROR_REASON_VALIDATION || meta["field"] != field {
		t.Fatalf("err = %v (code %v reason %v meta %v), want VALIDATION field=%s", err, code, reason, meta, field)
	}
}

func TestListConversations_Validation(t *testing.T) {
	rg := newRig(t, nil)
	tok := func(binding string, at time.Time) string {
		return cursor.EncodeAt(testCursorKey, binding, cursor.Cursor{CreatedAt: rg.now, DocID: "x"}, at)
	}
	tests := []struct {
		name  string
		uid   string
		req   *messagingv1.ListConversationsRequest
		field string
	}{
		{"folder unspecified", alice, &messagingv1.ListConversationsRequest{}, "folder"},
		{"folder out of range", alice, &messagingv1.ListConversationsRequest{Folder: 9}, "folder"},
		{"both tokens", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: "a", SinceToken: "b"}, "page_token"},
		{"garbage page token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: "nope"}, "page_token"},
		{"garbage since token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: "nope"}, "since_token"},
		{"page token of another user", bob, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: tok(pageBinding(alice, dmInboxCollection), rg.now)}, "page_token"},
		{"since token of another user", bob, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: tok(sinceBinding(alice, dmInboxCollection), rg.now)}, "since_token"},
		{"page token of another folder", alice, &messagingv1.ListConversationsRequest{Folder: requests, PageToken: tok(pageBinding(alice, dmInboxCollection), rg.now)}, "page_token"},
		{"since token of another folder", alice, &messagingv1.ListConversationsRequest{Folder: requests, SinceToken: tok(sinceBinding(alice, dmInboxCollection), rg.now)}, "since_token"},
		{"since token used as page token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: tok(sinceBinding(alice, dmInboxCollection), rg.now)}, "page_token"},
		{"page token used as since token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: tok(pageBinding(alice, dmInboxCollection), rg.now)}, "since_token"},
		{"expired since token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: tok(sinceBinding(alice, dmInboxCollection), rg.now.Add(-31*24*time.Hour))}, "since_token"},
		{"expired page token", alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: tok(pageBinding(alice, dmInboxCollection), rg.now.Add(-31*24*time.Hour))}, "page_token"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := rg.svc.ListConversations(context.Background(), tt.uid, tt.req)
			wantField(t, err, tt.field)
			if rg.repo.lists+rg.repo.counts != 0 || rg.social.calls != 0 {
				t.Fatalf("reads: lists=%d counts=%d graph=%d, want 0 (validation before any read)", rg.repo.lists, rg.repo.counts, rg.social.calls)
			}
		})
	}
	t.Run("a 29 day old token still opens", func(t *testing.T) {
		old := tok(sinceBinding(alice, dmInboxCollection), rg.now.Add(-29*24*time.Hour))
		if _, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: old}); err != nil {
			t.Fatalf("err = %v", err)
		}
	})
}

func TestListConversations_PagesAndSince(t *testing.T) {
	rg := newRig(t, nil)
	for i := range 25 {
		rg.put(alice, dmInboxCollection, rg.entryAt(fmt.Sprintf("peer-%02d", i), i))
	}
	first := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(first.Conversations) != 20 || first.NextPageToken == "" || first.SinceToken == "" {
		t.Fatalf("first page: %d conversations next=%q since=%q", len(first.Conversations), first.NextPageToken, first.SinceToken)
	}
	// Newest activity first.
	for i, c := range first.Conversations {
		if want := ConversationID(alice, fmt.Sprintf("peer-%02d", 24-i)); c.Id != want {
			t.Fatalf("first[%d] = %s, want %s", i, c.Id, want)
		}
	}
	if first.RequestCount != 0 {
		t.Errorf("request_count = %d, want 0 with no requests", first.RequestCount)
	}
	second := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageToken: first.NextPageToken})
	if len(second.Conversations) != 5 || second.NextPageToken != "" {
		t.Fatalf("second page: %d conversations next=%q", len(second.Conversations), second.NextPageToken)
	}
	if second.SinceToken != "" {
		t.Errorf("an older page must not replace the client's since_token, got %q", second.SinceToken)
	}
	seen := map[string]bool{}
	for _, id := range append(convIDs(first), convIDs(second)...) {
		if seen[id] {
			t.Fatalf("duplicate %s across pages", id)
		}
		seen[id] = true
	}
	if len(seen) != 25 {
		t.Fatalf("pages cover %d conversations, want 25", len(seen))
	}

	// One entry moves up (a new message): a refresh returns exactly it.
	moved := rg.repo.entries[entryKey(alice, dmInboxCollection)][3]
	moved.LastMessageAt, moved.ChangedAt = rg.now, rg.now
	moved.Last.Snippet = "newer"
	rg.repo.entries[entryKey(alice, dmInboxCollection)][3] = moved
	rg.repo.queries = nil
	ref := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	// A first page's since_token is "now - settle" (its rows are ordered by lastMessageAt and bound nothing below them), so
	// a refresh returns exactly the entry that changed after it, not the old newest.
	if got := convIDs(ref); len(got) != 1 || got[0] != moved.ID {
		t.Fatalf("refresh = %v, want only the moved entry", got)
	}
	if ref.NextPageToken != "" || ref.SinceToken == "" || ref.RequestCount != 0 || rg.repo.counts != 2 {
		t.Errorf("refresh: next=%q since=%q request_count=%d counts=%d", ref.NextPageToken, ref.SinceToken, ref.RequestCount, rg.repo.counts)
	}
	if ref.Conversations[0].LastMessage.Snippet != "newer" {
		t.Errorf("snippet = %q", ref.Conversations[0].LastMessage.Snippet)
	}
	// The new token trails the moved entry by 5 s: the entry comes back once more (the client dedupes by id).
	again := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: ref.SinceToken})
	if got := convIDs(again); len(got) != 1 || got[0] != moved.ID {
		t.Fatalf("settle window: refresh = %v, want %s once more", got, moved.ID)
	}
	rg.now = rg.now.Add(time.Minute)
	empty := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if len(empty.Conversations) != 1 {
		t.Fatalf("old token still returns the moved entry, got %v", convIDs(empty))
	}
}

func TestListConversations_EmptyThenRefresh(t *testing.T) {
	rg := newRig(t, nil)
	first := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	if len(first.Conversations) != 0 || first.NextPageToken != "" || first.SinceToken == "" {
		t.Fatalf("empty first page: %+v", first)
	}
	if rg.social.calls != 0 {
		t.Errorf("graph read %d times for an empty page, want 0", rg.social.calls)
	}
	rg.now = rg.now.Add(time.Second)
	rg.put(alice, dmInboxCollection, rg.entryAt("peer-x", 360)) // at rg.now
	ref := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if len(ref.Conversations) != 1 {
		t.Fatalf("refresh after an empty open = %d, want 1", len(ref.Conversations))
	}
	// An empty refresh keeps the position of the old token.
	rg.repo.entries = nil
	keep := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: ref.SinceToken})
	if len(keep.Conversations) != 0 || keep.SinceToken == "" {
		t.Fatalf("empty refresh: %+v", keep)
	}
	c, err := cursor.DecodeAtTTL(testCursorKey, sinceBinding(alice, dmInboxCollection), keep.SinceToken, rg.now, RefreshTokenTTL)
	prev, _ := cursor.DecodeAtTTL(testCursorKey, sinceBinding(alice, dmInboxCollection), ref.SinceToken, rg.now, RefreshTokenTTL)
	if err != nil || c != prev {
		t.Errorf("position moved on an empty refresh: %v vs %v (%v)", c, prev, err)
	}
}

func TestListConversations_RequestsReadTimeRules(t *testing.T) {
	tests := []struct {
		name   string
		snap   graph.Snapshot
		hidden bool
		cause  string
	}{
		{"plain", graph.Snapshot{}, false, ""},
		{"caller blocks the peer", graph.Snapshot{Blocked: map[string]bool{"p": true}}, true, causeBlocked},
		{"caller mutes the peer", graph.Snapshot{Muted: map[string]bool{"p": true}}, true, causeMuted},
		{"peer blocks the caller", graph.Snapshot{BlockedBy: map[string]bool{"p": true}}, true, causeBlockedBy},
		{"blocks another account", graph.Snapshot{Blocked: map[string]bool{"q": true}}, false, ""},
		{"follows the peer", graph.Snapshot{Following: map[string]bool{"p": true}}, false, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, nil)
			rg.social.snaps[alice] = tt.snap
			rg.put(alice, dmRequestsCollection, rg.entryAt("p", 1), rg.entryAt("other", 0))
			resp := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests})
			want := 2
			if tt.hidden {
				want = 1
			}
			if len(resp.Conversations) != want {
				t.Fatalf("shown = %d, want %d", len(resp.Conversations), want)
			}
			if tt.hidden && resp.Conversations[0].Id != ConversationID(alice, "other") {
				t.Errorf("the wrong entry was hidden: %v", convIDs(resp))
			}
			for _, c := range resp.Conversations {
				if c.Folder != requests || c.State != messagingv1.ConversationState_CONVERSATION_STATE_REQUEST || !c.CanReply {
					t.Errorf("request entry mapped wrongly: folder=%v state=%v can_reply=%v", c.Folder, c.State, c.CanReply)
				}
			}
			if resp.RequestCount != 0 {
				t.Errorf("request_count = %d on REQUESTS, want 0", resp.RequestCount)
			}
			if rg.repo.counts != 0 {
				t.Errorf("count() ran on REQUESTS")
			}
		})
	}
}

func TestListConversations_HiddenEntriesStillAdvanceTokens(t *testing.T) {
	rg := newRig(t, nil)
	rg.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{"p0": true, "p1": true}}
	rg.put(alice, dmRequestsCollection, rg.entryAt("p0", 1), rg.entryAt("p1", 2))
	resp := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests, PageSize: 2})
	if len(resp.Conversations) != 0 {
		t.Fatalf("shown = %d, want 0", len(resp.Conversations))
	}
	if resp.NextPageToken == "" || resp.SinceToken == "" {
		t.Fatalf("a short page must keep next_page_token (follows the query) and since_token: %+v", resp)
	}
	older := rg.entryAt("p2", 0)
	rg.put(alice, dmRequestsCollection, older)
	next := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests, PageSize: 2, PageToken: resp.NextPageToken})
	if got := convIDs(next); len(got) != 1 || got[0] != older.ID {
		t.Fatalf("next page = %v, want the older entry", got)
	}
	// The since token was computed from the scanned rows: a new entry is returned, the hidden ones are not re-scanned
	// beyond the settle window.
	rg.now = rg.now.Add(time.Hour)
	fresh := rg.entryAt("p3", 720)
	rg.put(alice, dmRequestsCollection, fresh)
	ref := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests, SinceToken: resp.SinceToken})
	if got := convIDs(ref); len(got) != 1 || got[0] != fresh.ID {
		t.Fatalf("refresh = %v, want %s only", got, fresh.ID)
	}
}

func TestListConversations_InboxKeepsEverything(t *testing.T) {
	tests := []struct {
		name         string
		peer         string
		snap         graph.Snapshot
		wantCanReply bool
	}{
		{"plain", "p", graph.Snapshot{}, true},
		{"caller blocks", "p", graph.Snapshot{Blocked: map[string]bool{"p": true}}, false},
		{"peer blocks the caller", "p", graph.Snapshot{BlockedBy: map[string]bool{"p": true}}, false},
		{"both block", "p", graph.Snapshot{Blocked: map[string]bool{"p": true}, BlockedBy: map[string]bool{"p": true}}, false},
		{"caller mutes", "p", graph.Snapshot{Muted: map[string]bool{"p": true}}, true},
		{"erased peer", DeletedUID, graph.Snapshot{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, nil)
			rg.social.snaps[alice] = tt.snap
			e := rg.entryAt(tt.peer, 1)
			e.Silent = tt.snap.Muted[tt.peer]
			rg.put(alice, dmInboxCollection, e)
			resp := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
			if len(resp.Conversations) != 1 {
				t.Fatalf("shown = %d, want 1 (INBOX keeps every entry)", len(resp.Conversations))
			}
			c := resp.Conversations[0]
			if c.CanReply != tt.wantCanReply {
				t.Errorf("can_reply = %v, want %v", c.CanReply, tt.wantCanReply)
			}
			if c.Silent != e.Silent {
				t.Errorf("silent = %v, want the entry's %v", c.Silent, e.Silent)
			}
			if c.Folder != inbox || c.State != messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED || c.Kind != messagingv1.ConversationKind_CONVERSATION_KIND_DIRECT {
				t.Errorf("mapping: folder=%v state=%v kind=%v", c.Folder, c.State, c.Kind)
			}
			if c.UnreadCount != 2 || !c.UpdatedAt.AsTime().Equal(e.LastMessageAt) || !c.LastMessage.CreatedAt.AsTime().Equal(e.LastMessageAt) {
				t.Errorf("unread=%d updated_at=%v last.created_at=%v", c.UnreadCount, c.UpdatedAt.AsTime(), c.LastMessage.CreatedAt.AsTime())
			}
		})
	}
}

func TestListConversations_DeletedAccountPeer(t *testing.T) {
	rg := newRig(t, nil)
	e := rg.entryAt(DeletedUID, 1)
	// Even a stale or hand-edited peer copy is replaced: DeletedUID is never shown as an account.
	e.Peer = PeerDoc{Handle: "ghost", DisplayName: "Ghost", AvatarThumbURL: "https://img/ghost", Verified: true}
	e.Last = LastDoc{MessageID: "m", Snippet: deletedSnippet, State: msgDeletedAccount}
	rg.put(alice, dmInboxCollection, e)
	rg.put(alice, dmRequestsCollection, e)
	for _, f := range []messagingv1.Folder{inbox, requests} {
		c := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: f}).Conversations[0]
		p := c.Peer
		if p.DisplayName != DeletedAccountName || p.UserId != "" || p.Handle != "" || p.AvatarUrl != "" || p.Verified {
			t.Errorf("%v peer = %+v, want only the Deleted account name", f, p)
		}
		if c.CanReply {
			t.Errorf("%v can_reply = true for an erased peer", f)
		}
		if c.LastMessage.State != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT || c.LastMessage.Snippet != "" {
			t.Errorf("%v last = %+v, want an empty-snippet tombstone", f, c.LastMessage)
		}
	}
	if rg.profs.calls != 0 {
		t.Errorf("the directory was called %d times; an erased peer is never looked up", rg.profs.calls)
	}
}

func TestListConversations_PeerSnapshotAndTombstones(t *testing.T) {
	rg := newRig(t, nil)
	rg.put(alice, dmInboxCollection, rg.entryAt("p", 1))
	rg.put(alice, dmInboxCollection, func() EntryRow {
		e := rg.entryAt("q", 2)
		e.Last = LastDoc{MessageID: "m", FromSelf: true, Snippet: "taken down text", State: msgRemoved}
		return e
	}())
	got := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox}).Conversations
	removed, live := got[0], got[1]
	if removed.LastMessage.State != messagingv1.MessageState_MESSAGE_STATE_REMOVED || removed.LastMessage.Snippet != "" || !removed.LastMessage.FromSelf {
		t.Errorf("removed preview = %+v", removed.LastMessage)
	}
	p := live.Peer
	if p.UserId != "p" || p.Handle != "h-p" || p.DisplayName != "Name p" || p.AvatarUrl != "https://img/p" || !p.Verified {
		t.Errorf("peer = %+v", p)
	}
	if live.LastMessage.Snippet != "hello p" || live.LastMessage.State != messagingv1.MessageState_MESSAGE_STATE_VISIBLE {
		t.Errorf("preview = %+v", live.LastMessage)
	}
	if rg.profs.calls != 0 {
		t.Errorf("directory calls = %d, want 0 (the entry holds the snapshot)", rg.profs.calls)
	}
}

func TestListConversations_RequestCountOnFirstPageAndSinceRefresh(t *testing.T) {
	rg := newRig(t, nil)
	for i := range 3 {
		rg.put(alice, dmRequestsCollection, rg.entryAt(fmt.Sprintf("r%d", i), i))
	}
	for i := range 3 {
		rg.put(alice, dmInboxCollection, rg.entryAt(fmt.Sprintf("i%d", i), i))
	}
	first := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageSize: 2})
	if first.RequestCount != 3 || rg.repo.counts != 1 {
		t.Fatalf("first INBOX page: request_count=%d counts=%d, want 3 and 1", first.RequestCount, rg.repo.counts)
	}
	older := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, PageSize: 2, PageToken: first.NextPageToken})
	req := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests})
	reqSince := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests, SinceToken: req.SinceToken})
	for name, r := range map[string]*messagingv1.ListConversationsResponse{"older page": older, "REQUESTS": req, "REQUESTS since": reqSince} {
		if r.RequestCount != 0 {
			t.Errorf("%s: request_count = %d, want 0", name, r.RequestCount)
		}
	}
	if rg.repo.counts != 1 {
		t.Errorf("count() ran %d times over four calls, want once", rg.repo.counts)
	}
	// W7-37: an INBOX since refresh carries the current count, a request created after the first page included, and an
	// empty refresh too.
	rg.put(alice, dmRequestsCollection, rg.entryAt("r-new", 9))
	refresh := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: first.SinceToken})
	if refresh.RequestCount != 4 || rg.repo.counts != 2 {
		t.Errorf("since refresh: request_count=%d counts=%d, want 4 and 2", refresh.RequestCount, rg.repo.counts)
	}
	rg.now = rg.now.Add(time.Hour)
	empty := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox, SinceToken: refresh.SinceToken, PageSize: 2})
	if len(empty.Conversations) != 0 || empty.RequestCount != 4 || rg.repo.counts != 3 {
		t.Errorf("empty since refresh: rows=%d request_count=%d counts=%d, want 0, 4, 3", len(empty.Conversations), empty.RequestCount, rg.repo.counts)
	}
	// An unrelated user has no requests.
	if got := rg.list(t, bob, &messagingv1.ListConversationsRequest{Folder: inbox}); got.RequestCount != 0 {
		t.Errorf("bob request_count = %d", got.RequestCount)
	}
}

func TestListConversations_PageSize(t *testing.T) {
	for _, tt := range []struct {
		in   int32
		want int
	}{{0, 20}, {-3, 20}, {7, 7}, {50, 50}, {51, 50}, {1000, 50}} {
		rg := newRig(t, nil)
		rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: requests, PageSize: tt.in})
		if got := rg.repo.queries[0].Limit; got != tt.want {
			t.Errorf("page_size %d: query limit %d, want %d", tt.in, got, tt.want)
		}
	}
}

func TestListConversations_OnlyTheCallersPath(t *testing.T) {
	rg := newRig(t, nil)
	rg.put(bob, dmInboxCollection, rg.entryAt("p", 1))
	if got := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox}); len(got.Conversations) != 0 {
		t.Fatalf("alice sees bob's entries: %v", convIDs(got))
	}
}

func TestListConversations_FlagClass(t *testing.T) {
	// A caller dropped from the allowlist still lists; only a globally off flag refuses, before any read.
	t.Run("allowlist, caller outside", func(t *testing.T) {
		rg := newRig(t, func(r *rig) {
			r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{bob: {}}})
		})
		rg.put(alice, dmInboxCollection, rg.entryAt("p", 1))
		if got := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox}); len(got.Conversations) != 1 {
			t.Fatalf("listed %d, want 1", len(got.Conversations))
		}
	})
	t.Run("percent 0", func(t *testing.T) {
		rg := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 0}) })
		rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
	})
	t.Run("globally off", func(t *testing.T) {
		rg := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Off}) })
		_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || ae.Metadata["feature"] != FlagName {
			t.Fatalf("err = %v, want FEATURE_DISABLED feature=messaging", err)
		}
		if rg.repo.lists != 0 {
			t.Errorf("repo read while globally off")
		}
	})
}

func TestListConversations_Errors(t *testing.T) {
	t.Run("repo error is redacted and not an apierr", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.repo.listErr = fmt.Errorf("rpc: users/%s/dmInbox failed", alice)
		_, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a plain internal error", err)
		}
		if got := err.Error(); containsAny(got, alice) {
			t.Errorf("error leaks the uid: %q", got)
		}
	})
	t.Run("count error fails a first page and a since refresh", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.put(alice, dmInboxCollection, rg.entryAt("p", 1))
		first := rg.list(t, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		rg.repo.countErr = errors.New("boom")
		for name, req := range map[string]*messagingv1.ListConversationsRequest{
			"first": {Folder: inbox}, "since": {Folder: inbox, SinceToken: first.SinceToken},
		} {
			if _, err := rg.svc.ListConversations(context.Background(), alice, req); err == nil {
				t.Errorf("%s: want an error, never a silent 0", name)
			}
		}
	})
	t.Run("graph error", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.put(alice, dmInboxCollection, rg.entryAt("p", 1))
		rg.social.err = errors.New("boom")
		if _, err := rg.svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox}); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("deadline", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.repo.listErr = context.DeadlineExceeded
		ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
		defer cancel()
		_, err := rg.svc.ListConversations(ctx, alice, &messagingv1.ListConversationsRequest{Folder: inbox})
		if code, _, _ := reasonOf(t, err); code != connect.CodeDeadlineExceeded {
			t.Fatalf("code = %v, want DeadlineExceeded", code)
		}
	})
	t.Run("not configured", func(t *testing.T) {
		rg := newRig(t, nil)
		svc := New(rg.reg, Deps{Repo: rg.repo, Social: rg.social})
		if _, err := svc.ListConversations(context.Background(), alice, &messagingv1.ListConversationsRequest{Folder: inbox}); err == nil {
			t.Fatal("want an error without a cursor key")
		}
	})
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
	}
	return false
}

// TestListConversations_TokenConstantsMatchNotifications pins the reused codec parameters (ADR-0027 D7): the same 5 s
// settle window and 30-day lifetime as the notifications list, so a change there is a decision here too.
func TestListConversations_TokenConstantsMatchNotifications(t *testing.T) {
	if SettleWindow != notifications.SettleWindow || RefreshTokenTTL != notifications.RefreshTokenTTL ||
		DefaultPageSize != notifications.DefaultPageSize || MaxPageSize != notifications.MaxPageSize {
		t.Fatal("messaging list parameters drifted from notifications")
	}
}
