package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var aliceBobConv = ConversationID(alice, bob)

// putThread stores the conversation and n messages (oldest first, 10 s apart, alternating sender alice, bob) in the rig.
func (r *rig) putThread(n int, mut func(*ConvDoc)) []MessageRow {
	conv := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted}
	if mut != nil {
		mut(&conv)
	}
	r.repo.convs[aliceBobConv] = conv
	if r.repo.msgs == nil {
		r.repo.msgs = map[string][]MessageRow{}
	}
	rows := make([]MessageRow, 0, n)
	for i := range n {
		sender := alice
		if i%2 == 1 {
			sender = bob
		}
		rows = append(rows, MessageRow{ID: fmt.Sprintf("%032x", i+1), MsgDoc: MsgDoc{
			SenderID: sender, Text: fmt.Sprintf("secret text %d", i), State: msgVisible,
			CreatedAt: r.now.Add(-time.Hour).Add(time.Duration(i) * 10 * time.Second),
		}})
	}
	r.repo.msgs[aliceBobConv] = rows
	return rows
}

func (r *rig) listMsgs(t *testing.T, uid string, req *messagingv1.ListMessagesRequest) *messagingv1.ListMessagesResponse {
	t.Helper()
	resp, err := r.svc.ListMessages(context.Background(), uid, req)
	if err != nil {
		t.Fatalf("ListMessages: %v", err)
	}
	return resp
}

func msgIDs(resp *messagingv1.ListMessagesResponse) []string {
	out := make([]string, 0, len(resp.GetMessages()))
	for _, m := range resp.GetMessages() {
		out = append(out, m.GetId())
	}
	return out
}

func TestListMessages_Validation(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(1, nil)
	win := func(binding string, at time.Time) string {
		return cursor.EncodeWindowAt(testCursorKey, binding, cursor.Window{Upper: cursor.Cursor{CreatedAt: rg.now, DocID: "x"}}, at)
	}
	tok := func(binding string, at time.Time) string {
		return cursor.EncodeAt(testCursorKey, binding, cursor.Cursor{CreatedAt: rg.now, DocID: "x"}, at)
	}
	other := ConversationID(alice, "uid-other")
	tests := []struct {
		name  string
		uid   string
		req   *messagingv1.ListMessagesRequest
		field string
	}{
		{"empty id", alice, &messagingv1.ListMessagesRequest{}, "conversation_id"},
		{"upper-case id", alice, &messagingv1.ListMessagesRequest{ConversationId: "ABCDEFABCDEFABCDEFABCDEFABCDEFAB"}, "conversation_id"},
		{"short id", alice, &messagingv1.ListMessagesRequest{ConversationId: "abc"}, "conversation_id"},
		{"both tokens", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: "a", SinceToken: "b"}, "page_token"},
		{"garbage page token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: "nope"}, "page_token"},
		{"garbage since token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: "nope"}, "since_token"},
		{"page token of another user", bob, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: win(messagesPageBinding(alice, aliceBobConv), rg.now)}, "page_token"},
		{"page token of another conversation", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: win(messagesPageBinding(alice, other), rg.now)}, "page_token"},
		{"since token of another conversation", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tok(messagesSinceBinding(alice, other), rg.now)}, "since_token"},
		{"since token used as page token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: tok(messagesSinceBinding(alice, aliceBobConv), rg.now)}, "page_token"},
		{"page token used as since token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: win(messagesPageBinding(alice, aliceBobConv), rg.now)}, "since_token"},
		{"conversations list token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tok(sinceBinding(alice, dmInboxCollection), rg.now)}, "since_token"},
		{"expired since token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: tok(messagesSinceBinding(alice, aliceBobConv), rg.now.Add(-31*24*time.Hour))}, "since_token"},
		{"expired page token", alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: win(messagesPageBinding(alice, aliceBobConv), rg.now.Add(-31*24*time.Hour))}, "page_token"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := rg.svc.ListMessages(context.Background(), tt.uid, tt.req)
			wantField(t, err, tt.field)
			if rg.repo.gets != 0 || len(rg.repo.msgQueries) != 0 || rg.social.calls != 0 || rg.profs.calls != 0 {
				t.Fatalf("reads: conv=%d query=%d graph=%d profiles=%d, want 0 (validation before any read)", rg.repo.gets, len(rg.repo.msgQueries), rg.social.calls, rg.profs.calls)
			}
		})
	}
}

