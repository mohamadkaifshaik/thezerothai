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
	convs    map[string]*memConv // by id
	welcomes int                 // documents under the user's dmWelcomes
	calls    []string
	failAt   int // fail the n-th call (1-based) once; 0 never
	n        int
}

type memConv struct {
	gone       map[string]bool // the user's and the peer's `gone`
	peerGone   bool            // the peer was gone before the user's erasure began
	msgs       []string        // the user's message ids, in order
	tombstoned map[string]bool
	commits    int // the user's commit records not yet rewritten to DeletedUID
	rewrittenC int // the user's commit records rewritten
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
	c := m.convs[id]
	c.deleted, c.commits = true, 0
	return 0, true, nil
}

func (m *memPurger) RewriteCommitsPage(_ context.Context, _ string, id string) (int, error) {
	if err := m.tick("commits"); err != nil {
		return 0, err
	}
	c := m.convs[id]
	n := min(c.commits, memPage)
	c.commits -= n
	c.rewrittenC += n
	return n, nil
}

func (m *memPurger) RewriteConversation(_ context.Context, _ string, id string) error {
	if err := m.tick("rewrite"); err != nil {
		return err
	}
	c := m.convs[id]
	if !c.deleted && c.gone["me"] && c.commits == 0 {
		// The rewrite is only ever the last step: everything before it (the commit records included) is done.
		c.rewritten = true
	}
	return nil
}

func (m *memPurger) DeleteWelcomesPage(context.Context, string) (int, bool, error) {
	if err := m.tick("welcomes"); err != nil {
		return 0, false, err
	}
	for _, c := range m.convs {
		if !c.gone["me"] && !c.deleted {
			// The welcomes phase runs only once every conversation is marked gone.
			return 0, false, errors.New("welcomes phase before every conversation was marked gone")
		}
	}
	n := min(m.welcomes, memPage)
	m.welcomes -= n
	return n, n == memPage, nil
}

