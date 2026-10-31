package lists

import (
	"slices"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// cacheTTL is the staleness bound of every cached list doc (ADR-0030 D11): a write updates the writing instance at once, the
// other instances within 60 s. A list made private or hidden therefore stops serving non-owners within 60 s everywhere (at
// once on the instance that took the write). Behind the cache.LRU seam, so Memorystore can replace it by ADR.
const cacheTTL = 60 * time.Second

// docCache is the per-instance list-doc cache (CACHE_LISTS_ENTRIES entries, cacheTTL). W5-4 only fills and evicts it from
// the data a write produced (never re-reading); the read side (GetList, lists.Reader) is W5-7. Entries are copies, so a
// caller can not change a cached member slice.
type docCache struct {
	lru *cache.LRU[string, List]
}

func newDocCache(entries int) *docCache {
	return &docCache{lru: cache.New[string, List](max(entries, 1), cacheTTL)}
}

// put stores a copy of l under its id.
func (c *docCache) put(l List) {
	l.MemberIDs = slices.Clone(l.MemberIDs)
	c.lru.Set(l.ID, l)
}

// get returns a copy of the cached list, if any and not older than cacheTTL.
func (c *docCache) get(id string) (List, bool) {
	l, ok := c.lru.Get(id)
	if ok {
		l.MemberIDs = slices.Clone(l.MemberIDs)
	}
	return l, ok
}

// evict drops id (a delete, or an update that makes the list private).
func (c *docCache) evict(id string) { c.lru.Delete(id) }
