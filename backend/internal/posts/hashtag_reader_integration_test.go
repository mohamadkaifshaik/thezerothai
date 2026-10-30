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

// Emulator tests for W4-6: ByHashtag (Q-T) and CreatedAfter (Q-W). The emulator does not enforce composite indexes, so
// these prove the query shape; Q-T maps to the existing posts(hashtags CONTAINS, createdAt DESC) composite and Q-W runs
// on the automatic single-field indexes (createdAt ASC, __name__ ASC), so there is no firestore.indexes.json change.

func seedTagged(t *testing.T, client *firestore.Client, id, author string, kind Kind, ms int64, tags ...string) {
	t.Helper()
	seedTabPost(t, client, id, author, kind, ms, 0)
	if kind != KindRepost {
		if _, err := client.Collection(postsCollection).Doc(id).Update(context.Background(), []firestore.Update{{Path: "hashtags", Value: tags}}); err != nil {
			t.Fatal(err)
		}
	}
}

func takeDown(t *testing.T, client *firestore.Client, id string) {
	t.Helper()
	if _, err := client.Collection(postsCollection).Doc(id).Update(context.Background(), []firestore.Update{{Path: "moderation", Value: string(ModerationTakenDown)}}); err != nil {
		t.Fatal(err)
	}
}

func TestRepo_Integration_ByHashtag(t *testing.T) {
	client := newTestClient(t)
	svc, cache := integrationSvc(client)

	// 25 posts tagged #go (ids 1..25, createdAt 1000*n), a #rust post, a #rust+#go post, a REPOST, a hidden post (5).
	for n := 1; n <= 25; n++ {
		seedTagged(t, client, pid(n), "a", KindPost, int64(n)*1000, "go")
	}
	seedTagged(t, client, pid(26), "b", KindPost, 26000, "rust")
	seedTagged(t, client, pid(27), "b", KindPost, 27000, "rust", "go") // newest #go
	seedTagged(t, client, pid(28), "a", KindRepost, 28000)             // REPOST: hashtags [], never matches
	takeDown(t, client, pid(5))

	t.Run("pages of 20 + 6 come newest first; a REPOST and other tags never match; no filtering", func(t *testing.T) {
		ctx, c := measured(context.Background())
		first, err := svc.ByHashtag(ctx, "go", Window{}, 20)
		if err != nil || len(first) != 20 {
			t.Fatalf("first page: %d posts, err %v", len(first), err)
		}
		if first[0].ID != pid(27) || first[1].ID != pid(25) {
			t.Fatalf("order = %v", idList(first[:3]))
		}
		budgettest.Assert(t, "ByHashtag page 1", c, budgettest.Budget{Reads: 20})
		last := first[19]
		ctx2, c2 := measured(context.Background())
		second, err := svc.ByHashtag(ctx2, "go", Window{Before: &Position{CreatedAt: last.CreatedAt, ID: last.ID}}, 20)
		if err != nil {
			t.Fatal(err)
		}
		if len(second) != 6 || second[5].ID != pid(1) {
			t.Fatalf("second page = %v", idList(second))
		}
		budgettest.Assert(t, "ByHashtag page 2", c2, budgettest.Budget{Reads: 6})
		var hidden *Post
		for _, p := range append(first, second...) {
			if p.ID == pid(28) || p.ID == pid(26) {
				t.Errorf("post %s must not match #go", p.ID)
			}
			if p.ID == pid(5) {
				hidden = p
			}
			if _, ok := cache.GetPost(p.ID); !ok {
				t.Errorf("post %s not in the posts cache", p.ID)
			}
		}
		if hidden == nil || !hidden.Hidden() {
			t.Fatalf("a taken-down post must come back with Hidden() true, got %+v", hidden)
		}
	})

	t.Run("After bounds the window and a createdAt tie breaks by id descending", func(t *testing.T) {
		seedTagged(t, client, pid(30), "a", KindPost, 40000, "tie")
		seedTagged(t, client, pid(31), "a", KindPost, 40000, "tie")
		got, err := svc.ByHashtag(context.Background(), "tie", Window{}, 50)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(31), pid(30)}) {
			t.Fatalf("ids = %v err %v", idList(got), err)
		}
		got, err = svc.ByHashtag(context.Background(), "go", Window{After: &Position{CreatedAt: time.UnixMilli(23000).UTC(), ID: pid(23)}}, 50)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(27), pid(25), pid(24)}) {
			t.Fatalf("ids = %v err %v", idList(got), err)
		}
	})

	t.Run("no match bills 1 read", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.ByHashtag(ctx, "nothing", Window{}, 20)
		if err != nil || len(got) != 0 {
			t.Fatalf("got %d err %v", len(got), err)
		}
		budgettest.Assert(t, "ByHashtag empty", c, budgettest.Budget{Reads: 1})
	})
}

