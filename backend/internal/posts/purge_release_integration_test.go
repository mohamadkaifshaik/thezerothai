//go:build integration

package posts

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

const (
	relGone  = "uid-rel-gone"
	relOther = "uid-rel-other"
)

// relPost seeds one post doc with the fields phase 0 reads: authorId, createdAt (newest first), the reply / quote
// target and the two counters.
type relPost struct {
	id, author, replyTo, quoteOf string
	at                           int
	replies, quotes              int64
}

func seedRel(t *testing.T, client *firestore.Client, ps ...relPost) {
	t.Helper()
	for start := 0; start < len(ps); start += 400 {
		b := client.Batch()
		for _, p := range ps[start:min(start+400, len(ps))] {
			d := map[string]any{
				"authorId": p.author, "kind": string(KindPost), "createdAt": time.UnixMilli(1_700_000_000_000 + int64(p.at)).UTC(),
				"replyCount": p.replies, "quoteCount": p.quotes, "visibility": string(VisibilityPublic),
			}
			if p.replyTo != "" {
				d["replyToId"], d["isReply"] = p.replyTo, true
			}
			if p.quoteOf != "" {
				d["quoteOfId"], d["kind"] = p.quoteOf, string(KindQuote)
			}
			b.Set(client.Collection(postsCollection).Doc(p.id), d)
		}
		if _, err := b.Commit(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
}

func relRepo(t *testing.T) (*FirestoreRepo, *firestore.Client) {
	t.Helper()
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	withCopyPhase(repo, client)
	return repo, client
}

// purgeAll runs PurgeUser to done (bounded) and returns the final checkpoint and the number of calls.
func purgeAll(t *testing.T, repo *FirestoreRepo, uid string, cp Checkpoint) (Checkpoint, int) {
	t.Helper()
	for calls := 1; calls <= 20; calls++ {
		next, done, err := repo.PurgeUser(context.Background(), uid, cp)
		if err != nil {
			t.Fatalf("PurgeUser call %d: %v", calls, err)
		}
		cp = next
		if done {
			return cp, calls
		}
	}
	t.Fatal("purge did not finish in 20 calls")
	return cp, 0
}

func postGone(t *testing.T, client *firestore.Client, id string) bool {
	t.Helper()
	snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	return err != nil || !snap.Exists()
}

func counts(t *testing.T, client *firestore.Client, id string) (replies, quotes int64) {
	t.Helper()
	return fieldInt(t, client, postsCollection+"/"+id, "replyCount"), fieldInt(t, client, postsCollection+"/"+id, "quoteCount")
}

// TestPurgeUser_ReleasesReplyAndQuoteCounts (regression): erasing an account lowers the replyCount and quoteCount its
// replies and quotes held on other users' posts, across more than one page, and leaves the other users' own replies
// counted. A self-thread (the user's reply to their own post) costs no counter write on a post that dies with it.
func TestPurgeUser_ReleasesReplyAndQuoteCounts(t *testing.T) {
	repo, client := relRepo(t)
	parent, quoted, keep := pid(1), pid(2), pid(3)
	n := purgeOwnPage + 10 // two pages of replies to one parent
	seed := []relPost{
		{id: parent, author: relOther, at: 1, replies: int64(n) + 1},
		{id: quoted, author: relOther, at: 2, quotes: 3},
		{id: keep, author: relOther, at: 3, replyTo: parent},   // another user's reply: stays counted
		{id: pid(4), author: relOther, at: 4, quoteOf: quoted}, // another user's quote: stays counted
		{id: pid(5), author: relGone, at: 5, quoteOf: quoted},  // the user's quotes
		{id: pid(6), author: relGone, at: 6, quoteOf: quoted},
		{id: pid(7), author: relGone, at: 7, replies: 1},      // the user's own root ...
		{id: pid(8), author: relGone, at: 8, replyTo: pid(7)}, // ... and self-reply, in the same page
	}
	for i := range n {
		seed = append(seed, relPost{id: pid(100 + i), author: relGone, at: 100 + i, replyTo: parent})
	}
	seedRel(t, client, seed...)

	cp, calls := purgeAll(t, repo, relGone, Checkpoint{})
	if cp.Deleted != n+4 {
		t.Fatalf("deleted = %d, want %d", cp.Deleted, n+4)
	}
	if calls < 3 {
		t.Fatalf("finished in %d calls; %d posts must take two phase-0 pages", calls, n+4)
	}
	if r, q := counts(t, client, parent); r != 1 || q != 0 {
		t.Errorf("parent counts = %d replies, %d quotes; want 1, 0 (only the other user's reply)", r, q)
	}
	if r, q := counts(t, client, quoted); r != 0 || q != 1 {
		t.Errorf("quoted counts = %d replies, %d quotes; want 0, 1 (only the other user's quote)", r, q)
	}
	for _, id := range []string{pid(5), pid(6), pid(7), pid(8), pid(100), pid(100 + n - 1)} {
		if !postGone(t, client, id) {
			t.Errorf("the user's post %s survived", id)
		}
	}
	if postGone(t, client, keep) || postGone(t, client, pid(4)) {
		t.Error("another user's post was deleted")
	}
}

// TestPurgeUser_MissingTargetFallsBack: a reply whose parent and a quote whose quoted post are already deleted fail the
// page batch's implicit Exists precondition; the per-doc fallback deletes them without a counter and still lowers the
// counters of the targets that exist, without creating the missing ones.
func TestPurgeUser_MissingTargetFallsBack(t *testing.T) {
	repo, client := relRepo(t)
	live := pid(1)
	seedRel(t, client,
		relPost{id: live, author: relOther, at: 1, replies: 2, quotes: 1},
		relPost{id: pid(10), author: relGone, at: 10, replyTo: pid(900)}, // parent already gone
		relPost{id: pid(11), author: relGone, at: 11, replyTo: live},
		relPost{id: pid(12), author: relGone, at: 12, quoteOf: pid(901)}, // quoted post already gone
		relPost{id: pid(13), author: relGone, at: 13, quoteOf: live},
		relPost{id: pid(14), author: relGone, at: 14, replyTo: live},
	)
	cp, _ := purgeAll(t, repo, relGone, Checkpoint{})
	if cp.Deleted != 5 {
		t.Fatalf("deleted = %d, want 5", cp.Deleted)
	}
	if r, q := counts(t, client, live); r != 0 || q != 0 {
		t.Errorf("live target counts = %d, %d; want 0, 0", r, q)
	}
	for _, id := range []string{pid(10), pid(11), pid(12), pid(13), pid(14), pid(900), pid(901)} {
		if !postGone(t, client, id) {
			t.Errorf("post %s exists after the purge", id)
		}
	}
}

// TestPurgeUser_RedeliveryNeverDecrementsTwice: a crash after the page commit but before the checkpoint is stored
// re-runs phase 0 from the old checkpoint, and a stale or racing run still holding the same page snapshot commits it
// again. Neither lowers a counter a second time, on the page-batch path or on the per-doc fallback path.
func TestPurgeUser_RedeliveryNeverDecrementsTwice(t *testing.T) {
	for _, tc := range []struct {
		name    string
		missing bool // a gone target in the page forces the per-doc fallback
	}{{"page batch", false}, {"per-doc fallback", true}} {
		t.Run(tc.name, func(t *testing.T) {
			repo, client := relRepo(t)
			ctx := context.Background()
			target := pid(1)
			seed := []relPost{
				{id: target, author: relOther, at: 1, replies: 5, quotes: 5},
				{id: pid(20), author: relGone, at: 20, replyTo: target},
				{id: pid(21), author: relGone, at: 21, replyTo: target},
				{id: pid(22), author: relGone, at: 22, quoteOf: target},
			}
			if tc.missing {
				seed = append(seed, relPost{id: pid(23), author: relGone, at: 23, replyTo: pid(999)})
			}
			seedRel(t, client, seed...)
			stale, err := repo.authorQuery(relGone).Select(fieldReplyToID, fieldQuoteOfID).Limit(purgeOwnPage).Documents(ctx).GetAll()
			if err != nil {
				t.Fatal(err)
			}
			deleted, _, err := repo.purgeOwn(ctx, relGone, stale)
			if err != nil || deleted != len(seed)-1 {
				t.Fatalf("first run: deleted %d err %v, want %d", deleted, err, len(seed)-1)
			}
			check := func(when string) {
				t.Helper()
				if r, q := counts(t, client, target); r != 3 || q != 4 {
					t.Fatalf("%s: target counts = %d, %d; want 3, 4 (one decrement per deleted post)", when, r, q)
				}
			}
			check("after the first run")
			// The same snapshot again (a racing delivery read the page before the first commit).
			if deleted, released, err := repo.purgeOwn(ctx, relGone, stale); err != nil || deleted != 0 || released != 0 {
				t.Fatalf("stale re-run: deleted %d released %d err %v, want 0 0 nil", deleted, released, err)
			}
			check("after the stale re-run")
			// The checkpoint write was lost: the job resumes from the zero checkpoint.
			cp, _ := purgeAll(t, repo, relGone, Checkpoint{})
			if cp.Deleted != 0 {
				t.Fatalf("resumed purge deleted %d, want 0 (the page is gone)", cp.Deleted)
			}
			check("after the resumed purge")
		})
	}
}

// TestRecountChildren_Integration: the recount counts every reply or quote doc of the post and, with write, repairs the
// stored counter in one transaction; without write it changes nothing; a missing post is ErrNotFound.
func TestRecountChildren_Integration(t *testing.T) {
	repo, client := relRepo(t)
	ctx := context.Background()
	target := pid(1)
	seedRel(t, client,
		relPost{id: target, author: relOther, at: 1, replies: 7, quotes: 1},
		relPost{id: pid(30), author: relOther, at: 30, replyTo: target},
		relPost{id: pid(31), author: relGone, at: 31, replyTo: target},
		relPost{id: pid(32), author: relGone, at: 32, quoteOf: target},
		relPost{id: pid(33), author: relGone, at: 33, quoteOf: pid(2)},
	)
	got, err := repo.RecountChildren(ctx, target, ChildReplies, false)
	if err != nil || got != (ChildRecount{Stored: 7, Counted: 2}) {
		t.Fatalf("dry run = %+v, %v; want stored 7 counted 2", got, err)
	}
	if r, _ := counts(t, client, target); r != 7 {
		t.Fatalf("dry run wrote replyCount = %d", r)
	}
	got, err = repo.RecountChildren(ctx, target, ChildReplies, true)
	if err != nil || got != (ChildRecount{Stored: 7, Counted: 2, Written: true}) {
		t.Fatalf("write = %+v, %v", got, err)
	}
	if r, q := counts(t, client, target); r != 2 || q != 1 {
		t.Fatalf("after write counts = %d, %d; want 2, 1 (quoteCount untouched)", r, q)
	}
	got, err = repo.RecountChildren(ctx, target, ChildQuotes, true)
	if err != nil || got != (ChildRecount{Stored: 1, Counted: 1}) {
		t.Fatalf("quotes in step = %+v, %v; want no write", got, err)
	}
	if _, err := repo.RecountChildren(ctx, pid(404), ChildReplies, true); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing post err = %v, want ErrNotFound", err)
	}
	if !postGone(t, client, pid(404)) {
		t.Fatal("the recount created the missing post")
	}
}
