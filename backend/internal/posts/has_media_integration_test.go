//go:build integration

package posts

import (
	"context"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// Emulator tests for ADR-0024 D4/D5 (W3-7): hasMedia is written, as an explicit boolean, by every create path, and the two
// tab queries return the right posts in the right order within their read budget. The emulator does not enforce composite
// indexes, so these prove the query shape (filters, order, window, Limit) and the stored field names; the shapes map to the
// W3-2 indexes in firebase/firestore.indexes.json (see repo_firestore.go Q-M and Q-B).

// storedHasMedia reads the raw posts/{id} document: the value of hasMedia and whether the key exists at all (the backfill
// and "rerun writes 0" depend on a written false being present and a pre-W3 doc being absent).
func storedHasMedia(t *testing.T, client *firestore.Client, id string) (value, present bool) {
	t.Helper()
	snap, err := client.Collection(postsCollection).Doc(id).Get(context.Background())
	if err != nil {
		t.Fatalf("get posts/%s: %v", id, err)
	}
	v, ok := snap.Data()["hasMedia"]
	if !ok {
		return false, false
	}
	b, isBool := v.(bool)
	if !isBool {
		t.Fatalf("posts/%s.hasMedia = %#v, want a bool", id, v)
	}
	return b, true
}

func seedReadyMedia(t *testing.T, client *firestore.Client, owner string, n int) string {
	t.Helper()
	id := sweepMediaID(n)
	if _, err := client.Collection("media").Doc(id).Set(context.Background(), map[string]any{"ownerId": owner, "status": "READY"}); err != nil {
		t.Fatal(err)
	}
	return id
}

// TestHasMedia_Integration_CreatePostPaths: CreatePost root, reply and quote store hasMedia = (own media non-empty) in the same
// write, as an explicit false for a text-only post, and a quote of an image post without an image of its own is false.
func TestHasMedia_Integration_CreatePostPaths(t *testing.T) {
	client := newTestClient(t)
	in := newCreateInstance(t, client, time.Nanosecond)
	in.repo.w.Media = &sweepMedia{client: client}
	in.signUp(t, "uid-alice", "alice")
	in.signUp(t, "uid-bob", "bob")

	create := func(uid string, n int, mut func(*CreateInput)) *Post {
		t.Helper()
		if _, err := in.svc.directory.GetProfiles(context.Background(), []string{uid}); err != nil {
			t.Fatal(err)
		}
		ci := CreateInput{IdempotencyKey: key(n), Text: "post " + key(n), MediaEnabled: true, RepliesEnabled: true, QuotesEnabled: true}
		mut(&ci)
		ctx, c := measured(googleCtx(context.Background(), uid))
		p, err := in.svc.Create(ctx, uid, ci)
		if err != nil {
			t.Fatalf("Create %d: %v", n, err)
		}
		// +0 writes: hasMedia rides the post document. A root is idempotency + post + postsCount + quotas (4), a reply adds
		// the parent's replyCount (5), a quote adds the quoted post's quoteCount (5); each image adds its media.postId.
		wantWrites := int64(4)
		if ci.ReplyToPostID != "" || ci.QuoteOfPostID != "" {
			wantWrites++
		}
		wantWrites += int64(len(ci.MediaIDs))
		if c.Writes() != wantWrites {
			t.Errorf("Create %d: writes = %d, want %d (hasMedia must add none)", n, c.Writes(), wantWrites)
		}
		return p
	}
	rootImg := create("uid-alice", 1, func(ci *CreateInput) { ci.MediaIDs = []string{seedReadyMedia(t, client, "uid-alice", 1)} })
	rootText := create("uid-alice", 2, func(ci *CreateInput) {})
	replyImg := create("uid-bob", 3, func(ci *CreateInput) {
		ci.ReplyToPostID, ci.MediaIDs = rootText.ID, []string{seedReadyMedia(t, client, "uid-bob", 2)}
	})
	replyText := create("uid-bob", 4, func(ci *CreateInput) { ci.ReplyToPostID = rootText.ID })
	quoteImg := create("uid-bob", 5, func(ci *CreateInput) {
		ci.QuoteOfPostID, ci.MediaIDs = rootImg.ID, []string{seedReadyMedia(t, client, "uid-bob", 3)}
	})
	quoteOfImage := create("uid-bob", 6, func(ci *CreateInput) { ci.QuoteOfPostID = rootImg.ID })
	multi := create("uid-alice", 7, func(ci *CreateInput) {
		ci.MediaIDs = []string{
			seedReadyMedia(t, client, "uid-alice", 4), seedReadyMedia(t, client, "uid-alice", 5),
			seedReadyMedia(t, client, "uid-alice", 6), seedReadyMedia(t, client, "uid-alice", 7),
		}
	})

	tests := []struct {
		name string
		p    *Post
		want bool
	}{
		{"root with an image", rootImg, true},
		{"root text only", rootText, false},
		{"reply with an image", replyImg, true},
		{"reply text only", replyText, false},
		{"quote with its own image", quoteImg, true},
		{"quote of an image post, no image of its own", quoteOfImage, false},
		{"root with four images", multi, true},
	}
	read, err := in.repo.GetAll(context.Background(), []string{rootImg.ID, rootText.ID, replyImg.ID, replyText.ID, quoteImg.ID, quoteOfImage.ID, multi.ID})
	if err != nil {
		t.Fatal(err)
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got, present := storedHasMedia(t, client, tt.p.ID); !present || got != tt.want {
				t.Fatalf("stored hasMedia = (%v, present %v), want (%v, present true)", got, present, tt.want)
			}
			if tt.p.HasMedia != tt.want || (len(tt.p.Media) > 0) != tt.want {
				t.Fatalf("returned post HasMedia=%v len(Media)=%d, want hasMedia %v", tt.p.HasMedia, len(tt.p.Media), tt.want)
			}
			if got := read[tt.p.ID]; got == nil || got.HasMedia != tt.want {
				t.Fatalf("read back = %+v, want HasMedia %v", got, tt.want)
			}
			if cached, ok := in.cache.GetPost(tt.p.ID); ok && cached.HasMedia != tt.want {
				t.Fatalf("cached copy HasMedia = %v, want %v (the cache is filled from the written data)", cached.HasMedia, tt.want)
			}
		})
	}
}