// Given 45 messages, then pages of 20 / 20 / 5, newest first, no overlap; the conversation rides the first and older pages.
func TestListMessages_PagesNewestFirst(t *testing.T) {
	rg := newRig(t, nil)
	rows := rg.putThread(45, nil)
	want := make([]string, 0, 45)
	for i := len(rows) - 1; i >= 0; i-- {
		want = append(want, rows[i].ID)
	}
	var got []string
	token := ""
	for page, wantLen := range []int{20, 20, 5} {
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: token})
		if len(resp.Messages) != wantLen {
			t.Fatalf("page %d has %d messages, want %d", page, len(resp.Messages), wantLen)
		}
		if resp.Conversation == nil || resp.Conversation.Id != aliceBobConv {
			t.Fatalf("page %d conversation = %v, want set", page, resp.Conversation)
		}
		if (page == 0) != (resp.SinceToken != "") {
			t.Errorf("page %d since_token = %q (only the first page issues one)", page, resp.SinceToken)
		}
		if resp.GapPageToken != "" {
			t.Errorf("page %d gap_page_token = %q, want none", page, resp.GapPageToken)
		}
		if (page < 2) != (resp.NextPageToken != "") {
			t.Errorf("page %d next_page_token = %q", page, resp.NextPageToken)
		}
		got = append(got, msgIDs(resp)...)
		token = resp.NextPageToken
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order[%d] = %s, want %s", i, got[i], want[i])
		}
	}
}

func TestListMessages_PageSizeClamp(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(60, nil)
	for _, tt := range []struct {
		in   int32
		want int
	}{{0, 20}, {-3, 20}, {7, 7}, {50, 50}, {500, 50}} {
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageSize: tt.in})
		if len(resp.Messages) != tt.want {
			t.Errorf("page_size %d returned %d, want %d", tt.in, len(resp.Messages), tt.want)
		}
	}
}

// from_self is the only sender signal; a tombstone has an empty text and its state; an erased sender is never "self".
func TestListMessages_FromSelfAndTombstones(t *testing.T) {
	rg := newRig(t, nil)
	rows := rg.putThread(5, nil)
	rows[1].State, rows[1].Text = msgDeletedAccount, ""
	rows[1].SenderID = DeletedUID
	rows[2].State, rows[2].Text = msgRemoved, ""
	rows[3].State, rows[3].Text = "FUTURE_STATE", "must not leak"
	resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	byID := map[string]*messagingv1.Message{}
	for _, m := range resp.Messages {
		byID[m.Id] = m
		if m.ConversationId != aliceBobConv {
			t.Errorf("conversation_id = %q", m.ConversationId)
		}
	}
	tests := []struct {
		row      int
		fromSelf bool
		state    messagingv1.MessageState
		text     string
	}{
		{0, true, messagingv1.MessageState_MESSAGE_STATE_VISIBLE, "secret text 0"},
		{1, false, messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT, ""},
		{2, true, messagingv1.MessageState_MESSAGE_STATE_REMOVED, ""},
		{3, false, messagingv1.MessageState_MESSAGE_STATE_UNSPECIFIED, ""},
		{4, true, messagingv1.MessageState_MESSAGE_STATE_VISIBLE, "secret text 4"},
	}
	for _, tt := range tests {
		m := byID[rows[tt.row].ID]
		if m.FromSelf != tt.fromSelf || m.State != tt.state || m.Text != tt.text {
			t.Errorf("row %d = from_self %v state %v text %q, want %v %v %q", tt.row, m.FromSelf, m.State, m.Text, tt.fromSelf, tt.state, tt.text)
		}
	}
	// Bob sees the mirror image of the same rows.
	bobResp := rg.listMsgs(t, bob, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	for _, m := range bobResp.Messages {
		if m.Id == rows[0].ID && m.FromSelf {
			t.Error("bob sees alice's message as from_self")
		}
	}
}

func TestListMessages_ClearedAt(t *testing.T) {
	rg := newRig(t, nil)
	rows := rg.putThread(10, func(c *ConvDoc) {})
	// alice cleared the thread at the 6th message's time: messages 0..5 (createdAt <= clearedAt) are hidden for her only.
	cleared := rows[5].CreatedAt
	conv := rg.repo.convs[aliceBobConv]
	conv.ClearedAt = map[string]time.Time{alice: cleared}
	rg.repo.convs[aliceBobConv] = conv
	resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if len(resp.Messages) != 4 || resp.Messages[3].Id != rows[6].ID {
		t.Fatalf("alice sees %v, want the 4 messages after the clear", msgIDs(resp))
	}
	if resp.NextPageToken != "" {
		t.Errorf("next_page_token = %q, want none below the clear", resp.NextPageToken)
	}
	if got := len(rg.listMsgs(t, bob, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}).Messages); got != 10 {
		t.Errorf("bob sees %d messages, want all 10 (clearedAt is per user)", got)
	}
}

