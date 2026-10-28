package messaging

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// putRequest stores a REQUEST from alice to bob: bob's entry in dmRequests (2 unread), alice's own in dmInbox (the
// requester sees the conversation in the Inbox). mut edits the conversation document.
func (r *rig) putRequest(mut func(*ConvDoc)) {
	conv := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob, RequestCount: 1}
	if mut != nil {
		mut(&conv)
	}
	r.repo.convs[aliceBobConv] = conv
	at := r.now.Add(-time.Hour)
	r.put(bob, dmRequestsCollection, EntryRow{ID: aliceBobConv, EntryDoc: EntryDoc{
		PeerID: alice, Peer: PeerDoc{Handle: "alice"}, LastMessageAt: at, UnreadCount: 2, Last: LastDoc{MessageID: "m", Snippet: "hi", State: msgVisible},
	}})
	r.put(alice, dmInboxCollection, EntryRow{ID: aliceBobConv, EntryDoc: EntryDoc{
		PeerID: bob, Peer: PeerDoc{Handle: "bob"}, LastMessageAt: at, Last: LastDoc{MessageID: "m", FromSelf: true, Snippet: "hi", State: msgVisible},
	}})
}

func (r *rig) accept(uid, convID string) error {
	_, err := r.svc.Accept(context.Background(), uid, &messagingv1.AcceptMessageRequestRequest{ConversationId: convID})
	return err
}

func (r *rig) del(uid, convID string) error {
	_, err := r.svc.Delete(context.Background(), uid, &messagingv1.DeleteConversationRequest{ConversationId: convID})
	return err
}

func (r *rig) has(uid, folder string) bool {
	_, ok := r.repo.findEntry(uid, folder, aliceBobConv)
	return ok
}

// The routing table of AcceptMessageRequest, pure: only requestTo accepts, an accepted conversation is a no-op, and a
// request whose peer deleted the account cannot be accepted.
func TestDecideAccept(t *testing.T) {
	t.Parallel()
	req := func(mut func(*ConvDoc)) *ConvDoc {
		c := &ConvDoc{Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob}
		if mut != nil {
			mut(c)
		}
		return c
	}
	tests := []struct {
		name    string
		conv    *ConvDoc
		uid     string
		want    acceptDecision
		wantErr error
	}{
		{"the recipient accepts", req(nil), bob, acceptDecision{}, nil},
		{"the requester", req(nil), alice, acceptDecision{}, ErrNotFound},
		{"a non-participant", req(nil), "uid-carol", acceptDecision{}, ErrNotFound},
		{"a missing conversation", nil, bob, acceptDecision{}, ErrNotFound},
		{"already accepted, replay by the recipient", req(func(c *ConvDoc) { c.State = stateAccepted }), bob, acceptDecision{Already: true}, nil},
		{"already accepted, the requester", req(func(c *ConvDoc) { c.State = stateAccepted }), alice, acceptDecision{}, ErrNotFound},
		{"never a request (mutual follows)", req(func(c *ConvDoc) { c.State, c.RequestFrom, c.RequestTo = stateAccepted, "", "" }), bob, acceptDecision{}, ErrNotFound},
		{"the requester erased the account", req(func(c *ConvDoc) {
			c.Participants, c.Gone, c.RequestFrom = []string{DeletedUID, bob}, []string{DeletedUID}, DeletedUID
		}), bob, acceptDecision{}, ErrCannotMessage},
		{"accepted, then the requester erased the account", req(func(c *ConvDoc) {
			c.State, c.Participants, c.Gone = stateAccepted, []string{DeletedUID, bob}, []string{DeletedUID}
		}), bob, acceptDecision{Already: true}, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := decideAccept(tt.conv, tt.uid)
			if !errors.Is(err, tt.wantErr) || got != tt.want {
				t.Errorf("decideAccept = %+v, %v; want %+v, %v", got, err, tt.want, tt.wantErr)
			}
		})
	}
}

