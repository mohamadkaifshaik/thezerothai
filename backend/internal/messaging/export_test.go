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

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

type fakeExportSource struct {
	convs      []ExportConv
	msgs       map[string][]ExportMsg // newest first
	pages      int
	failOn     string
	entries    map[string]EntryDoc
	entryCalls int
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
	if err := NewExporter(src, h, &fakeSocial{}).ExportUser(context.Background(), "uid-me", &buf); err != nil {
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
		if err := NewExporter(src, &fakeHandles{}, &fakeSocial{}).ExportUser(context.Background(), "me", &buf); err == nil {
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
		if err := NewExporter(src, &fakeHandles{}, &fakeSocial{}).ExportUser(context.Background(), "me", w); err == nil {
			t.Errorf("failing write %d went unnoticed", n)
		}
	}
}

// GetEntry makes fakeExportSource an ExportSource: the entries are keyed by conversation id, calls counts the reads.
func (f *fakeExportSource) GetEntry(_ context.Context, _, convID, _ string) (EntryDoc, bool, error) {
	f.entryCalls++
	if f.failOn == "entry" {
		return EntryDoc{}, false, errors.New("entry down")
	}
	e, ok := f.entries[convID]
	return e, ok, nil
}

func entryOf(peer, handle string) EntryDoc {
	return EntryDoc{PeerID: peer, Peer: PeerDoc{Handle: handle}}
}

// W7-30 (security review M-2): a peer who blocked the caller (or whom the caller blocked, or every peer on overflow) is named by
// the handle frozen on the caller's entry, never the live directory handle, and is never looked up. A missing entry, an entry
// naming another peer, and an erased peer give no handle. Unblocked peers keep the live handle.
func TestExport_BlockedPeerUsesFrozenHandle(t *testing.T) {
	live := map[string]string{"p-by": "renamed-by", "p-blocked": "renamed-blocked", "p-nomatch": "live-nomatch", "p-noentry": "live-noentry", "p-free": "live-free"}
	cases := []struct {
		name string
		snap graph.Snapshot
		want map[string]string // peer -> handle in the export
		look []string          // peers the directory may be asked about
	}{
		{"none blocked", graph.Snapshot{}, map[string]string{"p-by": "renamed-by", "p-blocked": "renamed-blocked", "p-nomatch": "live-nomatch", "p-noentry": "live-noentry", "p-free": "live-free"}, []string{"p-by", "p-blocked", "p-nomatch", "p-noentry", "p-free"}},
		{"blocked either way", graph.Snapshot{BlockedBy: map[string]bool{"p-by": true, "p-nomatch": true, "p-noentry": true}, Blocked: map[string]bool{"p-blocked": true}},
			map[string]string{"p-by": "frozen-by", "p-blocked": "frozen-blocked", "p-nomatch": "", "p-noentry": "", "p-free": "live-free"}, []string{"p-free"}},
		{"overflow blocks every peer", graph.Snapshot{BlockedByOverflow: true},
			map[string]string{"p-by": "frozen-by", "p-blocked": "frozen-blocked", "p-nomatch": "", "p-noentry": "", "p-free": "frozen-free"}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			src := &fakeExportSource{
				convs: []ExportConv{
					{ID: "c-by", PeerUID: "p-by", State: stateAccepted, CreatedAt: ts(1)},
					{ID: "c-blocked", PeerUID: "p-blocked", State: stateAccepted, CreatedAt: ts(2)},
					{ID: "c-nomatch", PeerUID: "p-nomatch", State: stateAccepted, CreatedAt: ts(3)},
					{ID: "c-noentry", PeerUID: "p-noentry", State: stateAccepted, CreatedAt: ts(4)},
					{ID: "c-free", PeerUID: "p-free", State: stateAccepted, CreatedAt: ts(5)},
				},
				entries: map[string]EntryDoc{
					"c-by": entryOf("p-by", "frozen-by"), "c-blocked": entryOf("p-blocked", "frozen-blocked"),
					"c-nomatch": entryOf(DeletedUID, "frozen-nomatch"), "c-free": entryOf("p-free", "frozen-free"),
				},
			}
			h := &fakeHandles{byUID: live}
			var buf bytes.Buffer
			social := &fakeSocial{snaps: map[string]graph.Snapshot{"uid-me": tc.snap}}
			if err := NewExporter(src, h, social).ExportUser(context.Background(), "uid-me", &buf); err != nil {
				t.Fatal(err)
			}
			var v struct {
				Conversations []struct {
					PeerHandle string `json:"peerHandle"`
					CreatedAt  string `json:"createdAt"`
				} `json:"conversations"`
			}
			if err := json.Unmarshal(buf.Bytes(), &v); err != nil {
				t.Fatal(err)
			}
			byPeer := map[string]string{}
			for i, c := range v.Conversations { // newest first: p-free, p-noentry, p-nomatch, p-blocked, p-by
				byPeer[[]string{"p-free", "p-noentry", "p-nomatch", "p-blocked", "p-by"}[i]] = c.PeerHandle
			}
			for peer, want := range tc.want {
				if byPeer[peer] != want {
					t.Errorf("%s: handle %q, want %q", peer, byPeer[peer], want)
				}
			}
			asked := map[string]bool{}
			for _, call := range h.calls {
				for _, u := range call {
					asked[u] = true
				}
			}
			allowed := map[string]bool{}
			for _, u := range tc.look {
				allowed[u] = true
			}
			for u := range asked {
				if !allowed[u] {
					t.Errorf("the directory was asked about %s, a blocked peer", u)
				}
			}
			if social.calls != 1 {
				t.Errorf("graph reads = %d, want 1", social.calls)
			}
			wantEntries := len(tc.want) - len(tc.look)
			if src.entryCalls != wantEntries {
				t.Errorf("entry reads = %d, want %d (one per blocked conversation)", src.entryCalls, wantEntries)
			}
			if strings.Contains(buf.String(), "renamed-") && tc.name != "none blocked" {
				t.Errorf("a live handle of a blocked peer is in the export: %s", buf.String())
			}
		})
	}
}

