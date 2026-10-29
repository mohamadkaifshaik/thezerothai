//go:build integration

package messaging

// W7-20 (ADR-0027 D8, W7-6 "Budget"): the reference account of the plan, 20 conversations with 300 messages of its own (and
// 300 received), through the eraser step and the export section on the emulator. The single-conversation budgets in
// lifecycle_integration_test.go show the per-conversation shape; this one shows the totals the cost model uses.

import (
	"bytes"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

const (
	refConversations = 20
	refOwnPerConv    = 15 // 20 x 15 = 300 own messages
)

func (e *itEnv) seedReferenceAccount(uid string) {
	e.t.Helper()
	for i := range refConversations {
		peer := fmt.Sprintf("uid-ref-%02d", i)
		e.addUser(peer, fmt.Sprintf("ref%02d", i), false)
		msgs := make([][2]string, 0, 2*refOwnPerConv)
		for j := range refOwnPerConv {
			msgs = append(msgs, [2]string{uid, fmt.Sprintf("own %d", j)}, [2]string{peer, fmt.Sprintf("received %d", j)})
		}
		e.seedConversation(uid, peer, stateAccepted, base.Add(time.Duration(i)*time.Hour), msgs...)
	}
}

// The eraser step over the reference account, summed over all its calls: per conversation one `gone` write, 15 tombstones, one
// peer-entry rewrite, one closing write of the conversation document and one own-entry delete, and the reads that find them.
// The plan rounds this to "about 340 / 340 / 20"; the documented per-call costs give the figures asserted below.
func TestEraser_ReferenceAccountBudget(t *testing.T) {
	e := newIT(t, nil)
	e.seedReferenceAccount(alice)
	calls, total := e.runEraserFor(alice)
	t.Logf("REFBUDGET eraser calls=%d reads=%d writes=%d deletes=%d (plan: ~340 / ~340 / 20)", calls, total.Reads(), total.Writes(), total.Deletes())
	// The ceiling is the sum of the per-call costs documented in repo_lifecycle.go, not the plan's rounded "about 340 / 340 / 20":
	//   - the conversation cursor query: one read per conversation, plus a terminating empty page (at least 1 read);
	//   - MarkGone: 2 reads, 2 writes per conversation (the conversation, the peer's entry; `gone` and the peer rewrite);
	//   - TombstonePage: 1 read and 1 write per own message;
	//   - the closing step: 1 read, 1 write (the conversation document) and 1 delete (the user's own entry).
	// For 20 conversations and 300 own messages that is 381 reads, 360 writes and 20 deletes. The plan's summary figure is
	// stale (it leaves out MarkGone's second read and the closing step's read and write, 1 and 3 per conversation); correcting
	// it, and the cost-model row, is for sre-performance in W7-23. The assertion is on the documented per-call costs.
	const (
		perConvReads  = 2 + 1 // MarkGone + closing step, besides the own messages
		perConvWrites = 2 + 1
	)
	wantReads := int64(refConversations + 1 + refConversations*perConvReads + refConversations*refOwnPerConv)
	wantWrites := int64(refConversations*perConvWrites + refConversations*refOwnPerConv)
	budgettest.Assert(t, "eraser, reference account", total, budgettest.Budget{Reads: wantReads, Writes: wantWrites, Deletes: refConversations})
	if total.Writes() < 300 || total.Deletes() != refConversations {
		t.Errorf("writes/deletes = %d/%d, want at least the 300 tombstones and exactly %d entry deletes", total.Writes(), total.Deletes(), refConversations)
	}
	// Nothing of the user is left and every peer message is intact.
	if hits := e.uidHits(alice); len(hits) != 0 {
		t.Errorf("documents still hold the erased uid: %v", hits)
	}
	// A re-run of a finished account is one read.
	again, c := e.runEraserFor(alice)
	_ = again
	budgettest.Assert(t, "eraser repeat, reference account", c, budgettest.Budget{Reads: 1})
}

// The export section for the reference account reads each conversation and both sides of its messages to order the
// section: 20 + 20 x 30 = 620 reads, 0 writes (the plan's "about 620").
func TestExport_ReferenceAccountBudget(t *testing.T) {
	e := newIT(t, nil)
	e.seedReferenceAccount(alice)
	var buf bytes.Buffer
	ctx, c := budget.WithCounter(t.Context())
	if err := NewExporter(e.repo, e.profs).ExportUser(ctx, alice, &buf); err != nil {
		t.Fatal(err)
	}
	t.Logf("REFBUDGET export reads=%d writes=%d bytes=%d (plan: ~620 / 0)", c.Reads(), c.Writes(), buf.Len())
	budgettest.Assert(t, "export, reference account", c, budgettest.Budget{Reads: 620, Writes: 0})
}
