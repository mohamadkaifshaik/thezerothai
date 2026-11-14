//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// childShards sums the replyCount and quoteCount deltas pending on id's shards.
func childShards(t *testing.T, r *FirestoreRepo, id string) (replies, quotes int64) {
	t.Helper()
	tot, err := viewShards.Read(context.Background(), r.client, []*firestore.DocumentRef{r.ref(id)}, replyCountField, quoteCountField)
	if err != nil {
		t.Fatal(err)
	}
	return tot[0].Get(replyCountField), tot[0].Get(quoteCountField)
}

// runCounterRollup is one rollup tick at the real time with the views half off (the counter half always runs).
func runCounterRollup(t *testing.T, r *FirestoreRepo) {
	t.Helper()
	v := &ViewRollup{Repo: r, MinInterval: time.Hour, Off: func() bool { return true }, Now: time.Now}
	if _, err := v.Run(context.Background()); err != nil {
		t.Fatalf("rollup: %v", err)
	}
}

// quoteOf creates uid's QUOTE of quoted through the service.
func (in *createInstance) quoteOf(t *testing.T, uid, key, quoted string) (*Post, error) {
	t.Helper()
	ctx := authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
	if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
		t.Errorf("warm profile: %v", err)
	}
	return in.svc.Create(ctx, uid, CreateInput{IdempotencyKey: key, Text: "my take", QuoteOfPostID: quoted, QuotesEnabled: true})
}

// TestIntegration_HotRepliesAndQuotes: with HOT_COUNTER_THRESHOLD 1, the first reply and the first quote of a root see a
// count of 0 and take the cold path (a plain Increment); every later one sees the parent at or above 1 (the service's
// read) and writes a shard plus a counter marker instead, leaving the plain field behind. One rollup tick folds the
// deltas and the counts are exact: no lost and no doubled write. A second tick moves nothing.
func TestIntegration_HotRepliesAndQuotes(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client)
	in.repo.SetHotCounterThreshold(1)
	in.repo.now = func() time.Time { return time.Now().Add(-time.Hour) } // the markers' window is already foldable
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")
	root, err := in.create(t, "uid-alice", key(1), "root post")
	if err != nil {
		t.Fatal(err)
	}
	const replies, quotes = 4, 3
	k := 10
	for i := range replies {
		in.cache.DeletePost(root.ID) // read the parent's stored count, as another instance would
		if _, err := in.reply(t, "uid-bob", key(k), fmt.Sprintf("reply %d", i), root.ID); err != nil {
			t.Fatalf("reply %d: %v", i, err)
		}
		k++
	}
	for i := range quotes {
		in.cache.DeletePost(root.ID)
		if _, err := in.quoteOf(t, "uid-bob", key(k), root.ID); err != nil {
			t.Fatalf("quote %d: %v", i, err)
		}
		k++
	}
	plainR, plainQ := counts(t, client, root.ID)
	pendR, pendQ := childShards(t, in.repo, root.ID)
	if plainR != 1 || pendR != replies-1 || plainQ != 1 || pendQ != quotes-1 {
		t.Fatalf("before the fold: replies plain %d + pending %d, quotes plain %d + pending %d; want 1 + %d and 1 + %d (one cold write each)",
			plainR, pendR, plainQ, pendQ, replies-1, quotes-1)
	}

	runCounterRollup(t, in.repo)
	if r, q := counts(t, client, root.ID); r != replies || q != quotes {
		t.Fatalf("after the fold: replyCount %d quoteCount %d, want %d %d", r, q, replies, quotes)
	}
	if r, q := childShards(t, in.repo, root.ID); r != 0 || q != 0 {
		t.Fatalf("shards after the fold = %d %d, want drained", r, q)
	}
	runCounterRollup(t, in.repo)
	if r, q := counts(t, client, root.ID); r != replies || q != quotes {
		t.Fatalf("a second tick moved the counts: %d %d", r, q)
	}
}

