//go:build integration

package messaging

import (
	"context"
	"fmt"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
)

// putMsg writes one message document as is.
func (e *itEnv) putMsg(convID, id string, m MsgDoc) {
	e.t.Helper()
	if _, err := e.fs.Collection("conversations").Doc(convID).Collection("messages").Doc(id).Set(context.Background(), m); err != nil {
		e.t.Fatal(err)
	}
}

// setPreview points both participants' entries of a conversation at one message with the given snippet.
func (e *itEnv) setPreview(convID string, uids []string, folder, msgID, snippet string, encrypted bool) {
	e.t.Helper()
	for _, uid := range uids {
		if _, err := e.fs.Collection("users").Doc(uid).Collection(folder).Doc(convID).Update(context.Background(), []firestore.Update{
			{Path: "last.messageId", Value: msgID}, {Path: "last.snippet", Value: snippet}, {Path: "last.sharedPost", Value: true},
			{Path: "last.encrypted", Value: encrypted}, {Path: "last.state", Value: msgVisible},
		}); err != nil {
			e.t.Fatal(err)
		}
	}
}

// newestMsg is the id of the conversation's newest message.
func (e *itEnv) newestMsg(convID string) string {
	e.t.Helper()
	var id string
	var at time.Time
	for k, m := range e.msgs(convID) {
		if m.CreatedAt.After(at) {
			id, at = k, m.CreatedAt
		}
	}
	return id
}

// purgeAll drives PurgePlaintextPage from the start to the end and sums the pages.
func (e *itEnv) purgeAll(mode PlaintextMode) PlaintextPage {
	e.t.Helper()
	var sum PlaintextPage
	after := ""
	for range 100 {
		p, err := e.repo.PurgePlaintextPage(context.Background(), after, mode)
		if err != nil {
			e.t.Fatalf("PurgePlaintextPage: %v", err)
		}
		sum.Add(p)
		if !p.More {
			return sum
		}
		after = p.Last
	}
	e.t.Fatal("the walk did not finish")
	return sum
}

