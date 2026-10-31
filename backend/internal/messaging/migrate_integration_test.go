//go:build integration

package messaging

import (
	"context"
	"slices"
	"testing"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func (e *itEnv) migrate(after string, dryRun bool) (PlaceholderPage, *budget.Counter, error) {
	ctx, c := budget.WithCounter(context.Background())
	p, err := e.repo.MigratePlaceholder(ctx, after, dryRun)
	return p, c, err
}

// legacyErase turns a seeded conversation into what the pre-W7-34 eraser left behind for `erased`: the legacy placeholder in
// participants (position kept), gone and requestFrom/requestTo, in the erased user's messages and in the survivor's entry.
func (e *itEnv) legacyErase(id, erased, survivor, folder string) {
	e.t.Helper()
	ctx := context.Background()
	conv, _ := e.conv(id)
	swap := func(in []string) []string {
		out := slices.Clone(in)
		for i, v := range out {
			if v == erased {
				out[i] = legacyDeletedUID
			}
		}
		return out
	}
	ups := []firestore.Update{{Path: "participants", Value: swap(conv.Participants)}, {Path: "gone", Value: []string{legacyDeletedUID}}}
	if conv.RequestFrom == erased {
		ups = append(ups, firestore.Update{Path: "requestFrom", Value: legacyDeletedUID})
	}
	if conv.RequestTo == erased {
		ups = append(ups, firestore.Update{Path: "requestTo", Value: legacyDeletedUID})
	}
	if _, err := e.fs.Collection("conversations").Doc(id).Update(ctx, ups); err != nil {
		e.t.Fatal(err)
	}
	for mid, m := range e.msgs(id) {
		if m.SenderID == erased {
			if _, err := e.fs.Collection("conversations").Doc(id).Collection("messages").Doc(mid).Update(ctx, []firestore.Update{{Path: "senderId", Value: legacyDeletedUID}}); err != nil {
				e.t.Fatal(err)
			}
		}
	}
	e.setEntry(survivor, folder, id, firestore.Update{Path: "peerId", Value: legacyDeletedUID})
}

// W7-34 L-2: the dev data migration. Two legacy conversations (an accepted one with 2 erased-sender messages, a request whose
// requester was erased with 1) and one untouched conversation. A dry run reads and writes nothing; the real run rewrites exactly
// the documents that hold the legacy value (1 write each); a rerun is 1 read and 0 writes.
func TestMigratePlaceholder_RewritesOnlyLegacyDocumentsAndIsIdempotent(t *testing.T) {
	e := newIT(t, nil)
	const carol, dave = "uid-carol", "uid-dave"
	c1 := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "x"}, [2]string{alice, "y"}, [2]string{bob, "z"})
	c2 := e.seedConversation(carol, alice, stateRequest, base, [2]string{carol, "hi"})
	c3 := e.seedConversation(alice, dave, stateAccepted, base, [2]string{dave, "keep"})
	e.legacyErase(c1, bob, alice, dmInboxCollection)
	e.legacyErase(c2, carol, alice, dmRequestsCollection)
	// The peers' own entries went with the erased accounts' deletes.
	for _, gone := range []struct{ uid, folder, id string }{{bob, dmInboxCollection, c1}, {carol, dmInboxCollection, c2}} {
		if _, err := e.fs.Collection("users").Doc(gone.uid).Collection(gone.folder).Doc(gone.id).Delete(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := func() (ConvDoc, ConvDoc, map[string]MsgDoc, map[string]MsgDoc) {
		a, _ := e.conv(c1)
		b, _ := e.conv(c2)
		return a, b, e.msgs(c1), e.msgs(c2)
	}
	before1, before2, m1, m2 := snapshot()

	// Dry run: same reads as the real run, no writes, nothing changes.
	p, c, err := e.migrate("", true)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "migrate dry run", c, budgettest.Budget{Reads: 7})
	if c.Writes() != 0 || p.Conversations != 2 || p.Messages != 3 || p.Entries != 2 || p.More {
		t.Fatalf("dry run: page=%+v reads=%d writes=%d, want 2 conversations, 3 messages, 2 entries, 0 writes", p, c.Reads(), c.Writes())
	}
	after1, after2, am1, am2 := snapshot()
	if !equalConv(before1, after1) || !equalConv(before2, after2) || len(am1) != len(m1) || len(am2) != len(m2) {
		t.Fatal("a dry run changed data")
	}
	if in, _ := e.entry(alice, dmInboxCollection, c1); in.PeerID != legacyDeletedUID {
		t.Fatalf("a dry run changed alice's entry: peerId %q", in.PeerID)
	}

	// Real run: 7 reads (query 2, c1 messages 2, c1 entry 1, c2 messages 1, c2 entry 1) and 7 writes (c1: 2+1+1, c2: 1+1+1).
	p, c, err = e.migrate("", false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "migrate", c, budgettest.Budget{Reads: 7, Writes: 7})
	if p.Conversations != 2 || p.Messages != 3 || p.Entries != 2 {
		t.Fatalf("page = %+v", p)
	}
	got1, _ := e.conv(c1)
	if !slices.Contains(got1.Participants, DeletedUID) || slices.Contains(got1.Participants, legacyDeletedUID) || !slices.Equal(got1.Gone, []string{DeletedUID}) {
		t.Errorf("c1 participants=%v gone=%v", got1.Participants, got1.Gone)
	}
	if !slices.Equal(got1.Participants, swapOne(before1.Participants, legacyDeletedUID, DeletedUID)) || !got1.UpdatedAt.Equal(before1.UpdatedAt) || got1.Rev != before1.Rev {
		t.Errorf("c1 order, updatedAt or rev moved: %+v vs %+v", got1, before1)
	}
	got2, _ := e.conv(c2)
	if got2.RequestFrom != DeletedUID || got2.RequestTo != alice || !slices.Contains(got2.Participants, DeletedUID) || !slices.Equal(got2.Gone, []string{DeletedUID}) {
		t.Errorf("c2 = %+v", got2)
	}
	for _, id := range []string{c1, c2} {
		for mid, m := range e.msgs(id) {
			if m.SenderID == legacyDeletedUID {
				t.Errorf("message %s still has the legacy sender", mid)
			}
		}
	}
	if ent, _ := e.entry(alice, dmInboxCollection, c1); ent.PeerID != DeletedUID {
		t.Errorf("c1 entry peerId = %q", ent.PeerID)
	}
	if ent, _ := e.entry(alice, dmRequestsCollection, c2); ent.PeerID != DeletedUID {
		t.Errorf("c2 entry peerId = %q", ent.PeerID)
	}
	// The kept messages of the survivor and the untouched conversation are as they were.
	if kept := countSender(e.msgs(c1), alice); kept != 1 {
		t.Errorf("alice's message count in c1 = %d, want 1", kept)
	}
	if c3conv, _ := e.conv(c3); slices.Contains(c3conv.Participants, DeletedUID) || countSender(e.msgs(c3), dave) != 1 {
		t.Errorf("the unaffected conversation changed: %+v", c3conv)
	}

	// Idempotent: nothing left, one empty query, no writes.
	p, c, err = e.migrate("", false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "migrate rerun", c, budgettest.Budget{Reads: 1})
	if p != (PlaceholderPage{}) || c.Writes() != 0 {
		t.Errorf("rerun: page=%+v writes=%d, want nothing", p, c.Writes())
	}
}