// TestIntegration_ReplyToGoneParentWritesNothing: a reply or quote whose parent was deleted after the service's read
// answers ErrParentGone and writes nothing, cold (the Update's implicit Exists) and hot (GuardHot's read in the
// transaction): no post, no idempotency doc, no postsCount change, no shard and no counter marker.
func TestIntegration_ReplyToGoneParentWritesNothing(t *testing.T) {
	ctx := context.Background()
	for i, tc := range []struct {
		name      string
		threshold int64
		quote     bool
	}{
		{"cold reply", 0, false},
		{"hot reply", 1, false},
		{"cold quote", 0, true},
		{"hot quote", 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := newTestClient(t)
			in := newCreateInstance(t, client)
			in.repo.SetHotCounterThreshold(tc.threshold)
			in.signUp(t, "uid-bob", "bob")
			gone := pid(4242)
			p := CreateParams{
				AuthorID: "uid-bob", IdemKey: idempotency.Key("uid-bob", createRPC, key(900+i)), RequestHash: "h",
				Draft: Post{AuthorID: "uid-bob", Kind: KindReply, IsReply: true, ReplyToID: gone, Text: "late", Hashtags: []string{},
					Visibility: VisibilityPublic, ConversationID: gone},
				ParentID: gone, ParentReplyCount: 50, // the service read it at 50: hot when the threshold is 1
			}
			if tc.quote {
				p.Draft = Post{AuthorID: "uid-bob", Kind: KindQuote, QuoteOfID: gone, Text: "late", Hashtags: []string{}, Visibility: VisibilityPublic}
				p.ParentID, p.ParentReplyCount, p.QuoteID, p.QuotedQuoteCount = "", 0, gone, 50
			}
			if _, err := in.repo.Create(ctx, p); !errors.Is(err, ErrParentGone) {
				t.Fatalf("create = %v, want ErrParentGone", err)
			}
			if n := countDocs(t, client, postsCollection); n != 0 {
				t.Fatalf("%d posts written", n)
			}
			if n := countDocs(t, client, "idempotency"); n != 0 {
				t.Fatalf("%d idempotency docs written", n)
			}
			if n := countDocs(t, client, viewDirtyCollection); n != 0 {
				t.Fatalf("%d markers written", n)
			}
			if r, q := childShards(t, in.repo, gone); r != 0 || q != 0 {
				t.Fatalf("shards of the gone parent = %d %d", r, q)
			}
			if n := fieldInt(t, client, "users/uid-bob", "postsCount"); n != 0 {
				t.Fatalf("postsCount = %d, want 0", n)
			}
		})
	}
}