// A conversation converted by mls_init (plaintext above the separator, encrypted below) and a plaintext-only one:
// count, dry run, purge and a rerun, then the wire, the report and the export views of the result.
func TestPurgePlaintext_MixedConversation(t *testing.T) {
	e := newIT(t, func(e *itEnv) { e.addUser(carol, "carol", false) })
	ctx := context.Background()

	// alice-bob: two plaintext messages (one shares a post), then two encrypted ones; the previews show the encrypted one.
	mixed := e.seedConversation(alice, bob, stateAccepted, base)
	if _, err := e.fs.Collection("conversations").Doc(mixed).Update(ctx, []firestore.Update{{Path: "encryption", Value: encMLS}, {Path: "mlsGen", Value: 1}, {Path: "mlsEpoch", Value: 1}, {Path: "rev", Value: 4}}); err != nil {
		t.Fatal(err)
	}
	p1, p2, e1, e2 := msgID(100), msgID(101), msgID(102), msgID(103)
	e.putMsg(mixed, p1, MsgDoc{SenderID: alice, State: msgVisible, Text: "SECRET plain one", RequestHash: requestHash(mixed, "SECRET plain one", ""), CreatedAt: base})
	e.putMsg(mixed, p2, MsgDoc{SenderID: bob, State: msgVisible, Text: "SECRET look", SharedPostID: "7300000000000000001", RequestHash: "h2", CreatedAt: base.Add(time.Second)})
	enc := func(sender string, at time.Duration) MsgDoc {
		return MsgDoc{SenderID: sender, State: msgVisible, RequestHash: "enc-h", Ciphertext: []byte("ct"), Commitment: itCommitment, MlsGen: 1, MlsEpoch: 1, MlsKey: "1:1", CreatedAt: base.Add(at), CtExpireAt: base.Add(at + CiphertextRetention)}
	}
	e.putMsg(mixed, e1, enc(alice, 2*time.Second))
	e.putMsg(mixed, e2, enc(bob, 3*time.Second))
	e.setPreview(mixed, []string{alice, bob}, dmInboxCollection, e2, "", true)

	// alice-carol: plaintext only, an open request from carol; the previews show carol's last message.
	plain := e.seedConversation(carol, alice, stateRequest, base, [2]string{carol, "SECRET hi"}, [2]string{carol, "SECRET again"})
	last := e.newestMsg(plain)
	if _, err := e.fs.Collection("users").Doc(carol).Collection(dmInboxCollection).Doc(plain).Update(ctx, []firestore.Update{{Path: "last.messageId", Value: last}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.fs.Collection("users").Doc(alice).Collection(dmRequestsCollection).Doc(plain).Update(ctx, []firestore.Update{{Path: "last.messageId", Value: last}, {Path: "last.sharedPost", Value: true}}); err != nil {
		t.Fatal(err)
	}
	entryBefore, _ := e.entry(alice, dmRequestsCollection, plain)

	totals, err := e.repo.CountPlaintext(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if totals.Conversations != 2 || totals.Messages != 6 {
		t.Errorf("aggregation = %+v, want 2 conversations and 6 messages", totals)
	}
	for _, mode := range []PlaintextMode{PlaintextCountOnly, PlaintextDryRun} {
		got := e.purgeAll(mode)
		wantPreviews := 0
		if mode == PlaintextDryRun {
			wantPreviews = 2
		}
		if got.Conversations != 2 || got.Messages != 6 || got.Plaintext != 4 || got.Purged != 0 || got.Previews != wantPreviews {
			t.Errorf("mode %d: %+v, want 2 conversations, 6 messages, 4 plaintext, nothing purged, %d previews", mode, got, wantPreviews)
		}
		if m := e.msgs(mixed)[p1]; m.Text == "" || m.TextRemoved {
			t.Errorf("mode %d wrote: %+v", mode, m)
		}
		for id, m := range e.msgs(plain) {
			if m.Text == "" || m.RequestHash == "" || m.TextRemoved {
				t.Errorf("mode %d wrote alice-carol message %s: %+v", mode, id[:8], m)
			}
		}
		for _, side := range [][2]string{{carol, dmInboxCollection}, {alice, dmRequestsCollection}} {
			if en, _ := e.entry(side[0], side[1], plain); en.Last.Snippet != "SECRET again" || en.Last.SharedPost != (side[0] == alice) {
				t.Errorf("mode %d rewrote %s's preview: %+v", mode, side[0], en.Last)
			}
		}
	}

	got := e.purgeAll(PlaintextPurge)
	if got.Plaintext != 4 || got.Purged != 4 || got.Skipped != 0 || got.Previews != 2 || got.PreviewsSkipped != 0 {
		t.Errorf("purge = %+v, want 4 purged and 2 previews", got)
	}
	ms := e.msgs(mixed)
	for _, id := range []string{p1, p2} {
		m := ms[id]
		if m.Text != "" || m.RequestHash != "" || m.SharedPostID != "" || !m.TextRemoved || m.State != msgVisible || m.SenderID == "" || m.CreatedAt.IsZero() {
			t.Errorf("purged message %s = %+v, want text, digest and post gone, textRemoved, the record kept", id[:8], m)
		}
	}
	for _, id := range []string{e1, e2} {
		m := ms[id]
		if string(m.Ciphertext) != "ct" || m.RequestHash != "enc-h" || m.TextRemoved || m.CtRemoved {
			t.Errorf("encrypted message %s was touched: %+v", id[:8], m)
		}
	}
	if c, _ := e.conv(mixed); c.Rev != 4 {
		t.Errorf("rev = %d, want 4 (the purge never bumps it)", c.Rev)
	}
	for _, uid := range []string{alice, bob} {
		if en, _ := e.entry(uid, dmInboxCollection, mixed); en.Last.MessageID != e2 || !en.Last.Encrypted {
			t.Errorf("%s's encrypted preview was rewritten: %+v", uid, en.Last)
		}
	}
	for _, side := range [][2]string{{carol, dmInboxCollection}, {alice, dmRequestsCollection}} {
		en, ok := e.entry(side[0], side[1], plain)
		if !ok || en.Last.Snippet != noLongerStoredSnippet || en.Last.SharedPost || en.Last.State != msgVisible {
			t.Errorf("%s's preview = %+v, want %q", side[0], en.Last, noLongerStoredSnippet)
		}
		if side[0] == alice && (!en.LastMessageAt.Equal(entryBefore.LastMessageAt) || !en.ChangedAt.Equal(entryBefore.ChangedAt) || en.UnreadCount != entryBefore.UnreadCount) {
			t.Errorf("the preview rewrite moved lastMessageAt, changedAt or unreadCount: %+v -> %+v", entryBefore, en)
		}
	}

	// A rerun finds nothing and writes nothing.
	if again := e.purgeAll(PlaintextPurge); again.Plaintext != 0 || again.Purged != 0 || again.Previews != 0 {
		t.Errorf("rerun = %+v, want nothing", again)
	}

	// The wire: text_removed on the purged messages only.
	resp, err := e.svc.ListMessages(verifiedCtx(), alice, &messagingv1.ListMessagesRequest{ConversationId: mixed})
	if err != nil {
		t.Fatal(err)
	}
	var rows []string
	for _, m := range resp.GetMessages() {
		rows = append(rows, fmt.Sprintf("%s removed=%v text=%q post=%v ct=%d", m.GetId()[:4], m.GetTextRemoved(), m.GetText(), m.GetSharedPost() != nil, len(m.GetCiphertext())))
	}
	want := []string{
		e2[:4] + ` removed=false text="" post=false ct=2`, e1[:4] + ` removed=false text="" post=false ct=2`,
		p2[:4] + ` removed=true text="" post=false ct=0`, p1[:4] + ` removed=true text="" post=false ct=0`,
	}
	if !slices.Equal(rows, want) {
		t.Errorf("ListMessages = %v, want %v", rows, want)
	}

	// A purged message is unreportable.
	if _, err := e.svc.ReportableMessage(ctx, alice, mixed, p2); err != ErrNotFound { //nolint:errorlint // the sentinel is the contract
		t.Errorf("report of a purged message: err = %v, want ErrNotFound", err)
	}
	// The export: alice's own purged message is textRemoved, no text.
	exp, err := e.repo.ExportMessages(ctx, alice, mixed, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range exp {
		if m.ID == p1 && (!m.TextRemoved || m.Text != "") {
			t.Errorf("export row = %+v, want textRemoved and no text", m)
		}
	}
}

// Resume from a cursor: a page after a conversation id walks only the later conversations; a run from the start then
// finishes the one before it.
func TestPurgePlaintext_ResumeFromCursor(t *testing.T) {
	e := newIT(t, func(e *itEnv) { e.addUser(carol, "carol", false) })
	ctx := context.Background()
	ids := []string{
		e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "SECRET a"}),
		e.seedConversation(alice, carol, stateAccepted, base, [2]string{carol, "SECRET b"}),
		e.seedConversation(bob, carol, stateAccepted, base, [2]string{bob, "SECRET c"}),
	}
	slices.Sort(ids)
	p, err := e.repo.PurgePlaintextPage(ctx, ids[0], PlaintextPurge)
	if err != nil {
		t.Fatal(err)
	}
	if p.Conversations != 2 || p.Purged != 2 || p.Last != ids[2] || p.More {
		t.Errorf("page after the first = %+v, want the two later conversations, Last = the third", p)
	}
	for i, id := range ids {
		for _, m := range e.msgs(id) {
			if m.TextRemoved != (i > 0) {
				t.Errorf("conversation %d: textRemoved = %v", i, m.TextRemoved)
			}
		}
	}
	if p, err := e.repo.PurgePlaintextPage(ctx, ids[2], PlaintextPurge); err != nil || p.Conversations != 0 || p.Last != ids[2] || p.More {
		t.Errorf("page after the last = %+v, %v, want empty with the cursor kept", p, err)
	}
	if got := e.purgeAll(PlaintextPurge); got.Conversations != 3 || got.Purged != 1 {
		t.Errorf("a run from the start = %+v, want 3 walked and the first one purged", got)
	}
}

// A message changed between the read and the update is Skipped, not rewritten; the next run purges it.
func TestPurgePlaintext_ChangedMessageIsSkipped(t *testing.T) {
	e := newIT(t, nil)
	ctx := context.Background()
	conv := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "SECRET one"}, [2]string{bob, "SECRET two"})
	var target string
	for id := range e.msgs(conv) {
		target = id
		break
	}
	fired := false
	e.repo.hooks = &raceHooks{afterPlaintextRead: func() {
		if fired {
			return
		}
		fired = true
		if _, err := e.fs.Collection("conversations").Doc(conv).Collection("messages").Doc(target).Update(ctx, []firestore.Update{{Path: "text", Value: "SECRET edited meanwhile"}}); err != nil {
			t.Error(err)
		}
	}}
	got := e.purgeAll(PlaintextPurge)
	if got.Purged != 1 || got.Skipped != 1 {
		t.Errorf("purge = %+v, want 1 purged and 1 skipped", got)
	}
	if m := e.msgs(conv)[target]; m.Text != "SECRET edited meanwhile" || m.TextRemoved {
		t.Errorf("the changed message was rewritten: %+v", m)
	}
	e.repo.hooks = nil
	if again := e.purgeAll(PlaintextPurge); again.Purged != 1 || again.Skipped != 0 {
		t.Errorf("rerun = %+v, want the skipped one purged", again)
	}
	if m := e.msgs(conv)[target]; m.Text != "" || !m.TextRemoved {
		t.Errorf("after the rerun: %+v", m)
	}
}

