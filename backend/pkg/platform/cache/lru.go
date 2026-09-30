// Package cache is the in-process LRU-with-TTL used by every module for hot Firestore documents
// (users/{uid}, graph/{uid}, ...). CLAUDE.md: "update the instance cache from written data instead of
// re-reading" — repos should call Set with the value they just wrote, not re-read it.
//
// It is intentionally process-local (no Redis at Stage 0): each of up to 3 Cloud Run instances keeps
// its own cache; that's fine for a 60s TTL on read-mostly documents.
package cache

import (
	"container/list"
	"sync"
	"time"
)

// LRU is a fixed-capacity, TTL-expiring, concurrency-safe cache.
type LRU[K comparable, V any] struct {
	mu       sync.Mutex
	capacity int
	ttl      time.Duration
	ll       *list.List
	items    map[K]*list.Element
	now      func() time.Time // overridable for tests
}

type entry[K comparable, V any] struct {
	key       K
	value     V
	expiresAt time.Time
}

// New builds an LRU cache. capacity <= 0 means unbounded (only TTL evicts); ttl <= 0 means entries never
// expire on their own (only LRU eviction applies). At least one of the two should be set in production
// code so memory is bounded (skill: "LRU-bounded").
func New[K comparable, V any](capacity int, ttl time.Duration) *LRU[K, V] {
	return &LRU[K, V]{
		capacity: capacity,
		ttl:      ttl,
		ll:       list.New(),
		items:    make(map[K]*list.Element),
		now:      time.Now,
	}
}

// Get returns the cached value for key if present and not expired.
func (c *LRU[K, V]) Get(key K) (V, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.getLocked(key)
}

// GetOrSet returns the live value for key, or stores and returns mk() when absent or expired. The check and
// the insert happen under one lock, so concurrent first accesses share one value (a Get-miss-then-Set pair
// would let the second Set replace the first, losing anything already applied to it). mk runs under the
// lock: keep it cheap and never call back into the cache.
func (c *LRU[K, V]) GetOrSet(key K, mk func() V) V {
	c.mu.Lock()
	defer c.mu.Unlock()
	if v, ok := c.getLocked(key); ok {
		return v
	}
	v := mk()
	c.setLocked(key, v)
	return v
}

func (c *LRU[K, V]) getLocked(key K) (V, bool) {

	el, ok := c.items[key]
	if !ok {
		var zero V
		return zero, false
	}
	e := el.Value.(*entry[K, V])
	if c.ttl > 0 && c.now().After(e.expiresAt) {
		c.removeElement(el)
		var zero V
		return zero, false
	}
	c.ll.MoveToFront(el)
	return e.value, true
}

// Set inserts or updates key, resetting its TTL and marking it most-recently-used.
func (c *LRU[K, V]) Set(key K, value V) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setLocked(key, value)
}

func (c *LRU[K, V]) setLocked(key K, value V) {

	expiresAt := time.Time{}
	if c.ttl > 0 {
		expiresAt = c.now().Add(c.ttl)
	}
	if el, ok := c.items[key]; ok {
		el.Value.(*entry[K, V]).value = value
		el.Value.(*entry[K, V]).expiresAt = expiresAt
		c.ll.MoveToFront(el)
		return
	}
	el := c.ll.PushFront(&entry[K, V]{key: key, value: value, expiresAt: expiresAt})
	c.items[key] = el
	if c.capacity > 0 && c.ll.Len() > c.capacity {
		oldest := c.ll.Back()
		if oldest != nil {
			c.removeElement(oldest)
		}
	}
}

// Delete removes key if present (e.g. after a delete/invalidate).
func (c *LRU[K, V]) Delete(key K) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.items[key]; ok {
		c.removeElement(el)
	}
}

// Len returns the current number of entries, including any not-yet-lazily-expired ones.
func (c *LRU[K, V]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ll.Len()
}

func (c *LRU[K, V]) removeElement(el *list.Element) {
	c.ll.Remove(el)
	e := el.Value.(*entry[K, V])
	delete(c.items, e.key)
}
