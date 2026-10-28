package messaging

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

type fakeExportSource struct {
	convs  []ExportConv
	msgs   map[string][]ExportMsg // newest first
	pages  int
	failOn string
}

func (f *fakeExportSource) ExportConversations(context.Context, string) ([]ExportConv, error) {
	if f.failOn == "convs" {
		return nil, errors.New("convs down")
	}
	return f.convs, nil
}

func (f *fakeExportSource) ExportMessages(_ context.Context, _ string, id string, after *ExportMsg) ([]ExportMsg, error) {
	f.pages++
	if f.failOn == "msgs" {
		return nil, errors.New("msgs down")
	}
	all := f.msgs[id]
	start := 0
	if after != nil {
		for i, m := range all {
			if m.ID == after.ID {
				start = i + 1
			}
		}
	}
	return all[start:min(start+lifecyclePage, len(all))], nil
}

type fakeHandles struct {
	byUID map[string]string
	calls [][]string
}

func (f *fakeHandles) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	f.calls = append(f.calls, append([]string(nil), uids...))
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if h, ok := f.byUID[u]; ok {
			out[u] = identity.Profile{UserID: u, Handle: h}
		}
	}
	return out, nil
}

func ts(sec int64) time.Time { return time.Unix(1_700_000_000+sec, 0).UTC() }

func exportOf(t *testing.T, src ExportSource, h HandleSource) (string, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if err := NewExporter(src, h).ExportUser(context.Background(), "uid-me", &buf); err != nil {
		t.Fatal(err)
	}
	var v map[string]any
	if err := json.Unmarshal(buf.Bytes(), &v); err != nil {
		t.Fatalf("the section is not one JSON value: %v\n%s", err, buf.String())
	}
	return buf.String(), v
}

// F5: own messages in full, received ones as a time and "received", the peer by handle at export time, never by uid,
// conversations newest first (by creation), messages newest first.
func TestExport_OwnTextReceivedAsTimeOnlyNoPeerUID(t *testing.T) {
	src := &fakeExportSource{
		convs: []ExportConv{
			{ID: "c-old", PeerUID: "uid-peer-1", State: stateAccepted, CreatedAt: ts(10)},
			{ID: "c-new", PeerUID: "uid-peer-2", State: stateRequest, CreatedAt: ts(50), ClearedAt: ts(60)},
			{ID: "c-dead", PeerUID: "uid-peer-3", State: stateAccepted, CreatedAt: ts(30), PeerGone: true},
		},
		msgs: map[string][]ExportMsg{
			"c-old":  {{ID: "m3", FromSelf: false, Text: "THEIR WORDS", State: msgVisible, CreatedAt: ts(22)}, {ID: "m2", FromSelf: true, Text: "my words", State: msgVisible, CreatedAt: ts(21)}},
			"c-new":  {{ID: "m4", FromSelf: true, Text: "hello", State: msgVisible, CreatedAt: ts(51)}},
			"c-dead": {{ID: "m5", FromSelf: false, Text: "", State: msgDeletedAccount, CreatedAt: ts(31)}},
		},
	}
	raw, v := exportOf(t, src, &fakeHandles{byUID: map[string]string{"uid-peer-1": "alice", "uid-peer-2": "bob"}})
	for _, forbidden := range []string{"uid-peer", "THEIR WORDS", "uid-me", "c-old", "m2"} {
		if strings.Contains(raw, forbidden) {
			t.Errorf("the section contains %q:\n%s", forbidden, raw)
		}
	}
	convs := v["conversations"].([]any)
	var order []string
	for _, c := range convs {
		order = append(order, fmt.Sprint(c.(map[string]any)["peerHandle"]))
	}
	if got, want := strings.Join(order, ","), "bob,,alice"; got != want {
		t.Errorf("conversation order = %q, want %q (newest first; the deleted peer has no handle)", got, want)
	}
	bob := convs[0].(map[string]any)
	if bob["state"] != stateRequest || bob["clearedAt"] == nil {
		t.Errorf("bob's conversation = %v, want state REQUEST and a clearedAt", bob)
	}
	dead := convs[1].(map[string]any)
	if dead["peerDeleted"] != true {
		t.Errorf("a deleted peer must be flagged: %v", dead)
	}
	alice := convs[2].(map[string]any)["messages"].([]any)
	recv, sent := alice[0].(map[string]any), alice[1].(map[string]any)
	if recv["direction"] != "received" || recv["text"] != nil || recv["at"] == nil {
		t.Errorf("a received message = %v, want a time and 'received' only", recv)
	}
	if sent["direction"] != "sent" || sent["text"] != "my words" {
		t.Errorf("an own message = %v, want its full text", sent)
	}
}

