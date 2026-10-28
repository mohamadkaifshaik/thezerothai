//go:build integration

package messaging

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// base is the fixed instant the seeded conversations are built on. It is never compared with the real clock.
var base = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

func discardLog() *slog.Logger { return slog.New(slog.NewJSONHandler(io.Discard, nil)) }

// runEraserFor drives the step for uid to completion on the real repo, summing the cost of every call.
func (e *itEnv) runEraserFor(uid string) (calls int, total *budget.Counter) {
	e.t.Helper()
	er := NewEraser(e.repo, discardLog())
	ctx, total := budget.WithCounter(context.Background())
	var cp []byte
	for calls < 500 {
		next, done, err := er.PurgeUser(ctx, uid, cp)
		calls++
		if err != nil {
			e.t.Fatalf("PurgeUser call %d: %v", calls, err)
		}
		cp = next
		if done {
			return calls, total
		}
	}
	e.t.Fatal("the eraser did not finish")
	return 0, nil
}

// The thread, inbox, requests, badge count() and eraser queries, run on the emulator against collections that hold
// nothing but the automatic single-field indexes (no composite index is deployed for them: firestore.indexes.json
// carries only the six fieldOverrides of W7-3). The Firestore emulator does NOT enforce indexes, so this proves the
// queries run; that each is served by an automatic index is by construction, per query:
//   - thread, thread since, export: `createdAt DESC, __name__ DESC` (+ `createdAt >`) on one field: the descending
//     single-field index of createdAt, which carries __name__ descending (the precedent is pageBookmarks);
//   - inbox, requests, since: the same on lastMessageAt;
//   - badge: `unreadCount > 0` Limit 100 count(): a range on one field;
//   - eraser conversations, export conversations: `participants array-contains uid ORDER BY __name__`: the array
//     index is ordered by (element, __name__);
//   - eraser messages: `senderId == uid ORDER BY __name__`: an equality on one field.
func TestQueries_RunWithoutAnyCompositeIndex(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	for i := range 3 {
		e.tick(time.Second)
		e.must(alice, toUser(skey(i), bob, fmt.Sprint("m", i)))
		e.must(bob, toUser(skey(10+i), alice, fmt.Sprint("r", i)))
	}
	ctx := context.Background()
	convID := ConversationID(alice, bob)
	msgs := e.fs.Collection("conversations").Doc(convID).Collection("messages")
	since := base
	run := func(name string, q firestore.Query) {
		t.Helper()
		if _, err := q.Documents(ctx).GetAll(); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	run("thread", msgs.OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(20))
	run("thread since", msgs.Where("createdAt", ">", since).OrderBy("createdAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(50))
	run("thread past clearedAt", msgs.Where("createdAt", ">", since).OrderBy("createdAt", firestore.Desc).Limit(20))
	for _, folder := range []string{"dmInbox", "dmRequests"} {
		col := e.fs.Collection("users").Doc(alice).Collection(folder)
		run(folder+" page", col.OrderBy("lastMessageAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(20))
		run(folder+" since", col.Where("lastMessageAt", ">", since).OrderBy("lastMessageAt", firestore.Desc).OrderBy(firestore.DocumentID, firestore.Desc).Limit(50))
		for name, q := range map[string]firestore.Query{"badge": col.Where("unreadCount", ">", 0).Limit(100), "count": col.Limit(100)} {
			res, err := q.NewAggregationQuery().WithCount("n").Get(ctx)
			if err != nil {
				t.Errorf("%s %s count(): %v", folder, name, err)
				continue
			}
			if res["n"] == nil {
				t.Errorf("%s %s count(): no result", folder, name)
			}
		}
	}
	run("eraser conversations", e.fs.Collection("conversations").Where("participants", "array-contains", alice).OrderBy(firestore.DocumentID, firestore.Asc).Limit(100))
	run("eraser messages", msgs.Where("senderId", "==", alice).OrderBy(firestore.DocumentID, firestore.Asc).Limit(500))
	if got, err := e.repo.ExportMessages(ctx, alice, convID, nil); err != nil || len(got) != 6 {
		t.Errorf("export messages = %d, %v", len(got), err)
	}
	if got, err := e.repo.ExportConversations(ctx, alice); err != nil || len(got) != 1 {
		t.Errorf("export conversations = %d, %v", len(got), err)
	}
}

// The reference sequence of the plan: A (deleted) and B with 5 messages each. B's thread shows A's 5 as DELETED_ACCOUNT
// with empty text and B's 5 intact; B's entry reads "Deleted account"; A's entries are gone; a send by B is
// CANNOT_MESSAGE. Both orders of "who spoke last" are covered: when the user's message was last the snippet is cleared.
func TestEraser_DeletedUserLeavesTombstonesForThePeer(t *testing.T) {
	for _, tt := range []struct {
		name        string
		aSpeaksLast bool
	}{{"the deleted user spoke last", true}, {"the peer spoke last", false}} {
		t.Run(tt.name, func(t *testing.T) {
			e := newIT(t, nil)
			e.mutual(alice, bob)
			convID := ConversationID(alice, bob)
			for i := range 5 {
				e.tick(time.Second)
				if tt.aSpeaksLast {
					e.must(bob, toUser(skey(100+i), alice, fmt.Sprint("bob says ", i)))
					e.tick(time.Second)
					e.must(alice, toUser(skey(i), bob, fmt.Sprint("alice says ", i)))
				} else {
					e.must(alice, toUser(skey(i), bob, fmt.Sprint("alice says ", i)))
					e.tick(time.Second)
					e.must(bob, toUser(skey(100+i), alice, fmt.Sprint("bob says ", i)))
				}
			}
			calls, total := e.runEraserFor(alice)
			t.Logf("eraser: %d calls, reads %d, writes %d, deletes %d", calls, total.Reads(), total.Writes(), total.Deletes())
			// next+mark 3 reads (cursor, conversation, peer entry) + 5 messages + the closing cursor read 1.
			budgettest.Assert(t, "eraser, 1 conversation of 5 own messages", total, budgettest.Budget{Reads: 9, Writes: 7, Deletes: 1})
			if total.Writes() != 7 || total.Deletes() != 1 {
				t.Errorf("writes/deletes = %d/%d, want 7/1 (gone, peer entry, 5 tombstones / own entry)", total.Writes(), total.Deletes())
			}

			var tombstones, intact int
			for _, m := range e.msgs(convID) {
				switch {
				case m.SenderID == alice && m.State == msgDeletedAccount && m.Text == "" && m.RequestHash == "":
					tombstones++
				case m.SenderID == bob && m.State == msgVisible && strings.HasPrefix(m.Text, "bob says"):
					intact++
				default:
					t.Errorf("unexpected message after the erasure: %+v", m)
				}
			}
			if tombstones != 5 || intact != 5 {
				t.Errorf("tombstones/intact = %d/%d, want 5/5", tombstones, intact)
			}
			peer, ok := e.entry(bob, "dmInbox", convID)
			if !ok || peer.Peer.DisplayName != DeletedAccountName || peer.Peer.Handle != "" || peer.Peer.AvatarThumbURL != "" {
				t.Errorf("bob's entry = %+v, %v, want the Deleted account placeholder", peer, ok)
			}
			if tt.aSpeaksLast != (peer.Last.Snippet == deletedSnippet && peer.Last.State == msgDeletedAccount) {
				t.Errorf("bob's last = %+v; the snippet must be cleared exactly when the deleted user's message was last (%v)", peer.Last, tt.aSpeaksLast)
			}
			if !tt.aSpeaksLast && !strings.HasPrefix(peer.Last.Snippet, "bob says") {
				t.Errorf("bob's own last message snippet was touched: %+v", peer.Last)
			}
			for _, folder := range []string{"dmInbox", "dmRequests"} {
				if _, ok := e.entry(alice, folder, convID); ok {
					t.Errorf("alice's %s entry survived", folder)
				}
			}
			conv, _ := e.conv(convID)
			if !slices.Equal(conv.Gone, []string{alice}) {
				t.Errorf("gone = %v, want [alice]", conv.Gone)
			}
			_, wc, err := e.send(bob, toUser(skey(500), alice, "are you there?"))
			wantAPI(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, nil)
			if wc.Writes() != 0 {
				t.Errorf("the send to a deleted user wrote %d", wc.Writes())
			}

			// A repeat of the whole step writes nothing: the cursor, the conversation (already marked, so no peer-entry
			// read), the 5 tombstoned messages are read again and skipped, and the entry delete is a no-op.
			_, again := e.runEraserFor(alice)
			budgettest.Assert(t, "eraser repeat", again, budgettest.Budget{Reads: 8, Writes: 0, Deletes: 1})
			if again.Writes() != 0 {
				t.Errorf("a repeated erasure wrote %d (the peer entry and the tombstones are done)", again.Writes())
			}
		})
	}
}

// Both participants deleted: no document remains under conversations/{convId}, and no entry of either.
func TestEraser_BothDeletedLeavesNothing(t *testing.T) {
	e := newIT(t, nil)
	e.mutual(alice, bob)
	convID := ConversationID(alice, bob)
	for i := range 5 {
		e.tick(time.Second)
		e.must(alice, toUser(skey(i), bob, fmt.Sprint("a", i)))
		e.must(bob, toUser(skey(100+i), alice, fmt.Sprint("b", i)))
	}
	e.runEraserFor(alice)
	if left := e.treeDocs(convID); len(left) != 11 { // the conversation and 10 messages stay while bob lives
		t.Fatalf("after alice: %d docs left, want 11", len(left))
	}
	_, total := e.runEraserFor(bob)
	if left := e.treeDocs(convID); len(left) != 0 {
		t.Errorf("docs left under the conversation after both erasures: %v", left)
	}
	for _, uid := range []string{alice, bob} {
		for _, folder := range []string{"dmInbox", "dmRequests"} {
			if _, ok := e.entry(uid, folder, convID); ok {
				t.Errorf("%s's %s entry survived", uid, folder)
			}
		}
	}
	if total.Deletes() != 12 { // 10 messages, the conversation, bob's own entry
		t.Errorf("the second erasure deleted %d, want 12", total.Deletes())
	}
}

// A request the deleted user had received lives in dmRequests; that entry goes, and the requester's own entry becomes
// the placeholder.
func TestEraser_RequestRecipientEntryInDmRequests(t *testing.T) {
	e := newIT(t, nil)
	convID := e.seedConversation(alice, bob, stateRequest, base, [2]string{alice, "may I?"}, [2]string{alice, "hello?"})
	e.runEraserFor(bob)
	if _, ok := e.entry(bob, "dmRequests", convID); ok {
		t.Error("the recipient's dmRequests entry survived")
	}
	req, ok := e.entry(alice, "dmInbox", convID)
	if !ok || req.Peer.DisplayName != DeletedAccountName || req.Last.Snippet != "hello?" {
		t.Errorf("the requester's entry = %+v, %v: placeholder expected, her own last message kept", req, ok)
	}
	for _, m := range e.msgs(convID) {
		if m.State != msgVisible || m.Text == "" {
			t.Errorf("the requester's message was touched: %+v", m)
		}
	}
}

// The deleted user's conversation as the REQUESTER: the entry is in dmInbox; the recipient's request entry becomes the
// placeholder and its snippet is cleared (the requester's message was last).
func TestEraser_RequesterDeleted(t *testing.T) {
	e := newIT(t, nil)
	convID := e.seedConversation(alice, bob, stateRequest, base, [2]string{alice, "may I?"})
	e.runEraserFor(alice)
	req, ok := e.entry(bob, "dmRequests", convID)
	if !ok || req.Peer.DisplayName != DeletedAccountName || req.Last.Snippet != deletedSnippet {
		t.Errorf("the recipient's request entry = %+v, %v", req, ok)
	}
	if _, ok := e.entry(alice, "dmInbox", convID); ok {
		t.Error("the requester's own entry survived")
	}
}

// More than 500 own messages take several tombstone pages with a cursor; the peer's messages are never touched; every
// call is bounded to 500 writes.
func TestEraser_TombstonesInPagesOf500(t *testing.T) {
	e := newIT(t, nil)
	convID := ConversationID(alice, bob)
	ctx := context.Background()
	doc := ConvDoc{Kind: kindDirect, Participants: sortedPair(alice, bob), State: stateAccepted, CreatedAt: base, UpdatedAt: base}
	if _, err := e.fs.Collection("conversations").Doc(convID).Set(ctx, doc); err != nil {
		t.Fatal(err)
	}
	const own, theirs = 1_100, 40
	bw := e.fs.BulkWriter(ctx)
	var jobs []*firestore.BulkWriterJob
	for i := range own + theirs {
		sender, state := alice, msgVisible
		if i%28 == 27 { // 40 of them are bob's, spread through the ids
			sender = bob
		}
		job, err := bw.Set(e.fs.Collection("conversations").Doc(convID).Collection("messages").Doc(fmt.Sprintf("%032d", i)),
			MsgDoc{SenderID: sender, Text: "t", State: state, RequestHash: "h", CreatedAt: base.Add(time.Duration(i) * time.Second)})
		if err != nil {
			t.Fatal(err)
		}
		jobs = append(jobs, job)
	}
	bw.End()
	for _, j := range jobs {
		if _, err := j.Results(); err != nil {
			t.Fatal(err)
		}
	}
	bobMsgs := 0
	for _, m := range e.msgs(convID) {
		if m.SenderID == bob {
			bobMsgs++
		}
	}
	ownMsgs := own + theirs - bobMsgs

	er := NewEraser(e.repo, discardLog())
	var cp []byte
	maxWrites, tombstonePages := int64(0), 0
	for range 100 {
		cctx, c := budget.WithCounter(ctx)
		next, done, err := er.PurgeUser(cctx, alice, cp)
		if err != nil {
			t.Fatal(err)
		}
		maxWrites = max(maxWrites, c.Writes())
		if c.Writes() >= 400 {
			tombstonePages++
		}
		cp = next
		if done {
			break
		}
	}
	if maxWrites > 500 {
		t.Errorf("one call wrote %d, want at most 500", maxWrites)
	}
	var out Checkpoint
	_ = json.Unmarshal(cp, &out)
	if out.Tombstoned != ownMsgs || out.Conversations != 1 || out.EntriesDeleted != 1 {
		t.Errorf("counters = %+v, want %d tombstoned in 1 conversation", out, ownMsgs)
	}
	if tombstonePages < 2 {
		t.Errorf("only %d full tombstone pages, want at least 2", tombstonePages)
	}
	var tomb, visible int
	for _, m := range e.msgs(convID) {
		switch {
		case m.SenderID == alice && m.State == msgDeletedAccount && m.Text == "":
			tomb++
		case m.SenderID == bob && m.State == msgVisible && m.Text == "t":
			visible++
		}
	}
	if tomb != ownMsgs || visible != bobMsgs {
		t.Errorf("tombstoned %d (want %d), peer messages intact %d (want %d)", tomb, ownMsgs, visible, bobMsgs)
	}
}

// Both participants deleted at the same moment, each by its own eraser run, over several conversations: whoever marks
// second deletes the tree, and nothing is left behind.
func TestEraser_BothDeletedConcurrently(t *testing.T) {
	e := newIT(t, func(e *itEnv) {
		for i := range 4 {
			e.addUser(fmt.Sprintf("peer-%d", i), fmt.Sprintf("p%d", i), false)
		}
	})
	var ids []string
	for i := range 4 {
		id := e.seedConversation(alice, fmt.Sprintf("peer-%d", i), stateAccepted, base, [2]string{alice, "a"}, [2]string{fmt.Sprintf("peer-%d", i), "b"}, [2]string{alice, "c"})
		ids = append(ids, id)
	}
	var wg sync.WaitGroup
	for i := range 4 {
		wg.Add(2)
		go func() { defer wg.Done(); e.runEraserFor(alice) }()
		go func() { defer wg.Done(); e.runEraserFor(fmt.Sprintf("peer-%d", i)) }()
	}
	wg.Wait()
	for _, id := range ids {
		if left := e.treeDocs(id); len(left) != 0 {
			t.Errorf("conversation %s left %v", id[:8], left)
		}
	}
	for i := range 4 {
		for _, uid := range []string{alice, fmt.Sprintf("peer-%d", i)} {
			for _, folder := range []string{"dmInbox", "dmRequests"} {
				if _, ok := e.entry(uid, folder, ids[i]); ok {
					t.Errorf("%s's %s entry survived", uid, folder)
				}
			}
		}
	}
}

// A user with no conversations: the step is one empty query.
func TestEraser_NoConversations(t *testing.T) {
	e := newIT(t, nil)
	calls, total := e.runEraserFor("uid-nobody")
	if calls != 1 || total.Reads() != 1 || total.Writes() != 0 || total.Deletes() != 0 {
		t.Errorf("calls/reads/writes/deletes = %d/%d/%d/%d, want 1/1/0/0", calls, total.Reads(), total.Writes(), total.Deletes())
	}
}

// The `messages` section against its golden file: own text in full, received as time and "received", the peer by handle,
// no uid anywhere, conversations newest first.
func TestExport_MatchesGolden(t *testing.T) {
	e := newIT(t, func(e *itEnv) {
		for _, u := range []string{"uid-carol", "uid-dave", "uid-erin"} {
			e.addUser(u, strings.TrimPrefix(u, "uid-"), false)
		}
	})
	e.seedConversation(alice, bob, stateAccepted, base, [2]string{alice, "hi bob"}, [2]string{bob, "SECRET: hi alice"}, [2]string{alice, "see you"})
	e.seedConversation("uid-carol", alice, stateRequest, base.Add(24*time.Hour), [2]string{"uid-carol", "SECRET: request text"}, [2]string{"uid-carol", "SECRET: second"})
	e.seedConversation(alice, "uid-dave", stateAccepted, base.Add(48*time.Hour), [2]string{alice, "multi\nline & <html> \"quotes\" é"})
	// A conversation whose peer deleted the account and one the user cleared for themselves.
	gone := e.seedConversation(alice, "uid-erin", stateAccepted, base.Add(72*time.Hour), [2]string{"uid-erin", "SECRET: bye"})
	if _, err := e.fs.Collection("conversations").Doc(gone).Update(context.Background(), []firestore.Update{{Path: "gone", Value: []string{"uid-erin"}}}); err != nil {
		t.Fatal(err)
	}
	cleared := ConversationID(alice, bob)
	if _, err := e.fs.Collection("conversations").Doc(cleared).Update(context.Background(), []firestore.Update{{Path: "clearedAt", Value: map[string]time.Time{alice: base.Add(time.Hour)}}}); err != nil {
		t.Fatal(err)
	}
	// dave deleted his account: no profile, so no handle.
	delete(e.profs.profiles, "uid-dave")

	var buf bytes.Buffer
	ctx, c := budget.WithCounter(context.Background())
	if err := NewExporter(e.repo, e.profs).ExportUser(ctx, alice, &buf); err != nil {
		t.Fatal(err)
	}
	// 4 conversations + 3 + 2 + 1 + 1 messages (both sides are read to order the section).
	if c.Reads() != 11 || c.Writes() != 0 {
		t.Errorf("export reads/writes = %d/%d, want 11/0", c.Reads(), c.Writes())
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, bytes.TrimSpace(buf.Bytes()), "", "  "); err != nil {
		t.Fatalf("the section is not one JSON value: %v\n%s", err, buf.String())
	}
	got := pretty.String() + "\n"
	const golden = "testdata/export_messages.golden.json"
	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.WriteFile(golden, []byte(got), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatalf("read golden: %v (UPDATE_GOLDEN=1 writes it)", err)
	}
	if got != string(want) {
		t.Errorf("the section differs from %s:\n--- got\n%s\n--- want\n%s", golden, got, want)
	}
	for _, forbidden := range []string{"SECRET", "uid-", alice, bob, "dmInbox"} {
		if strings.Contains(got, forbidden) {
			t.Errorf("the section contains %q", forbidden)
		}
	}
}
