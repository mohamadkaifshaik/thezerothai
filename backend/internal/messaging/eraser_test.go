package messaging

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"strings"
	"testing"
)

// memPurger is an in-memory Purger over a few conversations, with the same idempotence the Firestore one has. Pages are
// 2 messages, so tombstoning takes several calls.
type memPurger struct {
	convs  map[string]*memConv // by id
	calls  []string
	failAt int // fail the n-th call (1-based) once; 0 never
	n      int
}

type memConv struct {
	gone       map[string]bool // the user's and the peer's `gone`
	peerGone   bool            // the peer was gone before the user's erasure began
	msgs       []string        // the user's message ids, in order
	tombstoned map[string]bool
	entryGone  bool
	peerEntry  string // "" | "rewritten"
	deleted    bool   // the whole tree is gone
	rewritten  bool   // the uid is replaced in the conversation document (it is no longer listed)
}

const memPage = 2

func (m *memPurger) tick(name string) error {
	m.n++
	m.calls = append(m.calls, name)
	if m.failAt == m.n {
		m.failAt = 0
		return errors.New("injected failure")
	}
	return nil
}

func (m *memPurger) ids() []string {
	var out []string
	for id, c := range m.convs {
		if !c.deleted && !c.rewritten {
			out = append(out, id)
		}
	}
	slices.Sort(out)
	return out
}

func (m *memPurger) NextConversation(_ context.Context, _ string, after string) (string, bool, error) {
	if err := m.tick("next"); err != nil {
		return "", false, err
	}
	for _, id := range m.ids() {
		if id > after {
			return id, true, nil
		}
	}
	return "", false, nil
}

func (m *memPurger) MarkGone(_ context.Context, _ string, id string) (goneResult, error) {
	if err := m.tick("mark"); err != nil {
		return goneResult{}, err
	}
	c, ok := m.convs[id]
	if !ok || c.deleted {
		return goneResult{Missing: true}, nil
	}
	c.gone["me"] = true
	if !c.peerGone {
		c.peerEntry = "rewritten"
	}
	return goneResult{Both: c.peerGone, Entry: entryInbox}, nil
}

func (m *memPurger) TombstonePage(_ context.Context, _ string, id, after string) (string, int, bool, error) {
	if err := m.tick("tombstone"); err != nil {
		return "", 0, false, err
	}
	c := m.convs[id]
	var page []string
	for _, msg := range c.msgs {
		if msg > after && len(page) < memPage {
			page = append(page, msg)
		}
	}
	if len(page) == 0 {
		return after, 0, false, nil
	}
	n := 0
	for _, msg := range page {
		if !c.tombstoned[msg] {
			c.tombstoned[msg] = true
			n++
		}
	}
	return page[len(page)-1], n, len(page) == memPage, nil
}

func (m *memPurger) DeleteEntry(_ context.Context, _ string, id, _ string) error {
	if err := m.tick("entry"); err != nil {
		return err
	}
	m.convs[id].entryGone = true
	return nil
}

func (m *memPurger) DeleteTreePage(_ context.Context, id string) (int, bool, error) {
	if err := m.tick("tree"); err != nil {
		return 0, false, err
	}
	m.convs[id].deleted = true
	return 0, true, nil
}

func (m *memPurger) RewriteConversation(_ context.Context, _ string, id string) error {
	if err := m.tick("rewrite"); err != nil {
		return err
	}
	c := m.convs[id]
	if !c.deleted && c.gone["me"] {
		// The rewrite is only ever the last step: everything before it is done.
		c.rewritten = true
	}
	return nil
}

func newMem() *memPurger {
	mk := func(peerGone bool, msgs ...string) *memConv {
		return &memConv{gone: map[string]bool{}, peerGone: peerGone, msgs: msgs, tombstoned: map[string]bool{}}
	}
	return &memPurger{convs: map[string]*memConv{
		"c1": mk(false, "m1", "m2", "m3", "m4", "m5"), // peer alive: 3 tombstone pages (2+2+1)
		"c2": mk(true, "m6", "m7"),                    // peer gone already: the tree goes
		"c3": mk(false),                               // no own messages
	}}
}

// run drives the eraser to completion and returns the number of calls.
func runEraser(t *testing.T, p *memPurger, killAfter int) (calls int, finalCP Checkpoint) {
	t.Helper()
	e := NewEraser(p, slog.New(slog.NewTextHandler(io.Discard, nil)))
	var cp []byte
	for calls < 200 {
		next, done, err := e.PurgeUser(context.Background(), "me", cp)
		calls++
		if err != nil {
			continue // the lifecycle retries the step with the last good checkpoint
		}
		if killAfter == calls {
			continue // instance death: the work happened, the checkpoint was not saved
		}
		cp = next
		if done {
			var out Checkpoint
			if err := json.Unmarshal(cp, &out); err != nil {
				t.Fatal(err)
			}
			return calls, out
		}
	}
	t.Fatal("the eraser did not finish")
	return 0, Checkpoint{}
}

