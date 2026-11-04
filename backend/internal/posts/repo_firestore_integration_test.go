//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"reflect"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

func newTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

// seedPost writes posts/{id} with createdAt = ms (the Snowflake millisecond) and returns the domain post.
func seedPost(t *testing.T, client *firestore.Client, id, author string, reply bool, ms int64) *Post {
	t.Helper()
	p := &Post{
		ID: id, AuthorID: author,
		Author:         AuthorSnapshot{UserID: author, Handle: "h_" + author, DisplayName: "N " + author, AvatarURL: "https://x/a.webp", Verified: true},
		Kind:           KindPost,
		IsReply:        reply,
		Text:           "text " + id,
		ConversationID: id,
		Hashtags:       []string{"go"},
		Mentions:       []Mention{{UserID: "m1", Handle: "mm1"}},
		LikeCount:      1, RepostCount: 2, ReplyCount: 3, QuoteCount: 4,
		Visibility: VisibilityPublic, SnapshotVersion: 7,
		CreatedAt: time.UnixMilli(ms).UTC(),
	}
	if reply {
		p.Kind, p.ReplyToID, p.ReplyToHandle, p.ConversationID = KindReply, "0000000000000000001", "root", "0000000000000000001"
	}
	if _, err := client.Collection(postsCollection).Doc(id).Set(context.Background(), toDoc(p)); err != nil {
		t.Fatalf("seed %s: %v", id, err)
	}
	return p
}

func pid(n int) string { return fmt.Sprintf("%019d", n) }

func integrationSvc(client *firestore.Client) (*service, *Cache) {
	cache := NewCache(time.Minute, 0, 0)
	return New(Deps{Repo: NewFirestoreRepo(client), Cache: cache}).(*service), cache
}

func idList(ps []*Post) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.ID
	}
	return out
}

// TestRepo_Integration_DocRoundTrip: every stored field survives a write and a read, including the nested
// author snapshot and mentions.
func TestRepo_Integration_DocRoundTrip(t *testing.T) {
	client := newTestClient(t)
	want := seedPost(t, client, pid(5), "a", false, 5000)
	repo := NewFirestoreRepo(client)
	got, err := repo.GetAll(context.Background(), []string{want.ID})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got[want.ID], want) {
		t.Fatalf("round trip differs:\n got %+v\nwant %+v", got[want.ID], want)
	}
	reply := seedPost(t, client, pid(6), "a", true, 6000)
	got, _ = repo.GetAll(context.Background(), []string{reply.ID})
	if !reflect.DeepEqual(got[reply.ID], reply) {
		t.Fatalf("reply round trip differs:\n got %+v\nwant %+v", got[reply.ID], reply)
	}
}

// TestRepo_Integration_GetManyAndAbsence: 20 ids with 12 cached all come back; a missing id is NOT_FOUND, and
// absence is not cached, so a post created afterwards is found at once.
func TestRepo_Integration_GetManyAndAbsence(t *testing.T) {
	client := newTestClient(t)
	svc, cache := integrationSvc(client)
	var ids []string
	for i := 1; i <= 20; i++ {
		p := seedPost(t, client, pid(i), "a", false, int64(1000+i))
		ids = append(ids, p.ID)
		if i <= 12 {
			cache.SetPost(p)
		}
	}
	ctx := context.Background()
	got, err := svc.GetMany(ctx, ids)
	if err != nil || len(got) != 20 {
		t.Fatalf("GetMany: len=%d err=%v", len(got), err)
	}

	for range 2 {
		if _, err := svc.Get(ctx, pid(999)); !errors.Is(err, ErrNotFound) {
			t.Fatalf("missing post: err = %v, want ErrNotFound", err)
		}
	}
	seedPost(t, client, pid(999), "a", false, 1999)
	if p, err := svc.Get(ctx, pid(999)); err != nil || p == nil {
		t.Fatalf("post created after two misses: p=%v err=%v, want it found (absence must not be cached)", p, err)
	}
	if _, err := svc.Get(ctx, pid(3)); err != nil {
		t.Fatalf("cached post: %v", err)
	}
}

