package graph

import (
	"slices"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// suggestionCacheCapacity bounds the per-viewer ListSuggestedUsers results on one instance: at most HydrateMax (50)
// profiles of about 0.6 KB each per viewer, 2,000 viewers is about 3 MB at the default 10 and 60 MB at the cap, far
// under the 512 MiB instance. The LRU, not DAU, bounds memory.
const suggestionCacheCapacity = 2_000

// suggestionEntry is one viewer's cached ListSuggestedUsers answer: the hydrated rows (up to HydrateMax, best first,
// each already past the exclusion matrix), so a warm call costs no read and a removal refills from the tail.
type suggestionEntry struct {
	items []ListItem
	// source is Suggestion.Source of the call that built the entry (the log field on a warm hit).
	source string
	// candidates is how many candidate uids that call sent to hydration.
	candidates int
	// expiresAt is the staleness bound: the entry is dead from here on. It is kept in the value, not left to the LRU's
	// TTL, because LRU.Set resets the TTL and remove re-Sets the entry; the bound must not stretch.
	expiresAt time.Time
}

// suggestionCache is the per-viewer instance cache behind ListSuggestedUsers (ADR-0024 D8).
//
// Staleness bound: a viewer's answer is served for at most CacheTTL (SUGGESTIONS_CACHE_TTL, default 1 h) after the
// call that built it. This instance removes a user from the viewer's entry the moment its own Follow, Block or Mute
// makes them unsuitable (remove below), and a warm hit is re-filtered against the viewer's snapshot when the 60 s
// snapshot cache holds one (0 reads). What stays stale for up to CacheTTL: a change made on another instance or by
// another user (X blocks the viewer, X deletes the account or is suspended) and the viewer's follows made elsewhere.
// Keys are the viewer's uid, so no entry is ever shared across users.
type suggestionCache struct {
	// mu makes remove's read-modify-write atomic against put and other removes; the LRU is already thread safe.
	mu  sync.Mutex
	lru *cache.LRU[string, suggestionEntry]
	ttl time.Duration
}

func newSuggestionCache(ttl time.Duration) *suggestionCache {
	return &suggestionCache{lru: cache.New[string, suggestionEntry](suggestionCacheCapacity, ttl), ttl: ttl}
}

// get returns the viewer's live entry. The items slice is shared and read-only: callers copy before changing it.
func (c *suggestionCache) get(viewer string, now time.Time) (suggestionEntry, bool) {
	e, ok := c.lru.Get(viewer)
	if !ok || !now.Before(e.expiresAt) {
		return suggestionEntry{}, false
	}
	return e, true
}

// put stores a freshly built answer; its staleness clock starts at now.
func (c *suggestionCache) put(viewer string, e suggestionEntry, now time.Time) {
	e.expiresAt = now.Add(c.ttl)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lru.Set(viewer, e)
}

// remove drops uids from the viewer's entry, keeping the rest and the original expiresAt. It always stores a new
// slice, never editing the shared one in place (concurrent warm hits are reading it).
func (c *suggestionCache) remove(viewer string, uids ...string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.lru.Get(viewer)
	if !ok {
		return
	}
	kept := make([]ListItem, 0, len(e.items))
	for _, it := range e.items {
		if !slices.Contains(uids, it.User.UserID) {
			kept = append(kept, it)
		}
	}
	if len(kept) == len(e.items) {
		return
	}
	e.items = kept
	c.lru.Set(viewer, e)
}
