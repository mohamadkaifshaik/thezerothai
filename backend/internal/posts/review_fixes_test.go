package posts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// TestStoreAuthorRecent_DoesNotOverwriteNewerOwnWrites (review M2): a query that started at t0, an own write on
// this instance, then StoreAuthorRecent(loadedAt = t0) must neither drop the new post nor bring back a deleted one.
func TestStoreAuthorRecent_DoesNotOverwriteNewerOwnWrites(t *testing.T) {
	p1, p2, p3 := post("0000000000000000001", "a"), post("0000000000000000002", "a"), post("0000000000000000003", "a")
	p1.CreatedAt, p2.CreatedAt, p3.CreatedAt = time.UnixMilli(1000), time.UnixMilli(2000), time.UnixMilli(3000)

	t.Run("own CreatePost after the query started is kept", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		t0 := clk.t
		clk.t = t0.Add(time.Second)
		c.PrependOwn(p3) // no entry yet: recorded anyway
		clk.t = t0.Add(2 * time.Second)
		c.StoreAuthorRecent("a", []*Post{p2, p1}, false, t0) // the stale query result lacks p3
		got, ok := c.AuthorRecent("a")
		if !ok || !equalStrings(ids(got.Posts), []string{p3.ID, p2.ID, p1.ID}) || !got.LoadedAt.Equal(t0) {
			t.Fatalf("entry = %v ok=%v, want [3 2 1] with loadedAt t0", ids(got.Posts), ok)
		}
	})
	t.Run("own DeletePost after the query started is not resurrected", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		t0 := clk.t
		clk.t = t0.Add(time.Second)
		c.RemoveOwn("a", p2.ID)
		clk.t = t0.Add(2 * time.Second)
		c.StoreAuthorRecent("a", []*Post{p3, p2, p1}, false, t0) // the stale result still has p2
		got, _ := c.AuthorRecent("a")
		if !equalStrings(ids(got.Posts), []string{p3.ID, p1.ID}) {
			t.Fatalf("entry = %v, want [3 1]", ids(got.Posts))
		}
	})
	t.Run("interleaved prepend and remove replay in order", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		t0 := clk.t
		clk.t = t0.Add(time.Second)
		c.PrependOwn(p3)
		clk.t = t0.Add(2 * time.Second)
		c.RemoveOwn("a", p3.ID) // created then deleted while the query was running
		clk.t = t0.Add(3 * time.Second)
		c.StoreAuthorRecent("a", []*Post{p2, p1}, false, t0)
		got, _ := c.AuthorRecent("a")
		if !equalStrings(ids(got.Posts), []string{p2.ID, p1.ID}) {
			t.Fatalf("entry = %v, want [2 1]", ids(got.Posts))
		}
	})
	t.Run("own writes older than the query start are already in its data", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		c.RemoveOwn("a", p2.ID)
		clk.t = clk.t.Add(time.Second)
		t0 := clk.t // the query started after the delete
		c.StoreAuthorRecent("a", []*Post{p1}, false, t0)
		got, _ := c.AuthorRecent("a")
		if !equalStrings(ids(got.Posts), []string{p1.ID}) {
			t.Fatalf("entry = %v, want [1]", ids(got.Posts))
		}
		// And a read that started after the delete may cache the post again (e.g. it was re-created elsewhere).
		c.SetPostRead(p2, t0)
		if _, ok := c.GetPost(p2.ID); !ok {
			t.Fatal("a read newer than the delete was refused")
		}
	})
	t.Run("a merge that overflows truncates", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		var full []*Post
		for i := 19; i >= 0; i-- {
			q := post(fmt.Sprintf("%019d", 100+i), "a")
			q.CreatedAt = time.UnixMilli(int64(100 + i))
			full = append(full, q)
		}
		t0 := clk.t
		clk.t = t0.Add(time.Second)
		own := post("0000000000000009999", "a")
		own.CreatedAt = time.UnixMilli(9999)
		c.PrependOwn(own)
		c.StoreAuthorRecent("a", full, false, t0)
		got, _ := c.AuthorRecent("a")
		if len(got.Posts) != MaxRecent || !got.Truncated || got.Posts[0].ID != own.ID {
			t.Fatalf("len=%d truncated=%v first=%s", len(got.Posts), got.Truncated, got.Posts[0].ID)
		}
	})
	t.Run("the own-write log is bounded by the TTL", func(t *testing.T) {
		c, clk := newClockedCache(time.Minute)
		c.PrependOwn(p3)
		c.RemoveOwn("a", p2.ID)
		clk.t = clk.t.Add(2 * time.Minute)
		c.sweepOwn(clk.t)
		if len(c.ownLog) != 0 || len(c.deleted) != 0 {
			t.Fatalf("expired own writes were kept: %d authors, %d deleted", len(c.ownLog), len(c.deleted))
		}
	})
}

