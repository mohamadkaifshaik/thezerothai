//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// Emulator tests for `opsctl backfill-has-media` (ADR-0024 D4, W3-8). The documents are seeded as raw maps: toDoc always
// writes hasMedia (W3-7), so only a raw Set can produce the pre-W3 shape the backfill exists for.

const (
	bfImage    = "1000000000000000001" // legacy POST with one image             -> true
	bfText     = "1000000000000000002" // legacy POST, text only                 -> false
	bfRepost   = "1000000000000000003" // legacy REPOST (images only in embedded) -> false
	bfTrue     = "1000000000000000004" // written after W3-7, hasMedia true     -> untouched
	bfFalse    = "1000000000000000005" // written after W3-7, hasMedia false    -> untouched
	bfQuote    = "1000000000000000006" // legacy QUOTE with two images           -> true
	bfReply    = "1000000000000000007" // legacy REPLY, text only                -> false
	bfOddFalse = "1000000000000000008" // explicit false although it stores media: never overwritten
)

// bfLegacyWant is what the backfill must write for the legacy documents.
var bfLegacyWant = map[string]bool{bfImage: true, bfText: false, bfRepost: false, bfQuote: true, bfReply: false}

func bfImages(n int) []any {
	out := make([]any, n)
	for i := range out {
		out[i] = map[string]any{"mediaId": fmt.Sprintf("m%d", i), "url": "https://x/i.webp", "thumbUrl": "https://x/t.webp", "width": int64(10), "height": int64(10)}
	}
	return out
}

func seedBackfillPosts(t *testing.T, client *firestore.Client) {
	t.Helper()
	docs := map[string]map[string]any{
		bfImage:    {"authorId": "uid-a", "kind": "POST", "text": "legacy image", "media": bfImages(1)},
		bfText:     {"authorId": "uid-a", "kind": "POST", "text": "legacy text"},
		bfRepost:   {"authorId": "uid-b", "kind": "REPOST", "repostOfId": bfImage, "embedded": map[string]any{"postId": bfImage, "media": bfImages(1)}},
		bfTrue:     {"authorId": "uid-a", "kind": "POST", "text": "new image", "media": bfImages(1), "hasMedia": true},
		bfFalse:    {"authorId": "uid-a", "kind": "POST", "text": "new text", "hasMedia": false},
		bfQuote:    {"authorId": "uid-b", "kind": "QUOTE", "text": "legacy quote", "quoteOfId": bfImage, "media": bfImages(2)},
		bfReply:    {"authorId": "uid-b", "kind": "POST", "isReply": true, "text": "legacy reply", "replyToId": bfImage},
		bfOddFalse: {"authorId": "uid-a", "kind": "POST", "text": "odd", "media": bfImages(1), "hasMedia": false},
	}
	for id, d := range docs {
		if _, err := client.Collection(postsCollection).Doc(id).Set(context.Background(), d); err != nil {
			t.Fatalf("seed posts/%s: %v", id, err)
		}
	}
}

// bfSnap reads the raw document.
func bfSnap(t *testing.T, client *firestore.Client, id string) *firestore.DocumentSnapshot {
	t.Helper()
	s, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("get posts/%s: %v", id, err)
	}
	return s
}

// bfRun drives BackfillHasMedia the way opsctl does: from cp until the state is not BackfillMore, on one budget counter.
func bfRun(t *testing.T, r *FirestoreRepo, cp BackfillCheckpoint, opts BackfillOptions) (BackfillCheckpoint, BackfillState, *budget.Counter) {
	t.Helper()
	ctx, c := budget.WithCounter(context.Background())
	for calls := 0; calls < 10_000; calls++ {
		next, state, err := r.BackfillHasMedia(ctx, cp, opts)
		if err != nil {
			t.Fatalf("BackfillHasMedia: %v", err)
		}
		cp = next
		if state != BackfillMore {
			return cp, state, c
		}
	}
	t.Fatal("BackfillHasMedia did not finish")
	return cp, BackfillMore, c
}