// A poll: the since token trails the newest message by the settle window, the response has no conversation and reads
// neither the peer profile nor the graph; an empty poll keeps the old position.
func TestListMessages_SincePoll(t *testing.T) {
	rg := newRig(t, nil)
	rows := rg.putThread(3, nil)
	first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	profCalls, graphCalls := rg.profs.calls, rg.social.calls
	if profCalls != 1 || graphCalls != 1 {
		t.Fatalf("first page profile/graph calls = %d/%d, want 1/1", profCalls, graphCalls)
	}

	// Nothing new: no conversation, no gap, 1 query. The newest message is inside the settle window of the token, so it
	// comes again (the client dedupes by id).
	resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken})
	if got := msgIDs(resp); len(got) != 1 || got[0] != rows[2].ID || resp.Conversation != nil || resp.GapPageToken != "" || resp.NextPageToken != "" || resp.SinceToken == "" {
		t.Fatalf("empty poll = %+v", resp)
	}
	if rg.profs.calls != profCalls || rg.social.calls != graphCalls {
		t.Errorf("a poll read the peer profile (%d) or the graph (%d)", rg.profs.calls-profCalls, rg.social.calls-graphCalls)
	}
	if rg.repo.gets != 1 {
		t.Errorf("conversation reads = %d, want 1 (the second call hits the 60 s cache)", rg.repo.gets)
	}

	// The settle window: a message committed up to 5 s behind the newest one is delivered again by the next poll.
	late := MessageRow{ID: fmt.Sprintf("%032x", 99), MsgDoc: MsgDoc{SenderID: bob, Text: "late", State: msgVisible, CreatedAt: rows[2].CreatedAt.Add(2 * time.Second)}}
	rg.repo.msgs[aliceBobConv] = append(rg.repo.msgs[aliceBobConv], late)
	resp2 := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken})
	if got := msgIDs(resp2); len(got) != 2 || got[0] != late.ID || got[1] != rows[2].ID {
		t.Fatalf("poll after a late commit = %v, want the late message and the settle-window duplicate of the newest", got)
	}
	// A message more than 5 s older than the newest is not repeated: rows[2] is 2 s older than the late one, so it is
	// still inside the window, rows[1] (10 s older) is not.
	resp3 := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: resp2.SinceToken})
	if got := msgIDs(resp3); len(got) != 2 || got[0] != late.ID || got[1] != rows[2].ID {
		t.Errorf("third poll = %v", got)
	}
	if resp3.Conversation != nil {
		t.Error("a poll carries a conversation")
	}
}

// A since poll whose page is full returns gap_page_token; paging it fills the gap down to the old since position and stops
// there, with no conversation.
func TestListMessages_GapPageToken(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(2, nil)
	first := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	// 45 new messages arrive after the first page.
	for i := range 45 {
		rg.repo.msgs[aliceBobConv] = append(rg.repo.msgs[aliceBobConv], MessageRow{ID: fmt.Sprintf("%032x", 1000+i), MsgDoc: MsgDoc{
			SenderID: bob, Text: "new", State: msgVisible, CreatedAt: rg.now.Add(-time.Minute).Add(time.Duration(i) * time.Second),
		}})
	}
	poll := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken, PageSize: 20})
	if len(poll.Messages) != 20 || poll.GapPageToken == "" || poll.NextPageToken != "" || poll.SinceToken == "" || poll.Conversation != nil {
		t.Fatalf("poll = %d messages gap=%q next=%q since=%q conversation=%v", len(poll.Messages), poll.GapPageToken, poll.NextPageToken, poll.SinceToken, poll.Conversation)
	}
	seen := map[string]bool{}
	for _, id := range msgIDs(poll) {
		seen[id] = true
	}
	token := poll.GapPageToken
	for range 3 {
		page := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, PageToken: token, PageSize: 20})
		if page.Conversation != nil || page.SinceToken != "" || page.GapPageToken != "" {
			t.Fatalf("gap fill carries conversation=%v since=%q gap=%q", page.Conversation, page.SinceToken, page.GapPageToken)
		}
		for _, id := range msgIDs(page) {
			if seen[id] {
				t.Fatalf("message %s returned twice", id)
			}
			seen[id] = true
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if len(seen) < 45 {
		t.Errorf("poll + gap fill returned %d distinct new messages, want >= 45 (the 2 old ones are within the settle window)", len(seen))
	}
	last := rg.repo.msgQueries[len(rg.repo.msgQueries)-1]
	if last.After == nil {
		t.Error("the gap fill lost its lower bound")
	}
}