func TestRepo_Integration_CreatedAfter(t *testing.T) {
	client := newTestClient(t)
	svc, cache := integrationSvc(client)

	seedTagged(t, client, pid(1), "a", KindPost, 1000, "go")
	seedTagged(t, client, pid(2), "a", KindPost, 2000, "go", "rust")
	seedTagged(t, client, pid(3), "b", KindPost, 3000, "go") // tie with 4
	seedTagged(t, client, pid(4), "c", KindPost, 3000, "rust")
	seedTagged(t, client, pid(5), "a", KindRepost, 4000)
	seedTagged(t, client, pid(6), "b", KindPost, 5000, "go")
	takeDown(t, client, pid(6))

	t.Run("from a watermark: strictly newer, oldest first, ties by id, projected", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.CreatedAfter(ctx, Position{CreatedAt: time.UnixMilli(2000).UTC(), ID: pid(2)}, 500)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(3), pid(4), pid(5), pid(6)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
		budgettest.Assert(t, "CreatedAfter", c, budgettest.Budget{Reads: 4})
		p := got[0]
		if p.AuthorID != "b" || !reflect.DeepEqual(p.Hashtags, []string{"go"}) || !p.CreatedAt.Equal(time.UnixMilli(3000)) || p.Kind != KindPost {
			t.Fatalf("projected fields wrong: %+v", p)
		}
		if p.Text != "" || p.Author.Handle != "" || p.ConversationID != "" {
			t.Fatalf("non-projected fields must be empty: %+v", p)
		}
		if got[2].Kind != KindRepost || len(got[2].Hashtags) != 0 {
			t.Fatalf("REPOST row: %+v", got[2])
		}
		if !got[3].Hidden() || got[0].Hidden() {
			t.Fatal("moderation must be projected: only post 6 is hidden")
		}
		for _, p := range got {
			if _, ok := cache.GetPost(p.ID); ok {
				t.Errorf("projected post %s was put in the posts cache", p.ID)
			}
		}
		if _, ok := cache.AuthorRecent("b"); ok {
			t.Error("projected posts reached the author-recent cache")
		}
	})

	t.Run("a tie: the watermark id decides, and paging by limit loses nothing", func(t *testing.T) {
		got, err := svc.CreatedAfter(context.Background(), Position{CreatedAt: time.UnixMilli(3000).UTC(), ID: pid(3)}, 1)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(4)}) {
			t.Fatalf("ids = %v err %v", idList(got), err)
		}
		got, err = svc.CreatedAfter(context.Background(), Position{CreatedAt: time.UnixMilli(3000).UTC(), ID: pid(4)}, 1)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(5)}) {
			t.Fatalf("ids = %v err %v", idList(got), err)
		}
	})

	t.Run("an empty id bounds on createdAt only (the first run, now minus 24 h)", func(t *testing.T) {
		got, err := svc.CreatedAfter(context.Background(), Position{CreatedAt: time.UnixMilli(3000).UTC()}, 50)
		if err != nil || !reflect.DeepEqual(idList(got), []string{pid(5), pid(6)}) {
			t.Fatalf("ids = %v err %v", idList(got), err)
		}
	})

	t.Run("Limit is honoured and an empty result bills 1", func(t *testing.T) {
		ctx, c := measured(context.Background())
		got, err := svc.CreatedAfter(ctx, Position{CreatedAt: time.UnixMilli(500).UTC(), ID: pid(0)}, 2)
		if err != nil || len(got) != 2 {
			t.Fatalf("got %d err %v", len(got), err)
		}
		budgettest.Assert(t, "CreatedAfter limit 2", c, budgettest.Budget{Reads: 2})
		ctx, c = measured(context.Background())
		got, err = svc.CreatedAfter(ctx, Position{CreatedAt: time.UnixMilli(99000).UTC(), ID: pid(99)}, 500)
		if err != nil || len(got) != 0 {
			t.Fatalf("got %d err %v", len(got), err)
		}
		budgettest.Assert(t, "CreatedAfter empty", c, budgettest.Budget{Reads: 1})
	})
}
