package posts

import (
	"fmt"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

func newClockedCache(ttl time.Duration) (*Cache, *fakeClock) {
	clk := &fakeClock{t: time.Unix(1_700_000_000, 0)}
	c := NewCache(ttl, 0, 0)
	c.now = clk.now
	return c, clk
}

func ids(ps []*Post) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.ID
	}
	return out
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestCache_PostRoundTripAndEvict(t *testing.T) {
	c, _ := newClockedCache(time.Minute)
	p := post("0000000000000000001", "a")
	if _, ok := c.GetPost(p.ID); ok {
		t.Fatal("empty cache hit")
	}
	c.SetPost(p)
	if got, ok := c.GetPost(p.ID); !ok || got != p {
		t.Fatalf("GetPost = %v, %v", got, ok)
	}
	c.DeletePost(p.ID)
	if _, ok := c.GetPost(p.ID); ok {
		t.Fatal("DeletePost did not evict")
	}
}

func TestCache_DefaultSizesBoundTheCaches(t *testing.T) {
	c := NewCache(time.Hour, 0, 0)
	for i := 0; i < DefaultPostsEntries+5; i++ {
		c.SetPost(&Post{ID: fmt.Sprintf("%019d", i)})
	}
	if n := c.posts.Len(); n != DefaultPostsEntries {
		t.Fatalf("posts entries = %d, want the default %d", n, DefaultPostsEntries)
	}
	for i := 0; i < DefaultAuthorRecentEntries+5; i++ {
		c.StoreAuthorRecent(fmt.Sprintf("a%d", i), nil, false, time.Now())
	}
	if n := c.recent.Len(); n != DefaultAuthorRecentEntries {
		t.Fatalf("author-recent entries = %d, want the default %d", n, DefaultAuthorRecentEntries)
	}
	if DefaultPostsEntries != 20_000 || DefaultAuthorRecentEntries != 1_000 {
		t.Fatal("ADR-0010 D15 defaults changed")
	}
	small := NewCache(time.Hour, 3, 2)
	for i := 0; i < 10; i++ {
		small.SetPost(&Post{ID: fmt.Sprint(i)})
	}
	if small.posts.Len() != 3 {
		t.Fatalf("configured size ignored: %d", small.posts.Len())
	}
}

func TestCache_AuthorRecentFreshnessUsesLoadedAt(t *testing.T) {
	c, clk := newClockedCache(time.Minute)
	loaded := clk.t
	c.StoreAuthorRecent("a", []*Post{post("0000000000000000002", "a")}, false, loaded)

	clk.t = loaded.Add(59 * time.Second)
	if _, ok := c.AuthorRecent("a"); !ok {
		t.Fatal("entry inside the TTL missed")
	}
	// An own write re-Sets the LRU entry (restarting the LRU's own expiry) but must not extend the data's life.
	c.PrependOwn(post("0000000000000000003", "a"))
	clk.t = loaded.Add(61 * time.Second)
	if _, ok := c.AuthorRecent("a"); ok {
		t.Fatal("an entry kept alive by an own write outlived CACHE_TTL since its data was read")
	}
	if _, ok := c.recent.Get("a"); ok {
		t.Fatal("an expired entry should be evicted on access")
	}
}

func TestCache_StoreAuthorRecentCapsAtTwentyAndMarksTruncated(t *testing.T) {
	c, clk := newClockedCache(time.Minute)
	var ps []*Post
	for i := 25; i > 0; i-- {
		ps = append(ps, post(fmt.Sprintf("%019d", i), "a"))
	}
	c.StoreAuthorRecent("a", ps, false, clk.t)
	got, ok := c.AuthorRecent("a")
	if !ok || len(got.Posts) != MaxRecent || !got.Truncated || got.Posts[0].ID != ps[0].ID {
		t.Fatalf("len=%d truncated=%v first=%s", len(got.Posts), got.Truncated, got.Posts[0].ID)
	}
	// The stored slice is a copy: mutating the caller's slice does not change the entry.
	ps[0] = nil
	if got2, _ := c.AuthorRecent("a"); got2.Posts[0] == nil {
		t.Fatal("entry aliases the caller's slice")
	}
}