// TestReads_DoNotResurrectAnOwnDelete: a query or GetMany that began before this instance deleted a post must
// not put it back in the posts cache.
func TestReads_DoNotResurrectAnOwnDelete(t *testing.T) {
	p := post("0000000000000000005", "a")
	repo := newFakeRepo(p)
	c, clk := newClockedCache(time.Minute)
	svc := New(Deps{Repo: repo, Cache: c, Now: clk.now}).(*service)
	// The repo call itself performs the delete, i.e. the delete lands while the read is in flight.
	repo.queryResult = []*Post{p}
	repo.beforeReturn = func() {
		clk.t = clk.t.Add(time.Second)
		c.RemoveOwn("a", p.ID)
	}
	if _, err := svc.ByAuthor(context.Background(), "a", false, Window{}, 5); err != nil {
		t.Fatal(err)
	}
	if _, ok := c.GetPost(p.ID); ok {
		t.Fatal("a delete that landed during the query was undone by the query's cache fill")
	}
}

func TestGetMany_RejectsInvalidIDs(t *testing.T) {
	for _, bad := range []string{"", "a/b", "/", "0000000000000000001/likes/x"} {
		t.Run(fmt.Sprintf("%q", bad), func(t *testing.T) {
			repo := newFakeRepo()
			svc, _ := newSvc(repo)
			if _, err := svc.GetMany(context.Background(), []string{"0000000000000000001", bad}); !errors.Is(err, ErrInvalidID) {
				t.Fatalf("err = %v, want ErrInvalidID", err)
			}
			if _, err := svc.Get(context.Background(), bad); !errors.Is(err, ErrInvalidID) {
				t.Fatalf("Get err = %v, want ErrInvalidID", err)
			}
			if repo.getAllCalls != 0 {
				t.Fatal("an invalid id reached the repo")
			}
		})
	}
}

// TestCacheHitIsAPerRequestCount (review M1, ADR-0010 D20): several Reader calls in one request sum their cache
// hits into one posts_cache_hit counter instead of the last call overwriting it.
func TestCacheHitIsAPerRequestCount(t *testing.T) {
	p1, p2, p3 := post("0000000000000000001", "a"), post("0000000000000000002", "a"), post("0000000000000000003", "a")
	repo := newFakeRepo(p1, p2, p3)
	svc, cache := newSvc(repo)
	cache.SetPost(p1)
	cache.SetPost(p2)

	ctx, info := logger.WithRequestInfo(context.Background())
	if _, err := svc.GetMany(ctx, []string{p1.ID, p2.ID, p3.ID}); err != nil { // 2 hits, 1 miss
		t.Fatal(err)
	}
	if _, err := svc.GetMany(ctx, []string{p1.ID, p3.ID}); err != nil { // 2 hits (p3 now cached)
		t.Fatal(err)
	}
	if _, err := svc.Get(ctx, "0000000000000000404"); !errors.Is(err, ErrNotFound) { // 0 hits
		t.Fatal(err)
	}
	if v, ok := info.Get("posts_cache_hit"); !ok || v != int64(4) {
		t.Fatalf("posts_cache_hit = %v, %v; want int64 4 (2 + 2 + 0)", v, ok)
	}
}

// TestFirestoreIndexesCoverThePostQueries (review M3): the emulator does not enforce composite indexes, so this
// asserts the file Terraform/firebase deploys declares the two indexes Q-H/Q-P and Q-R need
// (ADR-0010 D19: `__name__ DESC` rides on the last field's direction).
func TestFirestoreIndexesCoverThePostQueries(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "firebase", "firestore.indexes.json"))
	if err != nil {
		t.Fatalf("read firestore.indexes.json: %v", err)
	}
	var file struct {
		Indexes []struct {
			CollectionGroup string `json:"collectionGroup"`
			QueryScope      string `json:"queryScope"`
			Fields          []struct {
				FieldPath string `json:"fieldPath"`
				Order     string `json:"order"`
			} `json:"fields"`
		} `json:"indexes"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	have := map[string]bool{}
	for _, ix := range file.Indexes {
		if ix.CollectionGroup != "posts" || ix.QueryScope != "COLLECTION" {
			continue
		}
		var parts []string
		for _, f := range ix.Fields {
			parts = append(parts, f.FieldPath+":"+f.Order)
		}
		have[fmt.Sprint(parts)] = true
	}
	want := map[string][]string{
		"Q-H / Q-P (authorId in|==, isReply ==, createdAt DESC)": {"authorId:ASCENDING", "isReply:ASCENDING", "createdAt:DESCENDING"},
		"Q-R (authorId ==, createdAt DESC)":                      {"authorId:ASCENDING", "createdAt:DESCENDING"},
	}
	for name, fields := range want {
		if !have[fmt.Sprint(fields)] {
			t.Errorf("firestore.indexes.json has no posts index for %s: %v (declared: %v)", name, fields, reflect.ValueOf(have).MapKeys())
		}
	}
}
