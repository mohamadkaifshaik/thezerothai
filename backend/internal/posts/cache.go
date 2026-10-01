package posts

import (
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// Default cache sizes (ADR-0010 D15), overridden by CACHE_POSTS_ENTRIES / CACHE_AUTHOR_RECENT_ENTRIES.
const (
	DefaultPostsEntries        = 20_000
	DefaultAuthorRecentEntries = 1_000
)

// Cache is posts' instance cache (ADR-0010 D15): post docs by id, and per-author recent root posts. Both are
// LRU-bounded with the CACHE_TTL expiry, filled by every read path, and updated in place by this instance's own
// writes (CLAUDE.md: "update the instance cache from written data instead of re-reading"). Entries of the two
// caches share *Post pointers, and a *Post is immutable.
type Cache struct {
	mu     sync.Mutex // serialises the read-modify-write of author-recent entries (own writes)
	posts  *cache.LRU[string, *Post]
	recent *cache.LRU[string, Recent]
	ttl    time.Duration
	now    func() time.Time // overridable for tests
}

// NewCache builds the cache. ttl is config.CacheTTL (default 60 s); entry counts that are <= 0 use the D15
// defaults, so the cache is always bounded.
func NewCache(ttl time.Duration, postsEntries, authorRecentEntries int) *Cache {
	if postsEntries <= 0 {
		postsEntries = DefaultPostsEntries
	}
	if authorRecentEntries <= 0 {
		authorRecentEntries = DefaultAuthorRecentEntries
	}
	return &Cache{
		posts:  cache.New[string, *Post](postsEntries, ttl),
		recent: cache.New[string, Recent](authorRecentEntries, ttl),
		ttl:    ttl,
		now:    time.Now,
	}
}

// GetPost returns a cached post.
func (c *Cache) GetPost(id string) (*Post, bool) { return c.posts.Get(id) }

// SetPost caches p (own writes and every read path).
func (c *Cache) SetPost(p *Post) { c.posts.Set(p.ID, p) }

// DeletePost evicts a post (own deletes).
func (c *Cache) DeletePost(id string) { c.posts.Delete(id) }

// AuthorRecent returns authorID's entry if it is fresh. The LRU's own expiry restarts on every Set, so
// freshness is judged from the entry's LoadedAt: an entry kept alive by own-write updates still expires
// CACHE_TTL after its data was read.
func (c *Cache) AuthorRecent(authorID string) (Recent, bool) {
	r, ok := c.recent.Get(authorID)
	if !ok {
		return Recent{}, false
	}
	if c.ttl > 0 && c.now().Sub(r.LoadedAt) >= c.ttl {
		c.recent.Delete(authorID)
		return Recent{}, false
	}
	return r, true
}

// StoreAuthorRecent stores an author's newest root posts (newest first), keeping at most MaxRecent and marking
// the entry truncated when posts were dropped.
func (c *Cache) StoreAuthorRecent(authorID string, newest []*Post, truncated bool, loadedAt time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(newest) > MaxRecent {
		newest, truncated = newest[:MaxRecent], true
	}
	c.recent.Set(authorID, Recent{Posts: append([]*Post(nil), newest...), Truncated: truncated, LoadedAt: loadedAt})
}

// PrependOwn adds this instance's own new root post to an existing fresh entry, keeping its LoadedAt (the data
// before the new post was not re-read). A full entry drops its oldest post and becomes truncated. No entry, or
// an expired one: nothing to update. Replies are never in author-recent.
func (c *Cache) PrependOwn(p *Post) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if p.IsReply {
		return
	}
	r, ok := c.AuthorRecent(p.AuthorID)
	if !ok {
		return
	}
	posts := make([]*Post, 0, len(r.Posts)+1)
	posts = append(posts, p)
	for _, q := range r.Posts {
		if q.ID != p.ID {
			posts = append(posts, q)
		}
	}
	truncated := r.Truncated
	if len(posts) > MaxRecent {
		posts, truncated = posts[:MaxRecent], true
	}
	c.recent.Set(p.AuthorID, Recent{Posts: posts, Truncated: truncated, LoadedAt: r.LoadedAt})
}

// RemoveOwn drops a post this instance deleted from the posts cache and from its author's entry, keeping the
// entry's LoadedAt and Truncated flag.
func (c *Cache) RemoveOwn(authorID, postID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.posts.Delete(postID)
	r, ok := c.AuthorRecent(authorID)
	if !ok {
		return
	}
	kept := make([]*Post, 0, len(r.Posts))
	for _, q := range r.Posts {
		if q.ID != postID {
			kept = append(kept, q)
		}
	}
	c.recent.Set(authorID, Recent{Posts: kept, Truncated: r.Truncated, LoadedAt: r.LoadedAt})
}
