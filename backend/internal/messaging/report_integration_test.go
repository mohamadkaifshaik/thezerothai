//go:build integration

package messaging

// Report a message (ADR-0027 D12, plan W7-12) on the real FirestoreRepo: the lookup's reads, the takedown transaction's
// reads and writes, the previews of both participants, and how a takedown and the account eraser leave each other's
// tombstones (a taken-down message stays REMOVED when its sender later deletes the account).

import (
	"context"
	"errors"
	"testing"
	"time"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// twoMessages is a mutual conversation where alice wrote m1 and bob answered with m2 (the last message).
func twoMessages(t *testing.T, e *itEnv) (convID, m1, m2 string) {
	t.Helper()
	e.mutual(alice, bob)
	r1 := e.must(alice, toUser(skey(1), bob, "first, from alice"))
	e.tick(time.Second)
	r2 := e.must(bob, toUser(skey(2), alice, "second, from bob"))
	return ConversationID(alice, bob), r1.GetMessage().GetId(), r2.GetMessage().GetId()
}

func (e *itEnv) takedown(convID, msgID string, dryRun bool) (TakedownResult, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	res, err := e.repo.TakedownMessage(ctx, convID, msgID, dryRun)
	return res, c, err
}

// The lookup reads the conversation and the message through the repo (2 reads, the profile is the directory's); the
// takedown then removes the text, and the thread and the inbox of BOTH participants show it as removed.
func TestReportAndTakedown_BothParticipantsSeeTheMessageRemoved(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)

	ctx, c := budget.WithCounter(context.Background())
	got, err := e.newService().ReportableMessage(ctx, alice, convID, m2)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "ReportableMessage repo reads", c, budgettest.Budget{Reads: 2})
	if got.Text != "second, from bob" || got.SenderUID != bob || got.SenderHandle != "bob" || got.CreatedAt.IsZero() {
		t.Errorf("evidence = %+v", got)
	}

	// m2 is the last message of both conversations' previews: bob's own entry and alice's.
	res, c, err := e.takedown(convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "TakedownMessage", c, budgettest.Budget{Reads: 4, Writes: 3})
	if res.Before != msgVisible || res.After != msgRemoved || res.Entries != 2 || !res.Wrote {
		t.Fatalf("result = %+v", res)
	}
	stored := e.msgs(convID)[m2]
	if stored.State != msgRemoved || stored.Text != "" || stored.RequestHash != "" || stored.SenderID != bob {
		t.Errorf("stored message = %+v, want REMOVED, empty text and digest, sender kept", stored)
	}
	for _, uid := range []string{alice, bob} {
		ent, ok := e.entry(uid, dmInboxCollection, convID)
		if !ok || ent.Last.State != msgRemoved || ent.Last.Snippet != removedSnippet || ent.Last.MessageID != m2 {
			t.Errorf("%s's preview = %+v, %v", uid, ent.Last, ok)
		}
	}
	if ent, _ := e.entry(alice, dmInboxCollection, convID); ent.UnreadCount != 1 {
		t.Errorf("alice's unread count moved to %d, want 1 (a takedown touches the preview only)", ent.UnreadCount)
	}

	// A fresh first page and a fresh inbox, for both participants: REMOVED, empty text. Nothing of the text is left in storage.
	for _, uid := range []string{alice, bob} {
		resp, _ := e.mustListMsgs(e.msgSvc(), uid, &messagingv1.ListMessagesRequest{ConversationId: convID})
		var seen bool
		for _, m := range resp.GetMessages() {
			if m.GetId() == m2 {
				seen = true
				if m.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || m.GetText() != "" {
					t.Errorf("%s sees %v %q, want REMOVED with no text", uid, m.GetState(), m.GetText())
				}
			}
		}
		if !seen {
			t.Errorf("%s's thread lost the tombstone", uid)
		}
		list, _ := e.mustList(e.listSvc(), uid, &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX})
		if len(list.GetConversations()) != 1 {
			t.Fatalf("%s lists %d conversations", uid, len(list.GetConversations()))
		}
		if p := list.GetConversations()[0].GetLastMessage(); p.GetState() != messagingv1.MessageState_MESSAGE_STATE_REMOVED || p.GetSnippet() != "" {
			t.Errorf("%s's preview = %v %q", uid, p.GetState(), p.GetSnippet())
		}
	}

	// The report path no longer finds it, and a repeat takedown is a read-only no-op.
	if _, err := e.newService().ReportableMessage(context.Background(), alice, convID, m2); err != ErrNotFound { //nolint:errorlint // sentinel identity
		t.Errorf("a taken-down message is still reportable: %v", err)
	}
	res, c, err = e.takedown(convID, m2, false)
	if err != nil || res.Wrote || res.Before != msgRemoved || res.After != msgRemoved {
		t.Fatalf("repeat = %+v, %v", res, err)
	}
	budgettest.Assert(t, "TakedownMessage repeat", c, budgettest.Budget{Reads: 1, Writes: 0})
}