// No peer to decide about: no graph read. A graph or entry error fails the section (fail closed).
func TestExport_FrozenPeerReadsAndErrors(t *testing.T) {
	social := &fakeSocial{}
	var buf bytes.Buffer
	gone := &fakeExportSource{convs: []ExportConv{{ID: "c", PeerUID: "p", PeerGone: true, CreatedAt: ts(1)}}}
	if err := NewExporter(gone, &fakeHandles{}, social).ExportUser(context.Background(), "me", &buf); err != nil || social.calls != 0 {
		t.Errorf("only an erased peer: err %v, graph reads %d, want nil and 0", err, social.calls)
	}
	if err := NewExporter(&fakeExportSource{}, &fakeHandles{}, social).ExportUser(context.Background(), "me", &buf); err != nil || social.calls != 0 {
		t.Errorf("no conversation: err %v, graph reads %d, want nil and 0", err, social.calls)
	}
	one := &fakeExportSource{convs: []ExportConv{{ID: "c", PeerUID: "p", CreatedAt: ts(1)}}}
	if err := NewExporter(one, &fakeHandles{}, &fakeSocial{err: errors.New("graph down")}).ExportUser(context.Background(), "me", &buf); err == nil {
		t.Error("a graph error must fail the section")
	}
	blocked := &fakeSocial{snaps: map[string]graph.Snapshot{"me": {BlockedBy: map[string]bool{"p": true}}}}
	failing := &fakeExportSource{failOn: "entry", convs: one.convs}
	if err := NewExporter(failing, &fakeHandles{}, blocked).ExportUser(context.Background(), "me", &buf); err == nil {
		t.Error("an entry error must fail the section")
	}
}
