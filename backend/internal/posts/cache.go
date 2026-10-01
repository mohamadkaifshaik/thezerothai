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
	// ownLog and deleted (guarded by mu) remember this instance's own writes for ttl, so a read that started
	// before a write cannot overwrite it (StoreAuthorRecent, SetPostRead).
	ownLog  map[string][]ownWrite
	deleted map[string]time.Time
	ttl     time.Duration
	now     func() time.Time // overridable for tests
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
		posts:   cache.New[string, *Post](postsEntries, ttl),
		recent:  cache.New[string, Recent](authorRecentEntries, ttl),
		ownLog:  map[string][]ownWrite{},
		deleted: map[string]time.Time{},
		ttl:     ttl,
		now:     time.Now,
	}
}

// GetPost returns a cached post.
func (c *Cache) GetPost(id string) (*Post, bool) { return c.posts.Get(id) }

// SetPost caches p unconditionally (this instance's own writes).
func (c *Cache) SetPost(p *Post) { c.posts.Set(p.ID, p) }

// SetPostRead caches p from a read that started at readAt. It skips a post this instance deleted at or after
// readAt: the query may have seen the post before the delete, and caching it would resurrect it for up to
// CACHE_TTL.
func (c *Cache) SetPostRead(p *Post, readAt time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if at, ok := c.deleted[p.ID]; ok && !at.Before(readAt) {
		return
	}
	c.posts.Set(p.ID, p)
}

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
//
// loadedAt is when the query started. This instance's own writes at or after loadedAt are replayed onto the
// data before it is stored, so a slow query that raced a CreatePost or DeletePost here can neither drop the new
// post nor bring back a deleted one.
func (c *Cache) StoreAuthorRecent(authorID string, newest []*Post, truncated bool, loadedAt time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	merged := append([]*Post(nil), newest...)
	for _, w := range c.ownLog[authorID] {
		if w.at.Before(loadedAt) {
			continue
		}
		if w.post != nil {
			merged = insertNewestFirst(merged, w.post)
		} else {
			merged = removeID(merged, w.removeID)
		}
	}
	if len(merged) > MaxRecent {
		merged, truncated = merged[:MaxRecent], true
	}
	c.recent.Set(authorID, Recent{Posts: merged, Truncated: truncated, LoadedAt: loadedAt})
}

// ownWrite is one of this instance's own post writes, kept for ttl so a concurrent read can be reconciled
// (post != nil: a new root post; otherwise removeID was deleted).
type ownWrite struct {
	at       time.Time
	post     *Post
	removeID string
}

// ownLogSweepAt bounds the own-write log: above this many authors, expired entries are swept on every record.
const ownLogSweepAt = 1_024

// recordOwn appends w to authorID's own-write log, pruning entries older than ttl. Caller holds c.mu.
func (c *Cache) recordOwn(authorID string, w ownWrite) {
	now := c.now()
	keep := c.ownLog[authorID][:0:0]
	for _, o := range c.ownLog[authorID] {
		if c.ttl <= 0 || now.Sub(o.at) < c.ttl {
			keep = append(keep, o)
		}
	}
	c.ownLog[authorID] = append(keep, w)
	if w.post == nil {
		c.deleted[w.removeID] = w.at
	}
	if len(c.ownLog) > ownLogSweepAt || len(c.deleted) > ownLogSweepAt {
		c.sweepOwn(now)
	}
}

// sweepOwn drops every expired own-write record. Caller holds c.mu.
func (c *Cache) sweepOwn(now time.Time) {
	for a, ws := range c.ownLog {
		keep := ws[:0:0]
		for _, o := range ws {
			if c.ttl <= 0 || now.Sub(o.at) < c.ttl {
				keep = append(keep, o)
			}
		}
		if len(keep) == 0 {
			delete(c.ownLog, a)
		} else {
			c.ownLog[a] = keep
		}
	}
	for id, at := range c.deleted {
		if c.ttl > 0 && now.Sub(at) >= c.ttl {
			delete(c.deleted, id)
		}
	}
}

// insertNewestFirst adds p to a newest-first list unless present, ordered by (CreatedAt, ID) descending.
func insertNewestFirst(list []*Post, p *Post) []*Post {
	for _, q := range list {
		if q.ID == p.ID {
			return list
		}
	}
	i := 0
	for i < len(list) && (list[i].CreatedAt.After(p.CreatedAt) || (list[i].CreatedAt.Equal(p.CreatedAt) && list[i].ID > p.ID)) {
		i++
	}
	list = append(list, nil)
	copy(list[i+1:], list[i:])
	list[i] = p
	return list
}

func removeID(list []*Post, id string) []*Post {
	out := list[:0:0]
	for _, q := range list {
		if q.ID != id {
			out = append(out, q)
		}
	}
	return out
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
	// Recorded even when there is no entry: a query already in flight may store one built from older data.
	c.recordOwn(p.AuthorID, ownWrite{at: c.now(), post: p})
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
	c.recordOwn(authorID, ownWrite{at: c.now(), removeID: postID})
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