// The takedown clears the request digest (as the eraser does), so the sender's retry of the same idempotency key is a
// validation error, never a replay of the removed text and never a second message.
func TestTakedown_RetryOfTheSameKeyIsAValidationErrorAndCreatesNothing(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	if _, _, err := e.takedown(convID, m2, false); err != nil {
		t.Fatal(err)
	}
	_, _, err := e.send(bob, toUser(skey(2), alice, "second, from bob"))
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["field"] != "idempotency_key" {
		t.Fatalf("retry err = %v, want VALIDATION idempotency_key", err)
	}
	if n := len(e.msgs(convID)); n != 2 {
		t.Errorf("%d messages stored, want 2 (no duplicate)", n)
	}
	if got := e.msgs(convID)[m2]; got.State != msgRemoved || got.Text != "" {
		t.Errorf("the retry changed the tombstone: %+v", got)
	}
}

// A message that is not the last one has no preview to rewrite: the message only.
func TestTakedown_NotTheLastMessageLeavesThePreviewsAlone(t *testing.T) {
	e := newIT(t, nil)
	convID, m1, m2 := twoMessages(t, e)
	res, c, err := e.takedown(convID, m1, false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "TakedownMessage not last", c, budgettest.Budget{Reads: 4, Writes: 1})
	if res.Entries != 0 || !res.Wrote {
		t.Errorf("result = %+v", res)
	}
	if got := e.msgs(convID); got[m1].State != msgRemoved || got[m1].Text != "" || got[m2].State != msgVisible || got[m2].Text != "second, from bob" {
		t.Errorf("messages = %+v", got)
	}
	for _, uid := range []string{alice, bob} {
		if ent, _ := e.entry(uid, dmInboxCollection, convID); ent.Last.State != msgVisible || ent.Last.Snippet != "second, from bob" {
			t.Errorf("%s's preview changed: %+v", uid, ent.Last)
		}
	}
}

func TestTakedown_DryRunReadsTheSameAndWritesNothing(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	res, c, err := e.takedown(convID, m2, true)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "TakedownMessage dry run", c, budgettest.Budget{Reads: 4, Writes: 0})
	if res.Wrote || res.Entries != 2 || res.Before != msgVisible || res.After != msgRemoved {
		t.Errorf("result = %+v, want the plan: 2 previews, nothing written", res)
	}
	if got := e.msgs(convID)[m2]; got.State != msgVisible || got.Text == "" {
		t.Errorf("a dry run changed the message: %+v", got)
	}
}

