package graph

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// cacheCapacity mirrors identity.Cache's rationale (LRU-bounded memory independent of DAU). ADR-0008 D8
// notes graph docs are ~3KB typical but can reach ~566KB for an account near every cap; sre-performance
// watches instance memory (D8) rather than this package pre-emptively byte-weighting the cache.
const cacheCapacity = 5_000

// Cache is graph's instance cache: graph/{uid} Snapshots, 60s TTL (ADR-0008 D8), updated in place on this
// instance's own commits (CLAUDE.md: "update the instance cache from written data instead of re-reading").
type Cache struct {
	snapshots *cache.LRU[string, Snapshot]
}

// NewCache builds the cache. ttl is config.CacheTTL (default 60s), the same knob identity.Cache uses.
func NewCache(ttl time.Duration) *Cache {
	return &Cache{snapshots: cache.New[string, Snapshot](cacheCapacity, ttl)}
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