// The right-to-delete eraser and the purge are independent: in either order the deleted user's messages end as
// DELETED_ACCOUNT tombstones with no text, the peer's as purged, the deleted uid is named nowhere, and a later purge
// finds nothing.
func TestPurgePlaintext_AndEraserInEitherOrder(t *testing.T) {
	for _, eraserFirst := range []bool{true, false} {
		t.Run(fmt.Sprintf("eraser first %v", eraserFirst), func(t *testing.T) {
			e := newIT(t, nil)
			conv := e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "SECRET from alice"}, [2]string{bob, "SECRET from bob"})
			var got PlaintextPage
			if eraserFirst {
				e.runEraserFor(alice)
				got = e.purgeAll(PlaintextPurge)
				if got.Purged != 1 { // only bob's: alice's is already a tombstone with nothing readable
					t.Errorf("purge after the eraser = %+v, want bob's message only", got)
				}
			} else {
				got = e.purgeAll(PlaintextPurge)
				if got.Purged != 2 {
					t.Errorf("purge = %+v, want both messages", got)
				}
				e.runEraserFor(alice)
			}
			for id, m := range e.msgs(conv) {
				if m.Text != "" || m.RequestHash != "" || m.SharedPostID != "" {
					t.Errorf("message %s still holds readable data: %+v", id[:8], m)
				}
				switch m.SenderID {
				case DeletedUID:
					if m.State != msgDeletedAccount {
						t.Errorf("alice's message %s = %+v, want DELETED_ACCOUNT", id[:8], m)
					}
					if m.TextRemoved == eraserFirst {
						t.Errorf("alice's message %s textRemoved = %v (set only when the purge ran first)", id[:8], m.TextRemoved)
					}
				case bob:
					if m.State != msgVisible || !m.TextRemoved {
						t.Errorf("bob's message %s = %+v, want VISIBLE and textRemoved", id[:8], m)
					}
				default:
					t.Errorf("message %s has sender %q", id[:8], m.SenderID)
				}
			}
			if hits := e.uidHits(alice); len(hits) != 0 {
				t.Errorf("alice is still named in %v", hits)
			}
			if again := e.purgeAll(PlaintextPurge); again.Plaintext != 0 || again.Purged != 0 {
				t.Errorf("a later purge = %+v, want nothing", again)
			}
		})
	}
}