func newMem() *memPurger {
	mk := func(peerGone bool, commits int, msgs ...string) *memConv {
		return &memConv{gone: map[string]bool{}, peerGone: peerGone, msgs: msgs, tombstoned: map[string]bool{}, commits: commits}
	}
	return &memPurger{welcomes: 3, convs: map[string]*memConv{
		"c1": mk(false, 3, "m1", "m2", "m3", "m4", "m5"), // peer alive: 3 tombstone pages (2+2+1), 2 commit pages (2+1)
		"c2": mk(true, 2, "m6", "m7"),                    // peer gone already: the tree goes, commits with it
		"c3": mk(false, 0),                               // no own messages, no commits
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
		lines = append(lines, fmt.Sprintf("%s gone=%v entryGone=%v peerEntry=%q tree=%v rewritten=%v tomb=%v commitsLeft=%d", id, c.gone["me"], c.entryGone, c.peerEntry, c.deleted, c.rewritten, tomb, c.commits))
	}
	lines = append(lines, fmt.Sprintf("welcomes=%d", m.welcomes))
	return strings.Join(lines, "\n")
}

func TestEraser_StateMachine(t *testing.T) {
	p := newMem()
	calls, cp := runEraser(t, p, 0)
	want := strings.Join([]string{
		`c1 gone=true entryGone=true peerEntry="rewritten" tree=false rewritten=true tomb=[m1 m2 m3 m4 m5] commitsLeft=0`,
		`c2 gone=true entryGone=true peerEntry="" tree=true rewritten=false tomb=[] commitsLeft=0`,
		`c3 gone=true entryGone=true peerEntry="rewritten" tree=false rewritten=true tomb=[] commitsLeft=0`,
		`welcomes=0`,
	}, "\n")
	if got := p.endState(); got != want {
		t.Errorf("end state:\n%s\nwant:\n%s", got, want)
	}
	if cp.Conversations != 3 || cp.Tombstoned != 5 || cp.EntriesDeleted != 3 || cp.CommitsRewritten != 3 || cp.WelcomesDeleted != 3 {
		t.Errorf("counters = %+v, want 3 conversations, 5 tombstones, 3 entries, 3 commit records, 3 welcomes", cp)
	}
	if p.convs["c1"].rewrittenC != 3 {
		t.Errorf("c1 commit records rewritten = %d, want 3", p.convs["c1"].rewrittenC)
	}
	// c1: next, mark, 3 tombstone pages, entry, 2 commit pages and the empty one, rewrite; c2 (peer gone): next, mark,
	// entry, tree; c3: next, mark, tombstone(empty), entry, commits(empty), rewrite; the end: next, then the welcomes in
	// pages (2 + 1).
	wantCalls := []string{
		"next", "mark", "tombstone", "tombstone", "tombstone", "entry", "commits", "commits", "commits", "rewrite",
		"next", "mark", "entry", "tree",
		"next", "mark", "tombstone", "entry", "commits", "rewrite",
		"next", "welcomes", "welcomes",
	}
	if !slices.Equal(p.calls, wantCalls) {
		t.Errorf("calls = %v\nwant    %v", p.calls, wantCalls)
	}
	// One PurgeUser call each, except: picking a conversation and marking it gone (3 marks fold into their "next"), and an
	// empty commit page followed by the conversation rewrite (2 folds).
	if want := len(wantCalls) - 3 - 2; calls != want {
		t.Errorf("PurgeUser calls = %d, want %d", calls, want)
	}
}

// A checkpoint written by the build before the E2EE phases (no commit or welcome counters, phase names as they were)
// resumes under this one to the same end state: the commit records' rewrite runs inside the existing "rewrite" phase and
// their delete inside "tree", and the welcomes phase follows the last conversation.
func TestEraser_OldCheckpointsResume(t *testing.T) {
	clean := newMem()
	runEraser(t, clean, 0)
	want := clean.endState()
	for _, tt := range []struct {
		name string
		cp   string
		prep func(p *memPurger) // the work the old build had done before writing cp
	}{
		{"before the first conversation", `{}`, func(*memPurger) {}},
		{"mid tombstone", `{"conv":"c1","phase":"tombstone","msg":"m2","entry":"inbox","conversations":1,"tombstoned":2}`, func(p *memPurger) {
			p.convs["c1"].gone["me"], p.convs["c1"].peerEntry = true, "rewritten"
			p.convs["c1"].tombstoned["m1"], p.convs["c1"].tombstoned["m2"] = true, true
		}},
		{"at finish", `{"conv":"c1","phase":"finish","msg":"m5","entry":"inbox","conversations":1,"tombstoned":5}`, func(p *memPurger) {
			c := p.convs["c1"]
			c.gone["me"], c.peerEntry = true, "rewritten"
			for _, m := range c.msgs {
				c.tombstoned[m] = true
			}
		}},
		{"at rewrite", `{"conv":"c1","phase":"rewrite","msg":"m5","entry":"inbox","conversations":1,"tombstoned":5,"entriesDeleted":1}`, func(p *memPurger) {
			c := p.convs["c1"]
			c.gone["me"], c.peerEntry, c.entryGone = true, "rewritten", true
			for _, m := range c.msgs {
				c.tombstoned[m] = true
			}
		}},
		{"at tree", `{"after":"c1","conv":"c2","phase":"tree","both":true,"entry":"inbox","conversations":2,"tombstoned":5,"entriesDeleted":2}`, func(p *memPurger) {
			c1 := p.convs["c1"]
			c1.gone["me"], c1.peerEntry, c1.entryGone, c1.rewritten = true, "rewritten", true, true
			c1.rewrittenC, c1.commits = c1.commits, 0 // the old build wrote no commit records: none left behind the cursor
			for _, m := range c1.msgs {
				c1.tombstoned[m] = true
			}
			p.convs["c2"].gone["me"], p.convs["c2"].entryGone = true, true
		}},
		{"after the last conversation", `{"after":"c3","conversations":3,"tombstoned":5,"entriesDeleted":3}`, func(p *memPurger) {
			for id, c := range p.convs {
				c.gone["me"], c.entryGone = true, true
				if id == "c2" {
					c.deleted, c.commits = true, 0
					continue
				}
				c.peerEntry, c.rewritten = "rewritten", true
				c.rewrittenC, c.commits = c.commits, 0
				for _, m := range c.msgs {
					c.tombstoned[m] = true
				}
			}
		}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			p := newMem()
			tt.prep(p)
			e := NewEraser(p, slog.New(slog.NewTextHandler(io.Discard, nil)))
			cp := []byte(tt.cp)
			for range 100 {
				next, done, err := e.PurgeUser(context.Background(), "me", cp)
				if err != nil {
					t.Fatalf("resume from %s: %v", tt.cp, err)
				}
				cp = next
				if done {
					break
				}
			}
			if got := p.endState(); got != want {
				t.Errorf("end state after resuming from %s:\n%s\nwant:\n%s", tt.cp, got, want)
			}
		})
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