func TestListMessages_NotFoundIsByteIdentical(t *testing.T) {
	rg := newRig(t, nil)
	rg.putThread(3, nil)
	carolConv := ConversationID(alice, "uid-carol") // does not exist
	var want []byte
	for i, tt := range []struct {
		name string
		uid  string
		id   string
	}{
		{"unknown id", alice, carolConv},
		{"non-participant", "uid-mallory", aliceBobConv},
		{"unknown id, other caller", "uid-mallory", carolConv},
	} {
		_, err := rg.svc.ListMessages(context.Background(), tt.uid, &messagingv1.ListMessagesRequest{ConversationId: tt.id})
		wantAPI(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil)
		got := wireBytes(t, err)
		if i == 0 {
			want = got
		} else if !bytes.Equal(got, want) {
			t.Errorf("%s bytes differ:\n got  %q\n want %q", tt.name, got, want)
		}
	}
	if len(rg.repo.msgQueries) != 0 || rg.profs.calls != 0 || rg.social.calls != 0 {
		t.Errorf("a refused call read messages (%d), profiles (%d) or the graph (%d)", len(rg.repo.msgQueries), rg.profs.calls, rg.social.calls)
	}
	// A cached conversation answers a non-participant the same way (the cache is keyed by id, membership is checked after).
	if _, err := rg.svc.ListMessages(context.Background(), "uid-mallory", &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); !bytes.Equal(wireBytes(t, err), want) {
		t.Error("cached non-participant bytes differ")
	}
}

func TestListMessages_ConversationBlock(t *testing.T) {
	tests := []struct {
		name       string
		mut        func(*rig)
		conv       func(*ConvDoc)
		uid        string
		wantCan    bool
		wantPeer   string
		wantState  messagingv1.ConversationState
		wantFolder messagingv1.Folder
	}{
		{"accepted, free", nil, nil, alice, true, bob, messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, inbox},
		{"caller blocks peer", func(r *rig) { r.social.snaps[alice] = graph.Snapshot{Blocked: map[string]bool{bob: true}} }, nil, alice, false, bob, messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, inbox},
		{"peer blocks caller (frozen entry peer)", func(r *rig) {
			r.social.snaps[alice] = graph.Snapshot{BlockedBy: map[string]bool{bob: true}}
			r.putEntry(alice, dmInboxCollection, EntryDoc{PeerID: bob, Peer: PeerDoc{Handle: "bob", DisplayName: "Bob"}})
		}, nil, alice, false, bob, messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, inbox},
		{"request, recipient", nil, func(c *ConvDoc) { c.State, c.RequestFrom, c.RequestTo = stateRequest, alice, bob }, bob, true, alice, messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, requests},
		{"request, requester", nil, func(c *ConvDoc) { c.State, c.RequestFrom, c.RequestTo = stateRequest, alice, bob }, alice, true, bob, messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, inbox},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, tt.mut)
			rg.putThread(1, tt.conv)
			resp := rg.listMsgs(t, tt.uid, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			c := resp.Conversation
			if c == nil || c.CanReply != tt.wantCan || c.Peer.UserId != tt.wantPeer || c.State != tt.wantState || c.Folder != tt.wantFolder {
				t.Fatalf("conversation = %+v, want can_reply %v peer %s state %v folder %v", c, tt.wantCan, tt.wantPeer, tt.wantState, tt.wantFolder)
			}
			if c.Peer.Handle == "" || c.Peer.DisplayName == "" {
				t.Errorf("peer snapshot = %+v, want the live profile", c.Peer)
			}
		})
	}
}