func TestDecideDeleteAndReplay(t *testing.T) {
	t.Parallel()
	cleared := map[string]time.Time{bob: time.Date(2026, 10, 28, 1, 0, 0, 0, time.UTC)}
	req := &ConvDoc{Participants: sortedPair(alice, bob), State: stateRequest, RequestFrom: alice, RequestTo: bob}
	acc := &ConvDoc{Participants: sortedPair(alice, bob), State: stateAccepted, RequestFrom: alice, RequestTo: bob}
	tests := []struct {
		name       string
		conv       *ConvDoc
		uid        string
		wantFolder string
		wantErr    error
	}{
		{"the recipient of a request", req, bob, entryRequests, nil},
		{"the requester of a request", req, alice, entryInbox, nil},
		{"the recipient after accept", acc, bob, entryInbox, nil},
		{"a non-participant", req, "uid-carol", "", ErrNotFound},
		{"a missing conversation", nil, bob, "", ErrNotFound},
		{"an erased peer can still be cleaned up", &ConvDoc{Participants: []string{DeletedUID, bob}, Gone: []string{DeletedUID}, State: stateAccepted}, bob, entryInbox, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			folder, err := decideDelete(tt.conv, tt.uid)
			if folder != tt.wantFolder || !errors.Is(err, tt.wantErr) {
				t.Errorf("decideDelete = %q, %v; want %q, %v", folder, err, tt.wantFolder, tt.wantErr)
			}
		})
	}
	replay := []struct {
		name   string
		conv   ConvDoc
		exists bool
		want   bool
	}{
		{"entry present, never cleared", ConvDoc{}, true, false},
		{"entry present, cleared before (a new message recreated it)", ConvDoc{ClearedAt: cleared}, true, false},
		{"entry gone, cleared: a repeat", ConvDoc{ClearedAt: cleared}, false, true},
		{"entry gone, never cleared: an anomaly, still sets clearedAt", ConvDoc{}, false, false},
		{"entry gone, only the peer cleared", ConvDoc{ClearedAt: map[string]time.Time{alice: cleared[bob]}}, false, false},
	}
	for _, tt := range replay {
		if got := deleteIsReplay(tt.conv, bob, tt.exists); got != tt.want {
			t.Errorf("%s: deleteIsReplay = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// Given B accepts, then the conversation is ACCEPTED, B's request entry moved to the Inbox with its unread count, A's own
// entry untouched, this instance's cache and B's badge cache refreshed, and the request line carries kind=accept.
func TestAccept_MovesTheRequest(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := rg.svc.Accept(ctx, bob, &messagingv1.AcceptMessageRequestRequest{ConversationId: aliceBobConv}); err != nil {
		t.Fatal(err)
	}
	if got := rg.repo.convs[aliceBobConv].State; got != stateAccepted {
		t.Errorf("state = %q, want ACCEPTED", got)
	}
	if rg.has(bob, dmRequestsCollection) || !rg.has(bob, dmInboxCollection) || !rg.has(alice, dmInboxCollection) {
		t.Error("entries: bob's request not moved to his inbox, or alice's lost")
	}
	if i, _ := rg.repo.findEntry(bob, dmInboxCollection, aliceBobConv); rg.repo.entries[entryKey(bob, dmInboxCollection)][i].UnreadCount != 2 {
		t.Error("the unread count was not kept")
	}
	if rg.repo.writes != 2 || rg.repo.deletedDocs != 1 {
		t.Errorf("writes/deletes = %d/%d, want 2/1", rg.repo.writes, rg.repo.deletedDocs)
	}
	if c, ok := rg.svc.convs.Get(aliceBobConv); !ok || c.State != stateAccepted {
		t.Errorf("instance cache = %+v %v, want the accepted conversation", c, ok)
	}
	if len(rg.badge.got) != 1 || len(rg.badge.got[0]) != 1 || rg.badge.got[0][0] != bob {
		t.Errorf("badge evictions = %v, want [[bob]]", rg.badge.got)
	}
	if len(rg.events.got) != 0 {
		t.Errorf("events = %v, accept emits nothing", rg.events.got)
	}
	for k, want := range map[string]any{fieldKind: kindAccept, fieldState: stateLabelAccept, fieldReplay: false, fieldConvHash: logger.HashUID(aliceBobConv)} {
		if v, _ := info.Get(k); v != want {
			t.Errorf("request field %s = %v, want %v", k, v, want)
		}
	}
	if rg.repo.accepts[0].UID != bob || rg.repo.accepts[0].Now != rg.now {
		t.Errorf("params = %+v", rg.repo.accepts[0])
	}
}

// Given an accept replayed, then success and nothing written, nothing evicted.
func TestAccept_Replay(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	if err := rg.accept(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	writes, deletes, evictions := rg.repo.writes, rg.repo.deletedDocs, len(rg.badge.got)
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := rg.svc.Accept(ctx, bob, &messagingv1.AcceptMessageRequestRequest{ConversationId: aliceBobConv}); err != nil {
		t.Fatalf("replay: %v", err)
	}
	if rg.repo.writes != writes || rg.repo.deletedDocs != deletes || len(rg.badge.got) != evictions {
		t.Errorf("a replay wrote %d / deleted %d / evicted %d", rg.repo.writes-writes, rg.repo.deletedDocs-deletes, len(rg.badge.got)-evictions)
	}
	if v, _ := info.Get(fieldReplay); v != true {
		t.Errorf("replay = %v, want true", v)
	}
}

// Given the requester (or a non-participant, or an unknown id, or a conversation that never was a request) calls Accept,
// then NOT_FOUND with identical bytes and nothing written.
func TestAccept_NotFoundByteIdentical(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	mutual := ConversationID(alice, "uid-dave")
	rg.repo.convs[mutual] = ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, "uid-dave"), State: stateAccepted}
	cases := map[string]error{
		"the requester":       rg.accept(alice, aliceBobConv),
		"a non-participant":   rg.accept("uid-carol", aliceBobConv),
		"an unknown id":       rg.accept(bob, ConversationID(bob, "uid-nobody")),
		"never a request":     rg.accept(alice, mutual),
		"unknown, other user": rg.accept("uid-carol", ConversationID(bob, "uid-nobody")),
	}
	var first []byte
	for name, err := range cases {
		if code, _, _ := reasonOf(t, err); code != connect.CodeNotFound {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
		b := wireBytes(t, err)
		if first == nil {
			first = b
		} else if !bytes.Equal(first, b) {
			t.Errorf("%s: bytes differ from the others: %q vs %q", name, b, first)
		}
	}
	if rg.repo.writes != 0 || rg.repo.deletedDocs != 0 || !rg.has(bob, dmRequestsCollection) {
		t.Error("a refused accept changed state")
	}
	if len(rg.badge.got) != 0 || rg.repo.convs[aliceBobConv].State != stateRequest {
		t.Error("a refused accept evicted a badge or changed the state")
	}
}

// A request the recipient deleted for themselves is a deleted conversation: NOT_FOUND. A request from an erased account and
// a peer outside the flag cohort are CANNOT_MESSAGE with identical bytes (the cause is only in the log).
func TestAccept_Refusals(t *testing.T) {
	t.Run("deleted request", func(t *testing.T) {
		rg := newRig(t, nil)
		rg.putRequest(nil)
		if err := rg.del(bob, aliceBobConv); err != nil {
			t.Fatal(err)
		}
		err := rg.accept(bob, aliceBobConv)
		if code, _, _ := reasonOf(t, err); code != connect.CodeNotFound {
			t.Fatalf("err = %v, want NOT_FOUND", err)
		}
		if rg.repo.convs[aliceBobConv].State != stateRequest {
			t.Error("a refused accept moved the state")
		}
	})
	gone := newRig(t, nil)
	gone.putRequest(func(c *ConvDoc) {
		c.Participants, c.Gone, c.RequestFrom = []string{DeletedUID, bob}, []string{DeletedUID}, DeletedUID
	})
	errGone := gone.accept(bob, aliceBobConv)

	off := newRig(t, func(r *rig) {
		r.reg = flags.NewRegistry(flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{bob: {}}})
	})
	off.putRequest(nil)
	errOff := off.accept(bob, aliceBobConv)

	for name, err := range map[string]error{"requester erased": errGone, "peer flag off": errOff} {
		if code, reason, _ := reasonOf(t, err); code != connect.CodeFailedPrecondition || reason != commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE {
			t.Fatalf("%s: err = %v, want CANNOT_MESSAGE", name, err)
		}
	}
	if !bytes.Equal(wireBytes(t, errGone), wireBytes(t, errOff)) {
		t.Error("the two CANNOT_MESSAGE answers differ on the wire")
	}
	for name, rg := range map[string]*rig{"requester erased": gone, "peer flag off": off} {
		if rg.repo.writes != 0 || !rg.has(bob, dmRequestsCollection) {
			t.Errorf("%s: a refused accept changed state", name)
		}
	}
	// An accepted conversation whose peer was erased since is still a replay.
	late := newRig(t, nil)
	late.putRequest(nil)
	if err := late.accept(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	c := late.repo.convs[aliceBobConv]
	c.Participants, c.Gone = []string{DeletedUID, bob}, []string{DeletedUID}
	late.repo.convs[aliceBobConv] = c
	late.svc.convs.Delete(aliceBobConv)
	if err := late.accept(bob, aliceBobConv); err != nil {
		t.Errorf("replay after the peer erased the account: %v", err)
	}
}

func TestAccept_Validation(t *testing.T) {
	rg := newRig(t, nil)
	for _, id := range []string{"", "nope", "ABCDEF0123456789ABCDEF0123456789", aliceBobConv + "0"} {
		err := rg.accept(bob, id)
		wantField(t, err, "conversation_id")
	}
	if len(rg.repo.accepts) != 0 {
		t.Error("an invalid id reached storage")
	}
}

// Flag modes (ADR-0027 D6): Accept needs the flag on for the caller; Delete only needs it not globally off. The peer's flag
// is a second check for Accept (CANNOT_MESSAGE), never for Delete.
func TestAcceptDelete_FlagModes(t *testing.T) {
	tests := []struct {
		name       string
		spec       flags.Spec
		caller     string
		acceptOpen bool
		deleteOpen bool
	}{
		{"off", flags.Spec{Name: FlagName, Mode: flags.Off}, bob, false, false},
		{"allowlist, caller listed", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{alice: {}, bob: {}}}, bob, true, true},
		{"allowlist, caller outside", flags.Spec{Name: FlagName, Mode: flags.Allowlist, Allowlist: map[string]struct{}{alice: {}}}, bob, false, true},
		{"percent 0", flags.Spec{Name: FlagName, Mode: flags.Percent}, bob, false, true},
		{"percent 100", flags.Spec{Name: FlagName, Mode: flags.Percent, Percent: 100}, bob, true, true},
		{"on", flags.Spec{Name: FlagName, Mode: flags.On}, bob, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rg := newRig(t, func(r *rig) { r.reg = flags.NewRegistry(tt.spec) })
			rg.putRequest(nil)
			aerr := rg.accept(tt.caller, aliceBobConv)
			if tt.acceptOpen != (aerr == nil) {
				t.Fatalf("accept err = %v, open = %v", aerr, tt.acceptOpen)
			}
			if !tt.acceptOpen {
				if _, reason, meta := reasonOf(t, aerr); reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != FlagName {
					t.Errorf("accept err = %v", aerr)
				}
				if len(rg.repo.accepts) != 0 {
					t.Error("a disabled accept reached storage")
				}
			}
			derr := rg.del(tt.caller, aliceBobConv)
			if tt.deleteOpen != (derr == nil) {
				t.Fatalf("delete err = %v, open = %v", derr, tt.deleteOpen)
			}
			if !tt.deleteOpen {
				if _, reason, meta := reasonOf(t, derr); reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != FlagName {
					t.Errorf("delete err = %v", derr)
				}
				if len(rg.repo.deletes) != 0 {
					t.Error("a disabled delete reached storage")
				}
			}
		})
	}
}

// Given B deletes a request, then B's folder lacks it, clearedAt[B] is set, the state is still REQUEST and A's entry is
// untouched. The request line carries kind=delete, the folder and the conversation state.
func TestDelete_Request(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := rg.svc.Delete(ctx, bob, &messagingv1.DeleteConversationRequest{ConversationId: aliceBobConv}); err != nil {
		t.Fatal(err)
	}
	conv := rg.repo.convs[aliceBobConv]
	if conv.State != stateRequest || !conv.ClearedAt[bob].Equal(rg.now) || !conv.ClearedAt[alice].IsZero() {
		t.Errorf("conversation = %+v, want REQUEST with clearedAt[bob] = now only", conv)
	}
	if rg.has(bob, dmRequestsCollection) || !rg.has(alice, dmInboxCollection) {
		t.Error("entries: bob's request still there, or alice's lost")
	}
	if rg.repo.writes != 1 || rg.repo.deletedDocs != 1 {
		t.Errorf("writes/deletes = %d/%d, want 1/1", rg.repo.writes, rg.repo.deletedDocs)
	}
	if len(rg.badge.got) != 1 || rg.badge.got[0][0] != bob {
		t.Errorf("badge evictions = %v, want [[bob]]", rg.badge.got)
	}
	for k, want := range map[string]any{fieldKind: kindDelete, fieldState: stateLabelRequest, fieldFolder: folderLabelRequests, fieldReplay: false} {
		if v, _ := info.Get(k); v != want {
			t.Errorf("request field %s = %v, want %v", k, v, want)
		}
	}
}

// Delete from the Inbox (an accepted conversation), by either side; the other side keeps everything.
func TestDelete_Inbox(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	if err := rg.accept(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	if err := rg.del(alice, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	if rg.has(alice, dmInboxCollection) || !rg.has(bob, dmInboxCollection) {
		t.Error("alice's delete removed bob's entry, or did not remove hers")
	}
	conv := rg.repo.convs[aliceBobConv]
	if conv.State != stateAccepted || conv.ClearedAt[alice].IsZero() || !conv.ClearedAt[bob].IsZero() {
		t.Errorf("conversation = %+v", conv)
	}
}

// Given a repeated delete (a retry whose response was lost), then success and nothing written.
func TestDelete_Replay(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	if err := rg.del(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	cleared := rg.repo.convs[aliceBobConv].ClearedAt[bob]
	writes, deletes, evictions := rg.repo.writes, rg.repo.deletedDocs, len(rg.badge.got)
	rg.now = rg.now.Add(time.Minute)
	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := rg.svc.Delete(ctx, bob, &messagingv1.DeleteConversationRequest{ConversationId: aliceBobConv}); err != nil {
		t.Fatalf("replay: %v", err)
	}
	if rg.repo.writes != writes || rg.repo.deletedDocs != deletes || len(rg.badge.got) != evictions {
		t.Error("a replayed delete wrote, deleted or evicted")
	}
	if !rg.repo.convs[aliceBobConv].ClearedAt[bob].Equal(cleared) {
		t.Error("a replayed delete moved clearedAt")
	}
	if v, _ := info.Get(fieldReplay); v != true {
		t.Errorf("replay = %v, want true", v)
	}
}

// Given a non-participant or an unknown id, then the same NOT_FOUND bytes as Accept, and nothing written.
func TestDelete_NotFoundByteIdentical(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(nil)
	errs := map[string]error{
		"a non-participant": rg.del("uid-carol", aliceBobConv),
		"an unknown id":     rg.del(bob, ConversationID(bob, "uid-nobody")),
		"unknown, other":    rg.del("uid-carol", ConversationID(bob, "uid-nobody")),
		"accept, requester": rg.accept(alice, aliceBobConv),
	}
	var first []byte
	for name, err := range errs {
		if code, _, _ := reasonOf(t, err); code != connect.CodeNotFound {
			t.Fatalf("%s: err = %v, want NOT_FOUND", name, err)
		}
		if b := wireBytes(t, err); first == nil {
			first = b
		} else if !bytes.Equal(first, b) {
			t.Errorf("%s: bytes differ", name)
		}
	}
	if rg.repo.writes != 0 || len(rg.repo.convs[aliceBobConv].ClearedAt) != 0 {
		t.Error("a refused delete changed state")
	}
}

// Given an erased peer, the caller can still delete the conversation (clean-up), and clearedAt is set.
func TestDelete_ErasedPeer(t *testing.T) {
	rg := newRig(t, nil)
	rg.putRequest(func(c *ConvDoc) {
		c.State, c.Participants, c.Gone, c.RequestFrom = stateAccepted, []string{DeletedUID, bob}, []string{DeletedUID}, DeletedUID
	})
	rg.repo.entries[entryKey(bob, dmInboxCollection)] = rg.repo.entries[entryKey(bob, dmRequestsCollection)]
	delete(rg.repo.entries, entryKey(bob, dmRequestsCollection))
	if err := rg.del(bob, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	if rg.has(bob, dmInboxCollection) || rg.repo.convs[aliceBobConv].ClearedAt[bob].IsZero() {
		t.Error("an erased peer's conversation could not be deleted")
	}
}

// Given clearedAt set by Delete, then ListMessages on the same instance hides the older messages at once, although the
// conversation was cached before (D14: other instances converge within 60 s).
func TestDelete_ClearedAtTakesEffectOnThisInstance(t *testing.T) {
	rg := newRig(t, nil)
	rows := rg.putThread(6, nil)
	rg.put(alice, dmInboxCollection, EntryRow{ID: aliceBobConv, EntryDoc: EntryDoc{PeerID: bob}})
	before := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if len(before.Messages) != 6 {
		t.Fatalf("setup: %d messages", len(before.Messages))
	}
	// Time passes: the thread's messages are an hour old, the delete happens now.
	if err := rg.del(alice, aliceBobConv); err != nil {
		t.Fatal(err)
	}
	after := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv})
	if len(after.Messages) != 0 {
		t.Errorf("after the delete alice still sees %d messages", len(after.Messages))
	}
	// The peer keeps the whole thread.
	if got := rg.listMsgs(t, bob, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); len(got.Messages) != len(rows) {
		t.Errorf("bob sees %d messages, want %d", len(got.Messages), len(rows))
	}
	// A message newer than the delete shows.
	rg.now = rg.now.Add(time.Minute)
	rg.repo.msgs[aliceBobConv] = append(rg.repo.msgs[aliceBobConv], MessageRow{ID: fmt.Sprintf("%032x", 99), MsgDoc: MsgDoc{SenderID: bob, Text: "new", State: msgVisible, CreatedAt: rg.now}})
	if got := rg.listMsgs(t, alice, &messagingv1.ListMessagesRequest{ConversationId: aliceBobConv}); len(got.Messages) != 1 || got.Messages[0].Text != "new" {
		t.Errorf("after a newer message alice sees %+v, want only it", got.Messages)
	}
}

func TestAcceptDelete_Errors(t *testing.T) {
	calls := map[string]func(*rig) error{
		"accept": func(r *rig) error { return r.accept(bob, aliceBobConv) },
		"delete": func(r *rig) error { return r.del(bob, aliceBobConv) },
	}
	for name, call := range calls {
		t.Run(name+"/internal error is redacted and not an apierr", func(t *testing.T) {
			rg := newRig(t, nil)
			rg.repo.lifeErr = fmt.Errorf("rpc: users/%s/dmRequests/%s failed", bob, aliceBobConv)
			err := call(rg)
			var ae *apierr.Error
			if err == nil || errors.As(err, &ae) {
				t.Fatalf("err = %v, want a plain internal error", err)
			}
			if containsAny(err.Error(), bob, aliceBobConv) {
				t.Errorf("error leaks an id: %q", err)
			}
		})
		t.Run(name+"/contention is UNAVAILABLE with a retry hint", func(t *testing.T) {
			rg := newRig(t, nil)
			rg.repo.lifeErr = fmt.Errorf("txn: %w", store.ErrContended)
			err := call(rg)
			if code, _, _ := reasonOf(t, err); code != connect.CodeUnavailable {
				t.Fatalf("err = %v, want UNAVAILABLE", err)
			}
		})
		t.Run(name+"/deadline", func(t *testing.T) {
			rg := newRig(t, nil)
			rg.repo.lifeErr = context.DeadlineExceeded
			ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
			defer cancel()
			var err error
			if name == "accept" {
				_, err = rg.svc.Accept(ctx, bob, &messagingv1.AcceptMessageRequestRequest{ConversationId: aliceBobConv})
			} else {
				_, err = rg.svc.Delete(ctx, bob, &messagingv1.DeleteConversationRequest{ConversationId: aliceBobConv})
			}
			if code, _, _ := reasonOf(t, err); code != connect.CodeDeadlineExceeded {
				t.Fatalf("err = %v, want DEADLINE_EXCEEDED", err)
			}
		})
		t.Run(name+"/not configured", func(t *testing.T) {
			svc := New(newRig(t, nil).reg, Deps{})
			var err error
			if name == "accept" {
				_, err = svc.Accept(context.Background(), bob, &messagingv1.AcceptMessageRequestRequest{ConversationId: aliceBobConv})
			} else {
				_, err = svc.Delete(context.Background(), bob, &messagingv1.DeleteConversationRequest{ConversationId: aliceBobConv})
			}
			if err == nil {
				t.Fatal("want an error without a repo")
			}
		})
	}
	t.Run("delete validation", func(t *testing.T) {
		rg := newRig(t, nil)
		wantField(t, rg.del(bob, "nope"), "conversation_id")
		if len(rg.repo.deletes) != 0 {
			t.Error("an invalid id reached storage")
		}
	})
}
