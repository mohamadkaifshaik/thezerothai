//go:build integration

package messaging

// Races around a moderator takedown (ADR-0027 D12, plan W7-12), forced at the exact point the race would happen with the
// repo's test hooks: a Send that commits while the takedown transaction holds its reads, and a takedown that commits
// while the account eraser's tombstone page holds its query result.

import (
	"context"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// A Send that makes another message the conversation's last one commits between the takedown's reads and its writes. The
// takedown must not put the "removed" preview over the new message: Firestore aborts the transaction on the entries it read,
// the body re-runs, sees `last.messageId` is no longer the taken-down message and rewrites nothing in the inbox.
func TestTakedown_RacingASendThatBecomesTheLastMessageKeepsThePreview(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)

	var once sync.Once
	sent := make(chan struct{})
	e.repo.hooks = &raceHooks{afterTakedownReads: func() {
		once.Do(func() {
			e.tick(time.Second)
			go func() {
				defer close(sent)
				if _, _, err := e.send(alice, toUser(skey(3), bob, "third, sent during the takedown")); err != nil {
					t.Errorf("racing send: %v", err)
				}
			}()
			// If the emulator holds the send back until the takedown commits, do not wait for it here.
			select {
			case <-sent:
				t.Log("the send committed inside the takedown transaction: the takedown re-ran")
			case <-time.After(2 * time.Second):
				t.Log("the send waited for the takedown to commit")
			}
		})
	}}

	res, _, err := e.takedown(convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	<-sent // the send finishes, whichever side went first
	t.Logf("takedown result: %+v", res)

	msgs := e.msgs(convID)
	var third string
	for id, m := range msgs {
		if m.Text == "third, sent during the takedown" {
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
		if ent.Last.MessageID != third || ent.Last.State != msgVisible || ent.Last.Snippet != "third, sent during the takedown" {
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

	var once sync.Once
	var takedownErr error
	e.repo.hooks = &raceHooks{afterTombstoneRead: func() {
		once.Do(func() { _, _, takedownErr = e.takedown(convID, m2, false) })
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