// An erased peer is "Deleted account", never looked up, can_reply false; the same for a peer the directory no longer lists.
func TestListMessages_DeletedPeer(t *testing.T) {
	t.Run("DeletedUID", func(t *testing.T) {
		rg := newRig(t, nil)
		rows := rg.putThread(2, func(c *ConvDoc) { c.Participants = sortedPair(alice, DeletedUID); c.Gone = []string{DeletedUID} })
		rows[1].SenderID, rows[1].State, rows[1].Text = DeletedUID, msgDeletedAccount, ""
		resp := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if rg.profs.calls != 0 {
			t.Errorf("directory calls = %d, want 0 for DeletedUID", rg.profs.calls)
		}
		c := resp.Conversation
		if c.Peer.DisplayName != DeletedAccountName || c.Peer.UserId != "" || c.Peer.Handle != "" || c.CanReply {
			t.Fatalf("conversation = %+v", c)
		}
		if resp.Messages[0].State != messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT || resp.Messages[0].Text != "" || resp.Messages[0].FromSelf {
			t.Errorf("tombstone = %+v", resp.Messages[0])
		}
	})
	t.Run("not listed as ACTIVE", func(t *testing.T) {
		rg := newRig(t, func(r *rig) { delete(r.profs.profiles, bob) })
		rg.putThread(1, nil)
		c := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}).Conversation
		if c.Peer.DisplayName != DeletedAccountName || c.Peer.UserId != "" || c.CanReply {
			t.Fatalf("conversation = %+v", c)
		}
	})
}

func TestListMessages_ErrorsAndLogs(t *testing.T) {
	t.Run("repo error is redacted", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(1, nil)
		rg.repo.msgErr = errors.New("boom projects/p/documents/conversations/" + aliceBobConv)
		_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if err == nil || bytes.Contains([]byte(err.Error()), []byte(aliceBobConv)) {
			t.Fatalf("err = %v, want an error without the conversation id", err)
		}
	})
	t.Run("peer lookup error", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(1, nil)
		rg.profs.err = errors.New("directory down")
		if _, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); err == nil {
			t.Fatal("want an error")
		}
	})
	t.Run("canceled context", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(1, nil)
		rg.repo.msgErr = context.Canceled
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := rg.svc.ListMessages(ctx, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if code, _, _ := reasonOf(t, err); code != connect.CodeCanceled {
			t.Fatalf("code = %v, want Canceled", code)
		}
	})
	t.Run("request line", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putThread(3, nil)
		ctx, info := logger.WithRequestInfo(context.Background())
		first, err := rg.svc.ListMessages(ctx, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
		if err != nil {
			t.Fatal(err)
		}
		for k, want := range map[string]any{fieldKind: kindListMessages, fieldPoll: false, fieldResults: int(3), fieldCacheHit: false, fieldConvHash: logger.HashUID(aliceBobConv)} {
			if v, _ := info.Get(k); fmt.Sprint(v) != fmt.Sprint(want) {
				t.Errorf("%s = %v, want %v", k, v, want)
			}
		}
		ctx, info = logger.WithRequestInfo(context.Background())
		if _, err := rg.svc.ListMessages(ctx, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv, SinceToken: first.SinceToken}); err != nil {
			t.Fatal(err)
		}
		for k, want := range map[string]any{fieldKind: kindPoll, fieldPoll: true, fieldCacheHit: true} {
			if v, _ := info.Get(k); fmt.Sprint(v) != fmt.Sprint(want) {
				t.Errorf("poll %s = %v, want %v", k, v, want)
			}
		}
		for _, a := range info.Fields() {
			if s := a.Value.String(); s == aliceBobConv || s == alice || s == bob || bytes.Contains([]byte(s), []byte("secret text")) {
				t.Errorf("log field %s holds %q: no uid, conversation id or text in the line", a.Key, s)
			}
		}
	})
	t.Run("not configured", func(t *testing.T) {
		svc := New(flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.On}), Deps{})
		if _, err := svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); err == nil {
			t.Fatal("want an error")
		}
		if _, err := svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestListMessages_FlagModes(t *testing.T) {
	for _, tt := range []struct {
		name string
		mode flags.Mode
		pct  int
		open bool
	}{
		{"off", flags.Off, 0, false},
		{"allowlist, caller outside", flags.Allowlist, 0, true},
		{"percent 0, caller outside", flags.Percent, 0, true},
		{"on", flags.On, 0, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: tt.mode, Percent: tt.pct}) })
			rg.putThread(1, nil)
			_, err := rg.svc.ListMessages(context.Background(), alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
			_, merr := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv})
			if tt.open != (err == nil) || tt.open != (merr == nil) {
				t.Fatalf("list err = %v, mark err = %v, open = %v", err, merr, tt.open)
			}
			if !tt.open {
				if code, reason, meta := reasonOf(t, err); code != connect.CodeFailedPrecondition || reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != FlagName {
					t.Errorf("err = %v %v %v", code, reason, meta)
				}
				if rg.repo.gets != 0 || len(rg.repo.marked) != 0 {
					t.Error("a disabled call touched storage")
				}
			}
		})
	}
}