// TestRepo_Integration_QueryShapes runs Q-H, Q-P and Q-R with the explicit `createdAt DESC, __name__ DESC`
// order against the emulator (the emulator does not enforce composite indexes; the shapes map to the declared
// ones, see repo_firestore.go) and checks order, the isReply filter, windows and limits.
func TestRepo_Integration_QueryShapes(t *testing.T) {
	client := newTestClient(t)
	svc, _ := integrationSvc(client)

	// a: roots 1,2,3 and a reply 4; b: roots 5,6; c: root 7. Two posts share createdAt (ties on 2 and 3) so the
	// __name__ tie-breaker decides their order.
	seedPost(t, client, pid(1), "a", false, 1000)
	seedPost(t, client, pid(2), "a", false, 2000)
	seedPost(t, client, pid(3), "a", false, 2000) // tie with 2
	seedPost(t, client, pid(4), "a", true, 4000)
	seedPost(t, client, pid(5), "b", false, 5000)
	seedPost(t, client, pid(6), "b", false, 6000)
	seedPost(t, client, pid(7), "c", false, 7000)

	t.Run("Q-H authors in, roots only, newest first", func(t *testing.T) {
		ctx := context.Background()
		got, err := svc.ByAuthors(ctx, []string{"a", "b"}, Window{}, 50)
		if err != nil {
			t.Fatal(err)
		}
		want := []string{pid(6), pid(5), pid(3), pid(2), pid(1)} // the reply (4) is excluded; tie 3 before 2 (__name__ DESC)
		if !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
	})

	t.Run("Q-H pages with Before and never skips or repeats a tie", func(t *testing.T) {
		var all []string
		var before *Position
		for page := 0; page < 10; page++ {
			got, err := svc.ByAuthors(context.Background(), []string{"a", "b", "c"}, Window{Before: before}, 2)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) == 0 {
				break
			}
			for _, p := range got {
				all = append(all, p.ID)
			}
			last := got[len(got)-1]
			before = &Position{CreatedAt: last.CreatedAt, ID: last.ID}
		}
		want := []string{pid(7), pid(6), pid(5), pid(3), pid(2), pid(1)}
		if !reflect.DeepEqual(all, want) {
			t.Fatalf("paged ids = %v, want %v", all, want)
		}
	})

	t.Run("Q-H After bound stops strictly above it", func(t *testing.T) {
		after := &Position{CreatedAt: time.UnixMilli(2000).UTC(), ID: pid(3)}
		got, err := svc.ByAuthors(context.Background(), []string{"a", "b", "c"}, Window{After: after}, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(7), pid(6), pid(5)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v (strictly newer than the After position)", idList(got), want)
		}
	})

	t.Run("Q-H Before and After together bound a gap", func(t *testing.T) {
		w := Window{
			Before: &Position{CreatedAt: time.UnixMilli(6000).UTC(), ID: pid(6)},
			After:  &Position{CreatedAt: time.UnixMilli(2000).UTC(), ID: pid(2)},
		}
		got, err := svc.ByAuthors(context.Background(), []string{"a", "b", "c"}, w, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(5), pid(3)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
	})

	t.Run("Q-H no matches", func(t *testing.T) {
		ctx := context.Background()
		got, err := svc.ByAuthors(ctx, []string{"x", "y", "z"}, Window{}, 20)
		if err != nil || len(got) != 0 {
			t.Fatalf("got=%v err=%v", got, err)
		}
	})

	t.Run("Q-H respects Limit", func(t *testing.T) {
		ctx := context.Background()
		got, err := svc.ByAuthors(ctx, []string{"a", "b", "c"}, Window{}, 3)
		if err != nil || len(got) != 3 {
			t.Fatalf("got=%d err=%v", len(got), err)
		}
	})

	t.Run("Q-P Posts tab excludes replies", func(t *testing.T) {
		ctx := context.Background()
		got, err := svc.ByAuthor(ctx, "a", false, Window{}, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(3), pid(2), pid(1)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
	})

	t.Run("Q-R Replies tab has no isReply filter", func(t *testing.T) {
		got, err := svc.ByAuthor(context.Background(), "a", true, Window{}, 50)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(4), pid(3), pid(2), pid(1)}; !reflect.DeepEqual(idList(got), want) {
			t.Fatalf("ids = %v, want %v", idList(got), want)
		}
	})

	t.Run("Q-P and Q-R page with Before", func(t *testing.T) {
		first, err := svc.ByAuthor(context.Background(), "a", true, Window{}, 2)
		if err != nil || len(first) != 2 {
			t.Fatalf("first page: %v %v", idList(first), err)
		}
		last := first[1]
		next, err := svc.ByAuthor(context.Background(), "a", true, Window{Before: &Position{CreatedAt: last.CreatedAt, ID: last.ID}}, 2)
		if err != nil {
			t.Fatal(err)
		}
		if want := []string{pid(2), pid(1)}; !reflect.DeepEqual(idList(next), want) {
			t.Fatalf("second page = %v, want %v", idList(next), want)
		}
	})

	t.Run("query results fill the posts cache", func(t *testing.T) {
		svc2, cache := integrationSvc(client)
		got, err := svc2.ByAuthor(context.Background(), "c", false, Window{}, 5)
		if err != nil || len(got) != 1 {
			t.Fatal(err)
		}
		if _, err := svc2.Get(context.Background(), pid(7)); err != nil {
			t.Fatalf("Get after query: %v", err)
		}
		if _, ok := cache.GetPost(pid(7)); !ok {
			t.Fatal("not cached")
		}
	})
}