// TestIntegration_RecountHotChildrenDrainsShards: recount-replies on a hot post compares plain + pending; with write it
// sets the plain field to the count AND drains the replyCount shards in the same transaction, so the next fold does not
// count the pending deltas twice (a plain set would end at 3 + 2 = 5). The bulk repair does the same for both fields in
// one post write, draining only the stale field: the in-step field's pending delta still folds.
func TestIntegration_RecountHotChildrenDrainsShards(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	ctx := context.Background()
	base := time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)
	single, bulk, inStep := snowID(t, base, 0), snowID(t, base, 1), snowID(t, base, 2)
	seedChild(t, client, single, KindPost, 5, 0, "", "") // plain 5 + pending 2 = 7, but 3 replies
	seedChild(t, client, bulk, KindPost, 4, 0, "", "")   // replies: plain 4 + pending 1 = 5, but 2; quotes: 0 + 1 = 1 (in step)
	seedChild(t, client, inStep, KindPost, 1, 0, "", "") // plain 1 + pending 2 = 3 = its 3 replies
	for i := range 3 {
		seedChild(t, client, snowID(t, base, int64(10+i)), KindReply, 0, 0, single, "")
		seedChild(t, client, snowID(t, base, int64(30+i)), KindReply, 0, 0, inStep, "")
	}
	seedChild(t, client, snowID(t, base, 20), KindReply, 0, 0, bulk, "")
	seedChild(t, client, snowID(t, base, 21), KindReply, 0, 0, bulk, "")
	seedChild(t, client, snowID(t, base, 22), KindQuote, 0, 0, "", bulk)
	t0 := time.Now().Add(-time.Hour)
	seedCounterShard(t, repo, single, replyCountField, 2, t0)
	seedCounterShard(t, repo, bulk, replyCountField, 1, t0)
	seedCounterShard(t, repo, bulk, quoteCountField, 1, t0)
	seedCounterShard(t, repo, inStep, replyCountField, 2, t0)
	stageViewsCommit(t, repo, []string{single}, t0, 4) // views on the same shard docs stay untouched

	got, err := repo.RecountChildren(ctx, inStep, ChildReplies, true)
	if err != nil || got != (ChildRecount{Stored: 3, Pending: 2, Counted: 3}) {
		t.Fatalf("in-step hot recount = %+v, %v; want in step, nothing written", got, err)
	}
	got, err = repo.RecountChildren(ctx, single, ChildReplies, false)
	if err != nil || got != (ChildRecount{Stored: 7, Pending: 2, Counted: 3}) {
		t.Fatalf("dry run = %+v, %v", got, err)
	}
	got, err = repo.RecountChildren(ctx, single, ChildReplies, true)
	if err != nil || got != (ChildRecount{Stored: 7, Pending: 2, Counted: 3, Written: true}) {
		t.Fatalf("write = %+v, %v", got, err)
	}
	if r, _ := counts(t, client, single); r != 3 {
		t.Fatalf("after recount: replyCount %d, want 3", r)
	}
	if r, _ := childShards(t, repo, single); r != 0 {
		t.Fatalf("after recount: pending replies %d, want drained", r)
	}

	c, err := repo.CountChildParent(ctx, ChildParent{ID: bulk, Kind: KindPost, Replies: 4})
	if err != nil || c.Replies != (ChildRecount{Stored: 5, Pending: 1, Counted: 2}) || c.Quotes != (ChildRecount{Stored: 1, Pending: 1, Counted: 1}) || !c.Stale() {
		t.Fatalf("bulk count = %+v, %v", c, err)
	}
	fix, err := repo.RepairChildCounts(ctx, bulk)
	if err != nil || !fix.Replies.Written || fix.Quotes.Written || !fix.Wrote() {
		t.Fatalf("bulk repair = %+v, %v; want replyCount written only", fix, err)
	}
	if r, q := childShards(t, repo, bulk); r != 0 || q != 1 {
		t.Fatalf("after repair: pending %d %d, want replies drained and the in-step quote delta kept", r, q)
	}

	runCounterRollup(t, repo)
	if r, _ := counts(t, client, single); r != 3 {
		t.Fatalf("after the fold: replyCount %d, want 3 (no double count)", r)
	}
	if r, q := counts(t, client, bulk); r != 2 || q != 1 {
		t.Fatalf("after the fold: bulk counts %d %d, want 2 1", r, q)
	}
	if r, _ := counts(t, client, inStep); r != 3 {
		t.Fatalf("after the fold: in-step replyCount %d, want 3", r)
	}
	if v, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{repo.ref(single)}, viewShardField); err != nil || v[0].Get(viewShardField) != 4 {
		t.Fatalf("views on the shards = %v %v, want 4 untouched", v, err)
	}
	c, err = repo.CountChildParent(ctx, ChildParent{ID: bulk, Kind: KindPost, Replies: 2, Quotes: 1})
	if err != nil || c.Stale() {
		t.Fatalf("after the fold the bulk post is stale: %+v %v", c, err)
	}
}

// TestIntegration_PurgeUnderHotParent: an erased user's replies under a hot parent (part of its replyCount still pending
// on its shards) are released by the purge's cold decrements; after the next fold the parent's count is exact.
func TestIntegration_PurgeUnderHotParent(t *testing.T) {
	repo, client := relRepo(t)
	repo.SetHotCounterThreshold(1) // the purge must stay cold whatever the threshold
	parent := pid(1)
	// True count 6: 5 replies of the erased user and 1 of another; plain 3 + pending 3.
	seed := []relPost{
		{id: parent, author: relOther, at: 1, replies: 3},
		{id: pid(2), author: relOther, at: 2, replyTo: parent},
	}
	for i := range 5 {
		seed = append(seed, relPost{id: pid(100 + i), author: relGone, at: 100 + i, replyTo: parent})
	}
	seedRel(t, client, seed...)
	t0 := time.Now().Add(-time.Hour)
	for range 3 {
		seedCounterShard(t, repo, parent, replyCountField, 1, t0)
	}

	purgeAll(t, repo, relGone, Checkpoint{})
	if r, _ := counts(t, client, parent); r != -2 {
		t.Fatalf("after the purge: plain replyCount %d, want 3 - 5 = -2 (cold decrements, the deltas still pending)", r)
	}
	if r, _ := childShards(t, repo, parent); r != 3 {
		t.Fatalf("after the purge: pending %d, want 3 (the purge writes no shard)", r)
	}
	runCounterRollup(t, repo)
	if r, _ := counts(t, client, parent); r != 1 {
		t.Fatalf("after the fold: replyCount %d, want 1 (the other user's reply)", r)
	}
}