// A request accepted after the page read the conversation: the recipient's entry moved from dmRequests to dmInbox, and
// the preview there is rewritten. When the request entry is gone and no dmInbox entry exists either, it is PreviewsSkipped.
func TestPurgePlaintext_RequestAcceptedMidRun(t *testing.T) {
	for _, moved := range []bool{true, false} {
		t.Run(fmt.Sprintf("entry moved %v", moved), func(t *testing.T) {
			e := newIT(t, func(e *itEnv) { e.addUser(carol, "carol", false) })
			ctx := context.Background()
			conv := e.seedConversation(carol, alice, stateRequest, base, [2]string{carol, "SECRET hello"})
			last := e.newestMsg(conv)
			for _, side := range [][2]string{{carol, dmInboxCollection}, {alice, dmRequestsCollection}} {
				if _, err := e.fs.Collection("users").Doc(side[0]).Collection(side[1]).Doc(conv).Update(ctx, []firestore.Update{{Path: "last.messageId", Value: last}}); err != nil {
					t.Fatal(err)
				}
			}
			reqRef := e.fs.Collection("users").Doc(alice).Collection(dmRequestsCollection).Doc(conv)
			e.repo.hooks = &raceHooks{afterPlaintextRead: func() {
				snap, err := reqRef.Get(ctx)
				if err != nil {
					t.Error(err)
					return
				}
				if moved {
					if _, err := e.fs.Collection("users").Doc(alice).Collection(dmInboxCollection).Doc(conv).Set(ctx, snap.Data()); err != nil {
						t.Error(err)
					}
				}
				if _, err := reqRef.Delete(ctx); err != nil {
					t.Error(err)
				}
			}}
			got := e.purgeAll(PlaintextPurge)
			if moved {
				if got.Purged != 1 || got.Previews != 2 || got.PreviewsSkipped != 0 {
					t.Errorf("purge = %+v, want 1 purged and both previews rewritten", got)
				}
				if en, ok := e.entry(alice, dmInboxCollection, conv); !ok || en.Last.Snippet != noLongerStoredSnippet {
					t.Errorf("the moved entry = %+v (found %v), want %q", en.Last, ok, noLongerStoredSnippet)
				}
			} else if got.Purged != 1 || got.Previews != 1 || got.PreviewsSkipped != 1 {
				t.Errorf("purge = %+v, want 1 purged, carol's preview rewritten and alice's counted as skipped", got)
			}
		})
	}
}