// TestBackfillHasMedia_Integration_WritesOnlyMissingAndRerunWritesZero is the ticket's core test: legacy documents get
// HasMediaFor(kind, len(media)); the explicit true and false (and a false that disagrees with its media) are not touched;
// a rerun writes 0.
func TestBackfillHasMedia_Integration_WritesOnlyMissingAndRerunWritesZero(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedBackfillPosts(t, client)
	untouched := map[string]time.Time{}
	for _, id := range []string{bfTrue, bfFalse, bfOddFalse} {
		untouched[id] = bfSnap(t, client, id).UpdateTime
	}

	cp, state, c := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{})
	if state != BackfillDone {
		t.Fatalf("state = %v, want done", state)
	}
	// 8 posts: 8 reads (the short page is the last one: no extra empty query); 5 legacy documents: 5 writes.
	budgettest.Assert(t, "backfill-has-media", c, budgettest.Budget{Reads: 8, Writes: 5, Deletes: 0})
	if c.Reads() != 8 || c.Writes() != 5 || c.Deletes() != 0 {
		t.Errorf("reads/writes/deletes = %d/%d/%d, want 8/5/0", c.Reads(), c.Writes(), c.Deletes())
	}
	if want := (BackfillCheckpoint{After: bfOddFalse, Scanned: 8, Missing: 5, Updated: 5}); cp != want {
		t.Errorf("checkpoint = %+v, want %+v", cp, want)
	}

	for id, want := range bfLegacyWant {
		s := bfSnap(t, client, id)
		got, ok := s.Data()["hasMedia"].(bool)
		if !ok || got != want {
			t.Errorf("posts/%s.hasMedia = %v (present=%v), want %v", id, got, ok, want)
		}
		// Field-level update: the rest of the document survives (a Set would have replaced it).
		if s.Data()["authorId"] == nil || s.Data()["kind"] == nil {
			t.Errorf("posts/%s lost fields: %v", id, s.Data())
		}
	}
	if n := len(bfSnap(t, client, bfQuote).Data()["media"].([]any)); n != 2 {
		t.Errorf("quote media = %d, want 2 (untouched)", n)
	}
	if bfSnap(t, client, bfRepost).Data()["embedded"] == nil {
		t.Error("repost lost its embedded snapshot")
	}
	for id, before := range untouched {
		if after := bfSnap(t, client, id).UpdateTime; !after.Equal(before) {
			t.Errorf("posts/%s was written (UpdateTime %v -> %v), want it untouched", id, before, after)
		}
	}
	if odd, _ := bfSnap(t, client, bfOddFalse).Data()["hasMedia"].(bool); odd {
		t.Error("an explicit false was overwritten")
	}

	// A rerun reads every post again and writes nothing.
	cp2, state2, c2 := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{})
	if state2 != BackfillDone || cp2.Updated != 0 || cp2.Missing != 0 || cp2.Scanned != 8 {
		t.Errorf("rerun = %+v state=%v, want done with scanned 8 and 0 missing/updated", cp2, state2)
	}
	budgettest.Assert(t, "backfill-has-media rerun", c2, budgettest.Budget{Reads: 8, Writes: 0, Deletes: 0})
	if c2.Reads() != 8 || c2.Writes() != 0 {
		t.Errorf("rerun reads/writes = %d/%d, want 8/0", c2.Reads(), c2.Writes())
	}
}

// TestBackfillHasMedia_Integration_DryRunWritesNothing: the same scan and counts, no write.
func TestBackfillHasMedia_Integration_DryRunWritesNothing(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedBackfillPosts(t, client)

	cp, state, c := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{DryRun: true})
	if state != BackfillDone || cp.Scanned != 8 || cp.Missing != 5 || cp.Updated != 0 {
		t.Errorf("dry run = %+v state=%v, want done, scanned 8, missing 5, updated 0", cp, state)
	}
	budgettest.Assert(t, "backfill-has-media dry run", c, budgettest.Budget{Reads: 8, Writes: 0, Deletes: 0})
	if c.Writes() != 0 {
		t.Errorf("dry run writes = %d, want 0", c.Writes())
	}
	for id := range bfLegacyWant {
		if _, present := bfSnap(t, client, id).Data()["hasMedia"]; present {
			t.Errorf("posts/%s was written by a dry run", id)
		}
	}
}

// TestBackfillHasMedia_Integration_CapAndResume: a small page and cap give capped runs whose printed checkpoint resumes the
// work without skipping or rewriting anything; the last resume finishes, and a final rerun writes 0.
func TestBackfillHasMedia_Integration_CapAndResume(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedBackfillPosts(t, client)
	opts := BackfillOptions{PageSize: 3, MaxWrites: 2}
	has := func(id string) bool { _, ok := bfSnap(t, client, id).Data()["hasMedia"].(bool); return ok }

	// Run 1: page 1 is bfImage, bfText, bfRepost. The cap lands on the third legacy post: the checkpoint is the last post
	// decided (bfText), so bfRepost is read again, not skipped, by the resume.
	cp1, state, c1 := bfRun(t, repo, BackfillCheckpoint{}, opts)
	if state != BackfillCapped || cp1.After != bfText || cp1.Updated != 2 || cp1.Scanned != 2 {
		t.Fatalf("run 1 = %+v state=%v, want capped at %s with 2 updated", cp1, state, bfText)
	}
	if c1.Writes() != 2 || c1.Reads() != 3 {
		t.Errorf("run 1 reads/writes = %d/%d, want 3/2", c1.Reads(), c1.Writes())
	}
	if !has(bfImage) || !has(bfText) || has(bfRepost) || has(bfQuote) || has(bfReply) {
		t.Fatal("run 1 must have written exactly the first two legacy posts")
	}

	// Run 2 resumes after bfText with a fresh write allowance and caps again, mid-page, at bfQuote's neighbour.
	cp2, state, _ := bfRun(t, repo, BackfillCheckpoint{After: cp1.After}, opts)
	if state != BackfillCapped || cp2.Updated != 2 || cp2.After != bfQuote {
		t.Fatalf("run 2 = %+v state=%v, want capped after %s with 2 updated", cp2, state, bfQuote)
	}
	if !has(bfRepost) || !has(bfQuote) || has(bfReply) {
		t.Fatal("run 2 must have written bfRepost and bfQuote only")
	}

	// Run 3 finishes.
	cp3, state, c3 := bfRun(t, repo, BackfillCheckpoint{After: cp2.After}, opts)
	if state != BackfillDone || cp3.Updated != 1 || cp3.Missing != 1 {
		t.Fatalf("run 3 = %+v state=%v, want done with 1 updated", cp3, state)
	}
	if c3.Writes() != 1 {
		t.Errorf("run 3 writes = %d, want 1", c3.Writes())
	}
	for id, want := range bfLegacyWant {
		if got, _ := bfSnap(t, client, id).Data()["hasMedia"].(bool); got != want || !has(id) {
			t.Errorf("posts/%s.hasMedia = %v (present=%v), want %v", id, got, has(id), want)
		}
	}

	// The cap alone, with no --after, is also safe: it re-reads from the start and writes 0.
	cp4, state, c4 := bfRun(t, repo, BackfillCheckpoint{}, opts)
	if state != BackfillDone || cp4.Updated != 0 || c4.Writes() != 0 {
		t.Errorf("final rerun = %+v state=%v writes=%d, want done with 0 writes", cp4, state, c4.Writes())
	}
}