// A request conversation: the recipient's entry is in dmRequests, the sender's in dmInbox; both previews are rewritten.
func TestTakedown_RequestConversationRewritesBothFolders(t *testing.T) {
	e := newIT(t, nil)
	r := e.must(alice, toUser(skey(1), bob, "request text"))
	convID := ConversationID(alice, bob)
	if _, ok := e.entry(bob, dmRequestsCollection, convID); !ok {
		t.Fatal("setup: the recipient's entry is not in dmRequests")
	}
	res, _, err := e.takedown(convID, r.GetMessage().GetId(), false)
	if err != nil || res.Entries != 2 {
		t.Fatalf("result = %+v, %v", res, err)
	}
	for uid, folder := range map[string]string{alice: dmInboxCollection, bob: dmRequestsCollection} {
		if ent, _ := e.entry(uid, folder, convID); ent.Last.State != msgRemoved || ent.Last.Snippet != removedSnippet {
			t.Errorf("%s's %s preview = %+v", uid, folder, ent.Last)
		}
	}
}

// A participant who deleted the conversation for themselves has no entry: skipped, not created, and the takedown still commits.
func TestTakedown_SkipsAnEntryThatIsGone(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	if _, err := e.fs.Collection("users").Doc(alice).Collection(dmInboxCollection).Doc(convID).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	res, c, err := e.takedown(convID, m2, false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "TakedownMessage one entry gone", c, budgettest.Budget{Reads: 4, Writes: 2})
	if res.Entries != 1 || !res.Wrote {
		t.Errorf("result = %+v", res)
	}
	if _, ok := e.entry(alice, dmInboxCollection, convID); ok {
		t.Error("the takedown recreated a deleted entry")
	}
	if ent, _ := e.entry(bob, dmInboxCollection, convID); ent.Last.State != msgRemoved {
		t.Errorf("bob's preview = %+v", ent.Last)
	}
}

func TestTakedown_UnknownMessageAndMissingConversation(t *testing.T) {
	e := newIT(t, nil)
	convID, _, m2 := twoMessages(t, e)
	_, c, err := e.takedown(convID, "00000000000000000000000000000000", false)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown message: %v", err)
	}
	budgettest.Assert(t, "TakedownMessage unknown", c, budgettest.Budget{Reads: 1, Writes: 0})
	if _, err := e.fs.Collection("conversations").Doc(convID).Delete(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.takedown(convID, m2, false); !errors.Is(err, ErrNotFound) {
		t.Fatalf("message without its conversation: %v", err)
	}
	if got := e.msgs(convID)[m2]; got.State != msgVisible {
		t.Errorf("a refused takedown changed the message: %+v", got)
	}
}

// The eraser and a takedown leave each other's tombstones alone: a message taken down and then orphaned by its sender's
// account deletion stays REMOVED (senderId becomes the placeholder), and a message the eraser already tombstoned is not
// taken down again.
func TestTakedownAndEraser_TombstonesSurviveEachOther(t *testing.T) {
	t.Run("takedown, then the sender deletes the account", func(t *testing.T) {
		e := newIT(t, nil)
		convID, _, m2 := twoMessages(t, e)
		if _, _, err := e.takedown(convID, m2, false); err != nil {
			t.Fatal(err)
		}
		e.runEraserFor(bob)
		got := e.msgs(convID)[m2]
		if got.State != msgRemoved || got.Text != "" || got.SenderID != DeletedUID {
			t.Errorf("after the eraser: %+v, want REMOVED with the placeholder sender", got)
		}
		if hits := e.uidHits(bob); len(hits) != 0 {
			t.Errorf("the deleted user's uid is still in storage: %v", hits)
		}
	})
	t.Run("the sender deletes the account, then a takedown", func(t *testing.T) {
		e := newIT(t, nil)
		convID, _, m2 := twoMessages(t, e)
		e.runEraserFor(bob)
		res, c, err := e.takedown(convID, m2, false)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "TakedownMessage tombstoned by the eraser", c, budgettest.Budget{Reads: 1, Writes: 0})
		if res.Before != msgDeletedAccount || res.After != msgDeletedAccount || res.Wrote {
			t.Errorf("result = %+v, want a no-op on DELETED_ACCOUNT", res)
		}
		if _, err := e.newService().ReportableMessage(context.Background(), alice, convID, m2); err != ErrNotFound { //nolint:errorlint // sentinel identity
			t.Errorf("a tombstoned message is reportable: %v", err)
		}
	})
}
