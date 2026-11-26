package messaging

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// The walk's classification: only a plaintext message with something readable is purged; an encrypted message never is,
// whatever its stored fields say; a message purged before only feeds the preview check.
func TestPlaintextClass(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		m    MsgDoc
		want int
	}{
		{"plaintext text", MsgDoc{State: msgVisible, Text: "hello", RequestHash: "h"}, plainReadable},
		{"a post share without a caption", MsgDoc{State: msgVisible, SharedPostID: "7300000000000000001"}, plainReadable},
		{"only the request digest is left", MsgDoc{State: msgVisible, RequestHash: "h"}, plainReadable},
		{"an encrypted message is never touched", MsgDoc{State: msgVisible, Text: "stray", RequestHash: "h", MlsGen: 1, Ciphertext: []byte("ct")}, plainNone},
		{"a swept encrypted message is never touched", MsgDoc{State: msgVisible, RequestHash: "h", CtRemoved: true}, plainNone},
		{"purged before", MsgDoc{State: msgVisible, TextRemoved: true}, plainPurged},
		{"a takedown tombstone holds nothing readable", MsgDoc{State: msgRemoved}, plainNone},
		{"an eraser tombstone holds nothing readable", MsgDoc{State: msgDeletedAccount, SenderID: DeletedUID}, plainNone},
	}
	for _, tt := range tests {
		if got := plaintextClass(tt.m); got != tt.want {
			t.Errorf("%s: class = %d, want %d", tt.name, got, tt.want)
		}
	}
}

// The one field update clears text, requestHash and sharedPostId and sets textRemoved; it never names state, senderId,
// the times or any encrypted field.
func TestPlaintextRemoval_ClearsTextDigestAndPostAndSetsTextRemoved(t *testing.T) {
	t.Parallel()
	got := map[string]any{}
	for _, u := range plaintextRemoval() {
		got[u.Path] = u.Value
	}
	want := map[string]any{"text": "", "requestHash": "", "sharedPostId": firestore.Delete, "textRemoved": true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("update = %v, want %v", got, want)
	}
}

func TestPreviewStale(t *testing.T) {
	t.Parallel()
	gone := map[string]bool{"m1": true}
	tests := []struct {
		name string
		l    LastDoc
		want bool
	}{
		{"a purged last message", LastDoc{MessageID: "m1", Snippet: "hello", State: msgVisible}, true},
		{"a purged post share", LastDoc{MessageID: "m1", Snippet: noLongerStoredSnippet, State: msgVisible, SharedPost: true}, true},
		{"already rewritten", LastDoc{MessageID: "m1", Snippet: noLongerStoredSnippet, State: msgVisible}, false},
		{"another message is last", LastDoc{MessageID: "m2", Snippet: "newer", State: msgVisible}, false},
		{"taken down since", LastDoc{MessageID: "m1", Snippet: removedSnippet, State: msgRemoved}, false},
		{"the sender deleted the account", LastDoc{MessageID: "m1", Snippet: deletedSnippet, State: msgDeletedAccount}, false},
		{"an encrypted preview", LastDoc{MessageID: "m1", State: msgVisible, Encrypted: true}, false},
	}
	for _, tt := range tests {
		if got := previewStale(tt.l, gone); got != tt.want {
			t.Errorf("%s: stale = %v, want %v", tt.name, got, tt.want)
		}
	}
}

func TestPlaintextPage_Add(t *testing.T) {
	t.Parallel()
	var sum PlaintextPage
	sum.Add(PlaintextPage{Last: "a", More: true, Conversations: 50, Messages: 10, Plaintext: 4, Purged: 3, Skipped: 1, Previews: 2, PreviewsSkipped: 1})
	sum.Add(PlaintextPage{Last: "b", Conversations: 2, Messages: 1, Plaintext: 1, Purged: 1, Previews: 1})
	want := PlaintextPage{Last: "b", Conversations: 52, Messages: 11, Plaintext: 5, Purged: 4, Skipped: 1, Previews: 3, PreviewsSkipped: 1}
	if sum != want {
		t.Errorf("sum = %+v, want %+v", sum, want)
	}
}