func TestMarkRead(t *testing.T) {
	t.Run("writes and evicts the badge", func(t *testing.T) {
		rg := newRig(t, nil)
		ctx, info := logger.WithRequestInfo(context.Background())
		if _, err := rg.svc.MarkRead(ctx, alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err != nil {
			t.Fatal(err)
		}
		if len(rg.repo.marked) != 1 || rg.repo.marked[0] != alice+"|"+aliceBobConv {
			t.Errorf("marked = %v", rg.repo.marked)
		}
		if len(rg.badge.got) != 1 || len(rg.badge.got[0]) != 1 || rg.badge.got[0][0] != alice {
			t.Errorf("badge evictions = %v, want [[alice]] (the caller only)", rg.badge.got)
		}
		if rg.repo.gets != 0 {
			t.Errorf("conversation reads = %d, want 0", rg.repo.gets)
		}
		if v, _ := info.Get(fieldKind); v != kindMarkRead {
			t.Errorf("kind = %v", v)
		}
		if v, _ := info.Get(fieldEntryFound); v != true {
			t.Errorf("entry_found = %v", v)
		}
	})
	t.Run("missing entry is success, nothing evicted", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.repo.markMissing = true
		if _, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err != nil {
			t.Fatal(err)
		}
		if len(rg.badge.got) != 0 {
			t.Errorf("badge evictions = %v, want none for a 0-write answer", rg.badge.got)
		}
	})
	t.Run("nil badge", func(t *testing.T) {
		rg := newRig(t, nil)
		svc := New(rg.reg, Deps{Repo: rg.repo, Now: func() time.Time { return rg.now }})
		if _, err := svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv}); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("validation", func(t *testing.T) {
		rg := newRig(t, nil)
		for _, id := range []string{"", "xyz", "ABCDEFABCDEFABCDEFABCDEFABCDEFAB"} {
			_, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: id})
			wantField(t, err, "conversation_id")
		}
		if len(rg.repo.marked) != 0 {
			t.Error("a malformed id reached storage")
		}
	})
	t.Run("repo error is redacted", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.repo.markErr = errors.New("boom users/" + alice + "/dmInbox/" + aliceBobConv)
		_, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv})
		if err == nil || bytes.Contains([]byte(err.Error()), []byte(alice)) || bytes.Contains([]byte(err.Error()), []byte(aliceBobConv)) {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("canceled", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.repo.markErr = context.Canceled
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := rg.svc.MarkRead(ctx, alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: lifeKey, ConversationId: aliceBobConv})
		if code, _, _ := reasonOf(t, err); code != connect.CodeCanceled {
			t.Fatalf("code = %v", code)
		}
	})
}

// A malformed idempotency_key on MarkConversationRead is VALIDATION idempotency_key with nothing stored (founder decision
// 2026-10-29: the key is format-validated, not stored); the interceptor's read is the only read.
func TestMarkRead_MalformedKey(t *testing.T) {
	for _, key := range []string{"", "short", "has spaces in the key!!", strings.Repeat("k", 65)} {
		rg := newRig(t, nil)
		_, err := rg.svc.MarkRead(context.Background(), alice, &messagingv1.MarkConversationReadRequest{IdempotencyKey: key, ConversationId: aliceBobConv})
		wantField(t, err, "idempotency_key")
		if len(rg.repo.marked) != 0 {
			t.Errorf("key %q reached storage", key)
		}
	}
}