// A same-key retry of a purged VISIBLE message replays it (text_removed, no text) instead of answering "key reused", on
// both replay paths: the AlreadyExists retry of an ordinary send, and replayOrRefuse behind a refusal (here the
// FEATURE_E2EE_REQUIRED rule switched on after the message was stored). Nothing is written.
func TestPurgePlaintext_SameKeyRetryReplays(t *testing.T) {
	for _, required := range []bool{false, true} {
		t.Run(fmt.Sprintf("behind a refusal %v", required), func(t *testing.T) {
			e := newIT(t, nil)
			e.mutual(alice, bob)
			first := e.must(alice, toUser(skey(1), bob, "SECRET stored before"))
			convID, msgID := first.GetConversation().GetId(), first.GetMessage().GetId()
			if got := e.purgeAll(PlaintextPurge); got.Purged != 1 {
				t.Fatalf("purge = %+v", got)
			}
			e.tick(time.Second)
			if required {
				e.requireFor(alice, bob)
			}
			before := e.snapshotState(convID)
			resp, err := e.send(alice, toUser(skey(1), bob, "SECRET stored before"))
			if err != nil {
				t.Fatalf("retry err = %v, want a replay", err)
			}
			m := resp.GetMessage()
			if m.GetId() != msgID || !m.GetTextRemoved() || m.GetText() != "" || m.GetState() != messagingv1.MessageState_MESSAGE_STATE_VISIBLE {
				t.Errorf("replayed message = %v, want the stored one with text_removed and no text", m)
			}
			if n := len(e.msgs(convID)); n != 1 {
				t.Errorf("%d messages stored, want 1 (no duplicate)", n)
			}
			before.check(t)
		})
	}
}