// An empty account exports a valid empty section with no lookup.
func TestExport_Empty(t *testing.T) {
	h := &fakeHandles{}
	raw, v := exportOf(t, &fakeExportSource{}, h)
	if len(v["conversations"].([]any)) != 0 || len(h.calls) != 0 {
		t.Errorf("section = %s, directory calls %v", raw, h.calls)
	}
}

// More than 50 peers take several directory calls of at most 50; more than 500 messages take several pages.
func TestExport_ChunksPeerLookupsAndMessagePages(t *testing.T) {
	src := &fakeExportSource{msgs: map[string][]ExportMsg{}}
	h := &fakeHandles{byUID: map[string]string{}}
	for i := range 120 {
		uid := fmt.Sprintf("uid-peer-%03d", i)
		id := fmt.Sprintf("conv-%03d", i)
		src.convs = append(src.convs, ExportConv{ID: id, PeerUID: uid, State: stateAccepted, CreatedAt: ts(int64(i))})
		h.byUID[uid] = fmt.Sprintf("h%03d", i)
	}
	for i := range 1_100 { // one conversation with 1,100 messages: 3 pages
		src.msgs["conv-000"] = append(src.msgs["conv-000"], ExportMsg{ID: fmt.Sprintf("m%04d", i), FromSelf: i%2 == 0, Text: "x", State: msgVisible, CreatedAt: ts(int64(2000 - i))})
	}
	_, v := exportOf(t, src, h)
	if len(h.calls) != 3 || len(h.calls[0]) != 50 || len(h.calls[1]) != 50 || len(h.calls[2]) != 20 {
		t.Errorf("directory calls = %d (sizes %v), want 3 calls of 50, 50 and 20", len(h.calls), func() []int {
			var n []int
			for _, c := range h.calls {
				n = append(n, len(c))
			}
			return n
		}())
	}
	var found int
	for _, c := range v["conversations"].([]any) {
		if m := c.(map[string]any)["messages"].([]any); len(m) == 1_100 {
			found++
		}
	}
	if found != 1 {
		t.Errorf("the 1,100-message conversation was not exported whole")
	}
	if want := 120 + 2; src.pages != want { // one page per conversation, plus 2 extra for the long one
		t.Errorf("message pages = %d, want %d", src.pages, want)
	}
}

func TestExport_ErrorsPropagate(t *testing.T) {
	for _, on := range []string{"convs", "msgs"} {
		src := &fakeExportSource{failOn: on, convs: []ExportConv{{ID: "c", PeerUID: "p", CreatedAt: ts(1)}}}
		var buf bytes.Buffer
		if err := NewExporter(src, &fakeHandles{}).ExportUser(context.Background(), "me", &buf); err == nil {
			t.Errorf("a failing %s read must fail the section", on)
		}
	}
}

// failingWriter fails on the n-th Write.
type failingWriter struct{ n, calls int }

func (w *failingWriter) Write(p []byte) (int, error) {
	w.calls++
	if w.calls >= w.n {
		return 0, errors.New("disk full")
	}
	return len(p), nil
}

// A write failure anywhere in the section (the opening, a separator, a conversation, the closing) fails the export.
func TestExport_WriteErrorsPropagate(t *testing.T) {
	src := &fakeExportSource{
		convs: []ExportConv{{ID: "a", PeerUID: "p1", CreatedAt: ts(2)}, {ID: "b", PeerUID: "p2", CreatedAt: ts(1)}},
		msgs:  map[string][]ExportMsg{"a": {{ID: "m1", FromSelf: true, Text: "x", State: msgVisible, CreatedAt: ts(3)}}},
	}
	for n := 1; n <= 5; n++ { // the opening, two conversations with the separator between, the closing
		w := &failingWriter{n: n}
		if err := NewExporter(src, &fakeHandles{}).ExportUser(context.Background(), "me", w); err == nil {
			t.Errorf("failing write %d went unnoticed", n)
		}
	}
}