// A run that died after the messages and the entry but before the conversation (the conversation is rewritten last) finishes on
// the rerun: the already rewritten documents cost their reads and no writes.
func TestMigratePlaceholder_ResumesAfterAPartialRun(t *testing.T) {
	e := newIT(t, nil)
	c1 := e.seedConversation(alice, bob, stateAccepted, base, [2]string{bob, "x"}, [2]string{alice, "y"})
	e.legacyErase(c1, bob, alice, dmInboxCollection)
	ctx := context.Background()
	// The crash point: messages and entry done, conversation still legacy.
	for mid, m := range e.msgs(c1) {
		if m.SenderID == legacyDeletedUID {
			if _, err := e.fs.Collection("conversations").Doc(c1).Collection("messages").Doc(mid).Update(ctx, []firestore.Update{{Path: "senderId", Value: DeletedUID}}); err != nil {
				t.Fatal(err)
			}
		}
	}
	e.setEntry(alice, dmInboxCollection, c1, firestore.Update{Path: "peerId", Value: DeletedUID})

	p, c, err := e.migrate("", false)
	if err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "migrate resume", c, budgettest.Budget{Reads: 3, Writes: 1})
	if p.Conversations != 1 || p.Messages != 0 || p.Entries != 0 {
		t.Errorf("page = %+v, want the conversation only", p)
	}
	if got, _ := e.conv(c1); slices.Contains(got.Participants, legacyDeletedUID) || !slices.Contains(got.Participants, DeletedUID) {
		t.Errorf("participants = %v", got.Participants)
	}
}

func swapOne(in []string, from, to string) []string {
	out := slices.Clone(in)
	for i, v := range out {
		if v == from {
			out[i] = to
		}
	}
	return out
}

func countSender(m map[string]MsgDoc, uid string) (n int) {
	for _, d := range m {
		if d.SenderID == uid {
			n++
		}
	}
	return n
}

func equalConv(a, b ConvDoc) bool {
	return slices.Equal(a.Participants, b.Participants) && slices.Equal(a.Gone, b.Gone) && a.RequestFrom == b.RequestFrom && a.RequestTo == b.RequestTo && a.UpdatedAt.Equal(b.UpdatedAt)
}