// ListMessages (messageOf) answers text_removed = true and no text for a purged message, in any state; never for an
// encrypted one.
func TestMessageOf_TextRemoved(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name string
		doc  MsgDoc
		want bool
	}{
		{"a purged visible message", MsgDoc{SenderID: alice, State: msgVisible, TextRemoved: true}, true},
		{"a purged message taken down later", MsgDoc{SenderID: alice, State: msgRemoved, TextRemoved: true}, true},
		{"a plain message", MsgDoc{SenderID: alice, State: msgVisible, Text: "hi"}, false},
		{"an encrypted message", MsgDoc{SenderID: alice, State: msgVisible, TextRemoved: true, MlsGen: 1, Ciphertext: []byte("ct")}, false},
	} {
		m := messageOf(MessageRow{ID: msgID(0), MsgDoc: tt.doc}, aliceBobConv, alice)
		if m.GetTextRemoved() != tt.want {
			t.Errorf("%s: text_removed = %v, want %v", tt.name, m.GetTextRemoved(), tt.want)
		}
		if tt.want && (m.GetText() != "" || m.GetSharedPost() != nil) {
			t.Errorf("%s: a purged message carries text %q / post %v", tt.name, m.GetText(), m.GetSharedPost())
		}
	}
}

// A replayed purged tombstone answers text_removed too (sendResponse).
func TestSendResponse_TextRemoved(t *testing.T) {
	t.Parallel()
	res := SendResult{Replay: true, Msg: MsgDoc{SenderID: alice, State: msgRemoved, TextRemoved: true}}
	m := sendResponse(aliceBobConv, msgID(0), activeProfile(bob, "bob", ts(0)), res, false).GetMessage()
	if !m.GetTextRemoved() || m.GetText() != "" || m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED {
		t.Errorf("message = %v, want a REMOVED tombstone with text_removed", m)
	}
}

// An own sent message after the purge exports textRemoved = true and no text; a received one stays time and "received".
func TestExport_ShowsTextRemoved(t *testing.T) {
	t.Parallel()
	src := &fakeExportSource{
		convs: []ExportConv{{ID: "c1", PeerUID: "uid-peer-1", State: stateAccepted, CreatedAt: ts(10)}},
		msgs: map[string][]ExportMsg{"c1": {
			{ID: "m2", FromSelf: false, State: msgVisible, TextRemoved: true, CreatedAt: ts(12)},
			{ID: "m1", FromSelf: true, State: msgVisible, TextRemoved: true, CreatedAt: ts(11)},
		}},
	}
	raw, v := exportOf(t, src, &fakeHandles{byUID: map[string]string{"uid-peer-1": "alice"}})
	msgs := v["conversations"].([]any)[0].(map[string]any)["messages"].([]any)
	recv, sent := msgs[0].(map[string]any), msgs[1].(map[string]any)
	if len(recv) != 2 || recv["direction"] != "received" {
		t.Errorf("a received purged message = %v, want direction and time only", recv)
	}
	if sent["direction"] != "sent" || sent["textRemoved"] != true || sent["state"] != msgVisible {
		t.Errorf("an own purged message = %v, want sent, its state and textRemoved", sent)
	}
	if _, ok := sent["text"]; ok {
		t.Errorf("an own purged message exports a text field: %v", sent)
	}
	if strings.Contains(raw, `"note"`) {
		t.Errorf("a purged plaintext message is not encrypted: no note expected\n%s", raw)
	}
}

// A purged message cannot be reported: the same ErrNotFound sentinel as every other unreportable message.
func TestReportableMessage_PurgedIsUnreportable(t *testing.T) {
	t.Parallel()
	rg := newRig(t, nil)
	rows := rg.putThread(3, nil)
	rows[1].Text, rows[1].RequestHash, rows[1].TextRemoved = "", "", true
	rg.repo.msgs[aliceBobConv] = rows
	svc, _ := rg.reporter()
	got, err := svc.ReportableMessage(context.Background(), alice, aliceBobConv, msgID(1))
	if err != ErrNotFound || !errors.Is(err, ErrNotFound) { //nolint:errorlint // the sentinel itself is the contract
		t.Fatalf("err = %v, want exactly ErrNotFound", err)
	}
	if !reflect.DeepEqual(got, ReportedMessage{}) {
		t.Errorf("a refusal returned evidence: %+v", got)
	}
}