func (m *memPurger) endState() string {
	var lines []string
	for _, id := range []string{"c1", "c2", "c3"} {
		c := m.convs[id]
		var tomb []string
		for msg := range c.tombstoned {
			tomb = append(tomb, msg)
		}
		slices.Sort(tomb)
		lines = append(lines, fmt.Sprintf("%s gone=%v entryGone=%v peerEntry=%q tree=%v rewritten=%v tomb=%v", id, c.gone["me"], c.entryGone, c.peerEntry, c.deleted, c.rewritten, tomb))
	}
	return strings.Join(lines, "\n")
}

func TestEraser_StateMachine(t *testing.T) {
	p := newMem()
	calls, cp := runEraser(t, p, 0)
	want := strings.Join([]string{
		`c1 gone=true entryGone=true peerEntry="rewritten" tree=false rewritten=true tomb=[m1 m2 m3 m4 m5]`,
		`c2 gone=true entryGone=true peerEntry="" tree=true rewritten=false tomb=[]`,
		`c3 gone=true entryGone=true peerEntry="rewritten" tree=false rewritten=true tomb=[]`,
	}, "\n")
	if got := p.endState(); got != want {
		t.Errorf("end state:\n%s\nwant:\n%s", got, want)
	}
	if cp.Conversations != 3 || cp.Tombstoned != 5 || cp.EntriesDeleted != 3 {
		t.Errorf("counters = %+v, want 3 conversations, 5 tombstones, 3 entries", cp)
	}
	// c1: next, mark, 3 tombstone pages, entry; c2 (peer gone): next, mark, entry, tree; c3: next, mark, tombstone(empty), entry; the end: next.
	wantCalls := []string{"next", "mark", "tombstone", "tombstone", "tombstone", "entry", "rewrite", "next", "mark", "entry", "tree", "next", "mark", "tombstone", "entry", "rewrite", "next"}
	if !slices.Equal(p.calls, wantCalls) {
		t.Errorf("calls = %v\nwant    %v", p.calls, wantCalls)
	}
	// Picking a conversation and marking it gone are one PurgeUser call: 3 marks fold into their "next".
	if want := len(wantCalls) - 3; calls != want {
		t.Errorf("PurgeUser calls = %d, want %d", calls, want)
	}
}

// A crash after any call (the work done, the checkpoint lost) and an error at any call (the work not done) both end in
// the clean run's state: every phase is idempotent.
func TestEraser_ResumesAfterACrashOrErrorAtEveryCall(t *testing.T) {
	clean := newMem()
	total, _ := runEraser(t, clean, 0)
	want := clean.endState()
	for k := 1; k <= total; k++ {
		t.Run(fmt.Sprintf("death after call %02d", k), func(t *testing.T) {
			p := newMem()
			runEraser(t, p, k)
			if got := p.endState(); got != want {
				t.Errorf("end state differs after a death at call %d:\n%s\nwant:\n%s", k, got, want)
			}
		})
		t.Run(fmt.Sprintf("error at call %02d", k), func(t *testing.T) {
			p := newMem()
			p.failAt = k
			runEraser(t, p, 0)
			if got := p.endState(); got != want {
				t.Errorf("end state differs after an error at call %d:\n%s\nwant:\n%s", k, got, want)
			}
		})
	}
}

// The checkpoint is ids and counters only: no uid, no text, and an unreadable one is an error, not a restart.
func TestEraser_CheckpointHoldsNoUIDAndRejectsGarbage(t *testing.T) {
	p := newMem()
	e := NewEraser(p, nil)
	next, _, err := e.PurgeUser(context.Background(), "uid-secret-user", nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(next), "uid-secret-user") {
		t.Errorf("checkpoint %s names the uid", next)
	}
	if _, _, err := e.PurgeUser(context.Background(), "me", []byte("{not json")); err == nil {
		t.Error("a corrupt checkpoint must fail the step, not restart it")
	}
}

// A conversation the peer's eraser deleted between the cursor query and the transaction is skipped, not an error.
func TestEraser_SkipsAMissingConversation(t *testing.T) {
	p := newMem()
	p.convs["c1"].deleted = true
	p.convs["c2"].deleted = true
	p.convs["c3"].deleted = true
	if _, cp := runEraser(t, p, 0); cp.Conversations != 0 {
		t.Errorf("conversations = %d, want 0", cp.Conversations)
	}
}