func TestCache_PrependOwn(t *testing.T) {
	c, clk := newClockedCache(time.Minute)
	loaded := clk.t
	p3, p2 := post("0000000000000000003", "a"), post("0000000000000000002", "a")

	t.Run("no entry is a no-op", func(t *testing.T) {
		c.PrependOwn(post("0000000000000000009", "nobody"))
		if _, ok := c.AuthorRecent("nobody"); ok {
			t.Fatal("PrependOwn created an entry")
		}
	})
	t.Run("prepends and keeps loadedAt and truncated", func(t *testing.T) {
		c.StoreAuthorRecent("a", []*Post{p2}, true, loaded)
		clk.t = loaded.Add(10 * time.Second)
		c.PrependOwn(p3)
		got, _ := c.AuthorRecent("a")
		if !equalStrings(ids(got.Posts), []string{p3.ID, p2.ID}) || !got.LoadedAt.Equal(loaded) || !got.Truncated {
			t.Fatalf("got ids=%v loadedAt=%v truncated=%v", ids(got.Posts), got.LoadedAt, got.Truncated)
		}
	})
	t.Run("a replayed post is not duplicated", func(t *testing.T) {
		c.PrependOwn(p3)
		got, _ := c.AuthorRecent("a")
		if !equalStrings(ids(got.Posts), []string{p3.ID, p2.ID}) {
			t.Fatalf("ids = %v", ids(got.Posts))
		}
	})
	t.Run("replies never enter author-recent", func(t *testing.T) {
		r := post("0000000000000000010", "a")
		r.IsReply = true
		c.PrependOwn(r)
		got, _ := c.AuthorRecent("a")
		if len(got.Posts) != 2 {
			t.Fatalf("a reply entered the entry: %v", ids(got.Posts))
		}
	})
	t.Run("a full entry drops its oldest and becomes truncated", func(t *testing.T) {
		var full []*Post
		for i := 40; i > 20; i-- {
			full = append(full, post(fmt.Sprintf("%019d", i), "b"))
		}
		c.StoreAuthorRecent("b", full, false, clk.t)
		c.PrependOwn(post("0000000000000000050", "b"))
		got, _ := c.AuthorRecent("b")
		if len(got.Posts) != MaxRecent || !got.Truncated || got.Posts[0].ID != "0000000000000000050" ||
			got.Posts[MaxRecent-1].ID != full[MaxRecent-2].ID {
			t.Fatalf("len=%d truncated=%v first=%s last=%s", len(got.Posts), got.Truncated, got.Posts[0].ID, got.Posts[len(got.Posts)-1].ID)
		}
	})
}

func TestCache_RemoveOwn(t *testing.T) {
	c, clk := newClockedCache(time.Minute)
	p3, p2 := post("0000000000000000003", "a"), post("0000000000000000002", "a")
	c.StoreAuthorRecent("a", []*Post{p3, p2}, true, clk.t)
	c.SetPost(p3)

	c.RemoveOwn("a", p3.ID)
	if _, ok := c.GetPost(p3.ID); ok {
		t.Fatal("post not evicted from the posts cache")
	}
	got, ok := c.AuthorRecent("a")
	if !ok || !equalStrings(ids(got.Posts), []string{p2.ID}) || !got.Truncated || !got.LoadedAt.Equal(clk.t) {
		t.Fatalf("entry after delete = %+v ok=%v", got, ok)
	}
	// No entry for the author, or an unknown post: nothing to do, and nothing created.
	c.RemoveOwn("nobody", "x")
	if _, ok := c.AuthorRecent("nobody"); ok {
		t.Fatal("RemoveOwn created an entry")
	}
	c.RemoveOwn("a", "0000000000000000999")
	if got, _ := c.AuthorRecent("a"); len(got.Posts) != 1 {
		t.Fatalf("removing an unknown post changed the entry: %v", ids(got.Posts))
	}
}

// TestCache_ConcurrentOwnWrites runs under -race in CI: prepend/remove/store from many goroutines.
func TestCache_ConcurrentOwnWrites(t *testing.T) {
	c := NewCache(time.Minute, 0, 0)
	c.StoreAuthorRecent("a", nil, false, time.Now())
	done := make(chan struct{})
	for g := 0; g < 8; g++ {
		go func(g int) {
			defer func() { done <- struct{}{} }()
			for i := 0; i < 200; i++ {
				p := post(fmt.Sprintf("%019d", g*1000+i), "a")
				c.SetPost(p)
				c.PrependOwn(p)
				if i%3 == 0 {
					c.RemoveOwn("a", p.ID)
				}
				c.AuthorRecent("a")
			}
		}(g)
	}
	for g := 0; g < 8; g++ {
		<-done
	}
	if got, ok := c.AuthorRecent("a"); !ok || len(got.Posts) > MaxRecent {
		t.Fatalf("entry invalid: ok=%v len=%d", ok, len(got.Posts))
	}
}