// TestHasMedia_Integration_PublishSweep: the ADR-0021 publish sweep writes hasMedia like CreatePost (true with a draft image,
// an explicit false without), in the same 4 + n writes as before.
func TestHasMedia_Integration_PublishSweep(t *testing.T) {
	e := newSweepIT(t)
	e.signUp("uid-alice", "alice")
	e.seedMedia("uid-alice", nil, 1)
	withImage := e.seedDue("uid-alice", 1, func(p *ScheduledPost) {
		p.Draft = &ScheduledDraft{Text: "a picture", Media: []MediaRef{{ID: sweepMediaID(1)}}}
	})
	textOnly := e.seedDue("uid-alice", 2)

	res, c := e.sweep()
	if res.Outcome != SweepOK || res.Published != 2 || len(res.Failed) != 0 {
		t.Fatalf("sweep: %+v, want 2 published", res)
	}
	t.Logf("two publishes cost %d reads %d writes", c.Reads(), c.Writes())
	// The publish budgets are pinned by TestSweepIT_PublishBudget; this one only guards that hasMedia added no write: the
	// image post writes post + postsCount + quotas + scheduled + media.postId = 5, the text-only one the same minus the media = 4.
	if c.Writes() != 5+4 {
		t.Errorf("writes = %d, want 9 (hasMedia rides the post document)", c.Writes())
	}
	for _, tt := range []struct {
		name string
		it   *ScheduledPost
		want bool
	}{{"draft with an image", withImage, true}, {"text-only draft", textOnly, false}} {
		postID, _ := e.raw(tt.it)["postId"].(string)
		if postID == "" {
			t.Fatalf("%s: not published", tt.name)
		}
		if got, present := storedHasMedia(t, e.client, postID); !present || got != tt.want {
			t.Errorf("%s: stored hasMedia = (%v, present %v), want (%v, present true)", tt.name, got, present, tt.want)
		}
	}
}

// TestHasMedia_Integration_RepostDocIsAlwaysFalse: the REPOST document (written through StageRepost by engagement's
// transaction) stores an explicit hasMedia=false even when the original has images: those live in `embedded`.
func TestHasMedia_Integration_RepostDocIsAlwaysFalse(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client)
	original := &Post{ID: pid(1), AuthorID: "a", Author: AuthorSnapshot{UserID: "a"}, Kind: KindPost, Media: []MediaRef{{ID: pid(90), URL: "https://x/1"}}, CreatedAt: time.UnixMilli(1000).UTC()}
	repost := NewRepostPost(pid(2), time.UnixMilli(2000).UTC(), AuthorSnapshot{UserID: "b"}, 1, original)
	if _, err := client.Batch().Create(repo.ref(repost.ID), toDoc(repost)).Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, present := storedHasMedia(t, client, repost.ID); !present || got {
		t.Fatalf("REPOST stored hasMedia = (%v, present %v), want (false, present true)", got, present)
	}
	snap, err := client.Collection(postsCollection).Doc(repost.ID).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if emb, _ := snap.Data()["embedded"].(map[string]any); emb == nil || emb["media"] == nil {
		t.Fatalf("test setup: the original's image should be in the embed, got %v", emb)
	}
}