// TestBackfillHasMedia_Integration_CapMetOnAFullPageIsCapped: when the write cap is met exactly by the last write of a full
// page, the call reports capped (more may remain) and the next call reads nothing.
func TestBackfillHasMedia_Integration_CapMetOnAFullPageIsCapped(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	seedBackfillPosts(t, client)

	ctx, c := budget.WithCounter(context.Background())
	cp, state, err := repo.BackfillHasMedia(ctx, BackfillCheckpoint{}, BackfillOptions{PageSize: 2, MaxWrites: 2})
	if err != nil || state != BackfillCapped || cp.Updated != 2 || cp.After != bfText {
		t.Fatalf("call 1 = %+v state=%v err=%v, want capped with 2 updated", cp, state, err)
	}
	readsBefore := c.Reads()
	cp2, state2, err := repo.BackfillHasMedia(ctx, cp, BackfillOptions{PageSize: 2, MaxWrites: 2})
	if err != nil || state2 != BackfillCapped || cp2 != cp || c.Reads() != readsBefore {
		t.Errorf("call 2 = %+v state=%v err=%v reads %d -> %d, want the same capped checkpoint and no read", cp2, state2, err, readsBefore, c.Reads())
	}
}

// TestBackfillHasMedia_Integration_MultiPageAtProductionPageSize: 1,001 posts (every third already carries the field) are
// read in pages of 500, 500 and 1, so reads == posts and writes == legacy posts exactly.
func TestBackfillHasMedia_Integration_MultiPageAtProductionPageSize(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	const n = 1001
	legacy := 0
	bw := client.BulkWriter(context.Background())
	for i := 0; i < n; i++ {
		d := map[string]any{"authorId": "uid-a", "kind": "POST", "text": "p"}
		if i%7 == 0 {
			d["media"] = bfImages(1)
		}
		if i%3 == 0 {
			d["hasMedia"] = false
		} else {
			legacy++
		}
		if _, err := bw.Set(client.Collection(postsCollection).Doc(fmt.Sprintf("2%018d", i)), d); err != nil {
			t.Fatal(err)
		}
	}
	bw.End()

	cp, state, c := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{})
	if state != BackfillDone || cp.Scanned != n || cp.Updated != legacy {
		t.Fatalf("run = %+v state=%v, want done, scanned %d, updated %d", cp, state, n, legacy)
	}
	budgettest.Assert(t, "backfill-has-media 1,001 posts", c, budgettest.Budget{Reads: n, Writes: int64(legacy), Deletes: 0})
	if c.Reads() != n || c.Writes() != int64(legacy) {
		t.Errorf("reads/writes = %d/%d, want %d/%d", c.Reads(), c.Writes(), n, legacy)
	}
	_, _, c2 := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{})
	if c2.Writes() != 0 || c2.Reads() != n {
		t.Errorf("rerun reads/writes = %d/%d, want %d/0", c2.Reads(), c2.Writes(), n)
	}
}

func TestBackfillHasMedia_Integration_EmptyCollectionAndBadCheckpoint(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)

	cp, state, c := bfRun(t, repo, BackfillCheckpoint{}, BackfillOptions{})
	if state != BackfillDone || cp != (BackfillCheckpoint{}) || c.Reads() != 1 || c.Writes() != 0 {
		t.Errorf("empty collection = %+v state=%v reads=%d writes=%d, want done, zero checkpoint, 1 read, 0 writes", cp, state, c.Reads(), c.Writes())
	}

	if _, _, err := repo.BackfillHasMedia(context.Background(), BackfillCheckpoint{After: "a/b"}, BackfillOptions{}); !errors.Is(err, ErrInvalidID) {
		t.Errorf("After with a slash: err = %v, want ErrInvalidID", err)
	}
}
