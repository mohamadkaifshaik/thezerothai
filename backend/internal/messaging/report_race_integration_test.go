//go:build integration

package messaging

// Races around a moderator takedown (ADR-0027 D12, plan W7-12), forced at the exact point the race would happen with the
// repo's test hooks: a Send that commits between two runs of the takedown transaction, and a takedown that commits while the
// account eraser's tombstone page holds its query result.
//
// A competing write cannot commit INSIDE a run: the emulator, like Firestore, holds the read locks of a transaction, and a
// competing write times out with "Transaction lock timeout" until the transaction ends. What the transaction must survive is
// the contention retry: its first run reads, is aborted, a send commits, and the next run must read the new state. The test
// forces exactly that (the first run returns an Aborted error, which the SDK retries) and commits the send between the runs.

import (
	"context"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// A Send that makes another message the conversation's last one commits after the takedown's first run read the previews and
// before its rerun. The rerun must read the new state: the "removed" preview must not be put over the new message, and the
// rerun's writes are the message and the conversation only (no preview).
func TestTakedown_SendBetweenRunsKeepsThePreviewOfTheNewMessage(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)

	e.repo.hooks = &raceHooks{
		afterTakedownReads: func(run int) error {
			if run == 1 {
				return status.Error(codes.Aborted, "forced by the test: the first run read the previews")
			}
			return nil
		},
		beforeTakedownRun: func(run int) {
			if run == 2 { // the first run was rolled back and its locks are released: a send commits now
				e.tick(time.Second)
				e.must(alice, toUser(skey(3), bob, "third, sent between the runs"))
			}
		},
	}

	ctx, c := budget.WithCounter(context.Background())
	res, err := e.repo.TakedownMessage(ctx, convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	if runs := e.repo.hooks.takedownRuns; runs != 2 {
		t.Fatalf("the takedown body ran %d times, want 2 (an aborted run and its rerun)", runs)
	}
	if res.Entries != 0 || !res.Wrote {
		t.Errorf("result = %+v, want the message and the conversation written and no preview rewritten", res)
	}
	// Writes are counted for the committing run only: the message and the conversation.
	if c.Writes() != 2 {
		t.Errorf("writes = %d, want 2 (the committing rerun)", c.Writes())
	}

	msgs := e.msgs(convID)
	var third string
	for id, m := range msgs {
		if m.Text == "third, sent between the runs" {
			third = id
		}
	}
	if third == "" {
		t.Fatalf("the racing send was lost: %+v", msgs)
	}
	if msgs[m2].State != msgRemoved || msgs[m2].Text != "" || msgs[third].State != msgVisible {
		t.Errorf("messages = %+v", msgs)
	}
	for _, uid := range []string{alice, bob} {
		ent, ok := e.entry(uid, dmInboxCollection, convID)
		if !ok {
			t.Fatalf("%s lost the inbox entry", uid)
		}
		if ent.Last.MessageID != third || ent.Last.State != msgVisible || ent.Last.Snippet != "third, sent between the runs" {
			t.Errorf("%s's preview = %+v, want the new message untouched", uid, ent.Last)
		}
	}
}

// A takedown that commits after the eraser read its tombstone page must not be overwritten with DELETED_ACCOUNT: the page
// writes carry the documents' LastUpdateTime, the batch fails, and the retry of the step finds the message REMOVED, keeps
// that state and only replaces the sender id.
func TestTombstonePage_RacingATakedownKeepsRemoved(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e) // bob wrote m2

	ran := false
	var takedownErr error
	e.repo.hooks = &raceHooks{afterTombstoneRead: func() {
		if ran {
			return
		}
		ran = true
		_, _, takedownErr = e.takedown(convID, m2, false)
	}}

	_, _, _, err := e.repo.TombstonePage(context.Background(), bob, convID, "")
	if takedownErr != nil {
		t.Fatalf("takedown inside the page: %v", takedownErr)
	}
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("TombstonePage err = %v, want FailedPrecondition (the document changed after the page was read)", err)
	}
	if got := e.msgs(convID)[m2]; got.State != msgRemoved || got.SenderID != bob {
		t.Fatalf("after the failed page: %+v, want REMOVED and still bob's", got)
	}

	// The step's retry re-reads the page.
	last, n, full, err := e.repo.TombstonePage(context.Background(), bob, convID, "")
	if err != nil || n != 1 || full || last != m2 {
		t.Fatalf("retry = %q %d %v, %v", last, n, full, err)
	}
	if got := e.msgs(convID)[m2]; got.State != msgRemoved || got.SenderID != DeletedUID || got.Text != "" {
		t.Errorf("after the retry: %+v, want REMOVED with the sender replaced", got)
	}
}
