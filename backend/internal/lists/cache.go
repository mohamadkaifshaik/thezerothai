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

// negativeTTL is the staleness bound of a negative entry (a missing list id), W5-45.
const negativeTTL = 60 * time.Second

// docCache is the per-instance list-doc cache (CACHE_LISTS_ENTRIES entries, cacheTTL). W5-4 only fills and evicts it from
// the data a write produced (never re-reading); the read side (GetList, lists.Reader) is W5-7. Entries are copies, so a
// caller can not change a cached member slice.
type docCache struct {
	lru *cache.LRU[string, List]
	// miss is the negative cache (W5-45, security review L-1): ids whose point read found no document, for negativeTTL. A
	// missing id then costs 0 reads on a repeat probe and answers as fast as a cached private list, so latency tells the two
	// apart no better than the byte-identical NOT_FOUND does. Staleness bound 60 s on every instance. A list created after an
	// entry is visible at once on the creating instance (put clears the entry); on another instance the bound is the TTL,
	// which needs a probe of an id before it is minted: ids are server-generated Snowflakes, so that is not guessable.
	miss *cache.LRU[string, struct{}]
}

func newDocCache(entries int) *docCache {
	n := max(entries, 1)
	return &docCache{lru: cache.New[string, List](n, cacheTTL), miss: cache.New[string, struct{}](n, negativeTTL)}
}

// put stores a copy of l under its id.
func (c *docCache) put(l List) {
	c.miss.Delete(l.ID)
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
func (c *docCache) evict(id string) {
	c.lru.Delete(id)
	c.miss.Delete(id)
}

// putMissing records that id has no document (negative cache, 60 s).
func (c *docCache) putMissing(id string) { c.miss.Set(id, struct{}{}) }

// isMissing reports a live negative entry for id.
func (c *docCache) isMissing(id string) bool {
	_, ok := c.miss.Get(id)
	return ok
}