// seedTabPost writes a post through toDoc (the production write mapping) with the given kind and image count. A REPOST
// embeds an original that carries the images, like a real one.
func seedTabPost(t *testing.T, client *firestore.Client, id, author string, kind Kind, ms int64, images int) {
	t.Helper()
	p := &Post{
		ID: id, AuthorID: author, Author: AuthorSnapshot{UserID: author, Handle: "h_" + author}, Kind: kind,
		Text: "text " + id, ConversationID: id, Visibility: VisibilityPublic, CreatedAt: time.UnixMilli(ms).UTC(),
		IsReply: kind == KindReply,
	}
	for i := 0; i < images; i++ {
		p.Media = append(p.Media, MediaRef{ID: pid(900 + i), URL: "https://x/" + id, ThumbURL: "https://x/t" + id})
	}
	if kind == KindRepost {
		original := &Post{ID: pid(999), AuthorID: "o", Author: AuthorSnapshot{UserID: "o"}, Kind: KindPost, Media: p.Media}
		p = NewRepostPost(id, p.CreatedAt, p.Author, 1, original)
	}
	if _, err := client.Collection(postsCollection).Doc(id).Set(context.Background(), toDoc(p)); err != nil {
		t.Fatalf("seed %s: %v", id, err)
	}
}

// TestRepo_Integration_TabQueries runs Q-M (ByAuthorMedia) and Q-B (ByAuthorKind) against the emulator: filters, the explicit
// `createdAt DESC, __name__ DESC` order with a createdAt tie, windows, Limit and the read budget (len(result), 1 when empty).
func TestRepo_Integration_TabQueries(t *testing.T) {
	client := newTestClient(t)
	svc, cache := integrationSvc(client)

	// author a: 1 root+image, 2 root text, 3 reply+image, 4 quote+image, 5 REPOST (of an image post), 6 and 7 root+image
	// sharing createdAt (the tie), 8 a pre-W3 doc with an image but no hasMedia field, 10 REPOST (of a text post).
	// author b: 9 root+image.
	seedTabPost(t, client, pid(1), "a", KindPost, 1000, 1)
	seedTabPost(t, client, pid(2), "a", KindPost, 2000, 0)
	seedTabPost(t, client, pid(3), "a", KindReply, 3000, 1)
	seedTabPost(t, client, pid(4), "a", KindQuote, 4000, 1)
	seedTabPost(t, client, pid(5), "a", KindRepost, 5000, 1)
	seedTabPost(t, client, pid(6), "a", KindPost, 6000, 2)
	seedTabPost(t, client, pid(7), "a", KindPost, 6000, 1) // tie with 6
	seedTabPost(t, client, pid(8), "a", KindPost, 7000, 1)
	// 8 becomes a pre-W3 document: every field it has today, minus hasMedia.
	if _, err := client.Collection(postsCollection).Doc(pid(8)).Update(context.Background(), []firestore.Update{{Path: "hasMedia", Value: firestore.Delete}}); err != nil {
		t.Fatal(err)
	}
	seedTabPost(t, client, pid(9), "b", KindPost, 8000, 1)
	seedTabPost(t, client, pid(10), "a", KindRepost, 9000, 0)
	if _, present := storedHasMedia(t, client, pid(8)); present {
		t.Fatal("test setup: the legacy doc must lack hasMedia")
	}

	t.Run("Q-M media tab: own images only, newest first, tie by __name__ DESC, no REPOST, no legacy doc", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.ByAuthorMedia(ctx, "a", Window{}, 50)
		if err != nil {
			t.Fatal(err)
		}
		want := []string{pid(7), pid(6), pid(4), pid(3), pid(1)}
		if !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
		for _, p := range got {
			if !p.HasMedia || len(p.Media) == 0 {
				t.Errorf("post %s: HasMedia=%v media=%d, want both set", p.ID, p.HasMedia, len(p.Media))
			}
			if _, ok := cache.GetPost(p.ID); !ok {
				t.Errorf("post %s was not put in the posts cache", p.ID)
			}
		}
		budgettest.Assert(t, "ByAuthorMedia", c, budgettest.Budget{Reads: int64(len(want))})
		if c.Reads() != int64(len(want)) || c.Writes() != 0 {
			t.Fatalf("cost = %d reads %d writes, want %d and 0", c.Reads(), c.Writes(), len(want))
		}
	})

	t.Run("Q-M pages with Before and never skips or repeats the tie", func(t *testing.T) {
		var all []string
		var before *Position
		for page := 0; page < 10; page++ {
			got, err := svc.ByAuthorMedia(context.Background(), "a", Window{Before: before}, 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) == 0 {
				break
			}
			all = append(all, idList(got)...)
			last := got[len(got)-1]
			before = &Position{CreatedAt: last.CreatedAt, ID: last.ID}
		}
		if want := []string{pid(7), pid(6), pid(4), pid(3), pid(1)}; !reflect.DeepEqual(all, want) {
			t.Fatalf("paged ids = %v, want %v", all, want)
		}
	})

	t.Run("Q-M After bound stops strictly above it, Before and After bound a gap", func(t *testing.T) {
		got, err := svc.ByAuthorMedia(context.Background(), "a", Window{After: &Position{CreatedAt: time.UnixMilli(3000).UTC(), ID: pid(3)}}, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(7), pid(6), pid(4)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("After: ids = %v, want %v", idList(got), want)
		}
		w := Window{
			Before: &Position{CreatedAt: time.UnixMilli(6000).UTC(), ID: pid(6)},
			After:  &Position{CreatedAt: time.UnixMilli(1000).UTC(), ID: pid(1)},
		}
		got, err = svc.ByAuthorMedia(context.Background(), "a", w, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(4), pid(3)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("Before+After: ids = %v, want %v", idList(got), want)
		}
	})

	t.Run("Q-M respects Limit", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.ByAuthorMedia(ctx, "a", Window{}, 2)
		if err != nil || len(got) != 2 {
			t.Fatalf("got=%d err=%v", len(got), err)
		}
		budgettest.Assert(t, "ByAuthorMedia limit 2", c, budgettest.Budget{Reads: 2})
		if c.Reads() != 2 {
			t.Fatalf("reads = %d, want 2", c.Reads())
		}
	})

	t.Run("Q-M another author and an author with no media", func(t *testing.T) {
		got, err := svc.ByAuthorMedia(context.Background(), "b", Window{}, 50)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(9)}) {
			t.Fatalf("b: ids=%v err=%v, want [%s]", idList(got), err, pid(9))
		}
		ctx, c := measured(context.Background())
		got, err = svc.ByAuthorMedia(ctx, "nobody", Window{}, 20)
		if err != nil || len(got) != 0 {
			t.Fatalf("nobody: got=%v err=%v", got, err)
		}
		budgettest.Assert(t, "ByAuthorMedia empty", c, budgettest.Budget{Reads: 1})
		if c.Reads() != 1 {
			t.Fatalf("an empty query must bill 1 read, got %d", c.Reads())
		}
	})

	t.Run("Q-B reposts tab: only kind REPOST, newest first", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.ByAuthorKind(ctx, "a", KindRepost, Window{}, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(10), pid(5)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
		for _, p := range got {
			if p.Kind != KindRepost || p.HasMedia || p.Embedded == nil {
				t.Errorf("post %s: kind=%s HasMedia=%v embedded=%v, want a REPOST with hasMedia false and its embed", p.ID, p.Kind, p.HasMedia, p.Embedded)
			}
		}
		budgettest.Assert(t, "ByAuthorKind", c, budgettest.Budget{Reads: 2})
		if c.Reads() != 2 {
			t.Fatalf("reads = %d, want 2", c.Reads())
		}
	})

	t.Run("Q-B pages with Before", func(t *testing.T) {
		first, err := svc.ByAuthorKind(context.Background(), "a", KindRepost, Window{}, 1)
		if err != nil || !reflect.DeepEqual(idList(first), []string{pid(10)}) {
			t.Fatalf("first page ids=%v err=%v", idList(first), err)
		}
		next, err := svc.ByAuthorKind(context.Background(), "a", KindRepost, Window{Before: &Position{CreatedAt: first[0].CreatedAt, ID: first[0].ID}}, 1)
		if err != nil || !reflect.DeepEqual(idList(next), []string{pid(5)}) {
			t.Fatalf("second page ids=%v err=%v", idList(next), err)
		}
	})

	t.Run("Q-B no reposts costs 1 read, and another kind uses the same index shape", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.ByAuthorKind(ctx, "b", KindRepost, Window{}, 20)
		if err != nil || len(got) != 0 {
			t.Fatalf("b reposts: got=%v err=%v", got, err)
		}
		budgettest.Assert(t, "ByAuthorKind empty", c, budgettest.Budget{Reads: 1})
		quotes, err := svc.ByAuthorKind(context.Background(), "a", KindQuote, Window{}, 20)
		if err != nil || !reflect.DeepEqual(idList(quotes), []string{pid(4)}) {
			t.Fatalf("a quotes: ids=%v err=%v", idList(quotes), err)
		}
	})
}
