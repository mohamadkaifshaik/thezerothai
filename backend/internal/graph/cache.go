package graph

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// cacheCapacity mirrors identity.Cache's rationale (LRU-bounded memory independent of DAU). ADR-0008 D8
// notes graph docs are ~3KB typical but can reach ~566KB for an account near every cap; sre-performance
// watches instance memory (D8) rather than this package pre-emptively byte-weighting the cache.
const cacheCapacity = 5_000

// edgeCapacity bounds the follow-edge answers (ADR-0024 D7): 5,000 pairs of two short strings and a bool,
// about 200 B each, about 1 MiB.
const edgeCapacity = 5_000

// edgeKey names one follows/{follower}_{followee} document. It is a struct, not the joined doc id, so no
// uid can make two different pairs collide, and the order of the fields is the order of the edge (who
// follows whom): getting it backwards asks about the opposite edge.
type edgeKey struct{ follower, followee string }

// Cache is graph's instance cache: graph/{uid} Snapshots, 60s TTL (ADR-0008 D8), updated in place on this
// instance's own commits (CLAUDE.md: "update the instance cache from written data instead of re-reading").
// It also holds the "does this follow edge exist" answers behind GetProfileRelationship (ADR-0024 D7).
type Cache struct {
	snapshots *cache.LRU[string, Snapshot]
	// edges holds whether follows/{follower}_{followee} exists, true and false alike, so a non-follower's
	// repeat view is 0 reads too. Staleness bound: at most the TTL (config.CacheTTL, <= 60 s) behind another
	// instance's write; this instance evicts the pair itself on every Follow, Unfollow and Block that
	// changes or may have changed the edge (see ForgetEdge).
	edges *cache.LRU[edgeKey, bool]
}

// NewCache builds the cache. ttl is config.CacheTTL (default 60s), the same knob identity.Cache uses.
func NewCache(ttl time.Duration) *Cache {
	return &Cache{
		snapshots: cache.New[string, Snapshot](cacheCapacity, ttl),
		edges:     cache.New[edgeKey, bool](edgeCapacity, ttl),
	}
}

func (c *Cache) Get(uid string) (Snapshot, bool) {
	return c.snapshots.Get(uid)
}

func (c *Cache) Set(uid string, s Snapshot) {
	c.snapshots.Set(uid, s)
}

func (c *Cache) Invalidate(uid string) {
	c.snapshots.Delete(uid)
}

// Edge returns whether follows/{follower}_{followee} existed when it was last read, and whether an answer is
// cached at all.
func (c *Cache) Edge(follower, followee string) (exists, ok bool) {
	return c.edges.Get(edgeKey{follower, followee})
}

// SetEdge records the answer a fresh read of follows/{follower}_{followee} gave.
func (c *Cache) SetEdge(follower, followee string, exists bool) {
	c.edges.Set(edgeKey{follower, followee}, exists)
}

// ForgetEdge drops the cached answer for follows/{follower}_{followee}: call it when a commit on this instance
// created or removed that edge.
func (c *Cache) ForgetEdge(follower, followee string) {
	c.edges.Delete(edgeKey{follower, followee})
}
