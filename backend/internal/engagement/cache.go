package engagement

import (
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// DefaultCacheEntries bounds the userLikes cache (one entry per recently active user on this instance).
const DefaultCacheEntries = 5_000

// likesState is one cached userLikes document plus the lookup sets. It is immutable: updates build a new state
// (copy on write), so a ViewerSet handed to a request never changes under it.
type likesState struct {
	recent, reposts []string
	set             posts.ViewerSet
}

func newLikesState(recent, reposts []string) *likesState {
	return &likesState{recent: recent, reposts: reposts, set: posts.NewViewerSet(recent, reposts)}
}

// userCache is the per-instance userLikes cache (ADR-0018 D7): 60 s TTL like every other cache, updated in place
// by this instance's own writes. Absence means "unknown": an own write never creates an entry (it would hide the
// user's other likes), the next read loads the document.
type userCache struct {
	// mu makes update's read-modify-write atomic: concurrent likes of different posts by one user (separate
	// flights) must not overwrite each other's new state.
	mu  sync.Mutex
	lru *cache.LRU[string, *likesState]
}

func newUserCache(ttl time.Duration, entries int) *userCache {
	if entries <= 0 {
		entries = DefaultCacheEntries
	}
	return &userCache{lru: cache.New[string, *likesState](entries, ttl)}
}

func (c *userCache) get(uid string) (*likesState, bool) { return c.lru.Get(uid) }

func (c *userCache) set(uid string, ul UserLikes) *likesState {
	st := newLikesState(ul.Recent, ul.RecentReposts)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lru.Set(uid, st)
	return st
}

// update applies fn to a present entry and stores the result; an absent entry is left alone. It returns the new
// state, or nil when there was none.
func (c *userCache) update(uid string, fn func(recent, reposts []string) ([]string, []string)) *likesState {
	c.mu.Lock()
	defer c.mu.Unlock()
	st, ok := c.lru.Get(uid)
	if !ok {
		return nil
	}
	r, p := fn(append([]string(nil), st.recent...), append([]string(nil), st.reposts...))
	next := newLikesState(r, p)
	c.lru.Set(uid, next)
	return next
}

func (c *userCache) delete(uid string) { c.lru.Delete(uid) }

// withID appends id (newest last) unless present.
func withID(list []string, id string) []string {
	for _, x := range list {
		if x == id {
			return list
		}
	}
	return append(list, id)
}

// withoutID removes every occurrence of id.
func withoutID(list []string, id string) []string {
	out := list[:0]
	for _, x := range list {
		if x != id {
			out = append(out, x)
		}
	}
	return out
}

// withoutIDs removes every id in drop.
func withoutIDs(list, drop []string) []string {
	if len(drop) == 0 {
		return list
	}
	d := make(map[string]struct{}, len(drop))
	for _, id := range drop {
		d[id] = struct{}{}
	}
	out := list[:0]
	for _, x := range list {
		if _, ok := d[x]; !ok {
			out = append(out, x)
		}
	}
	return out
}
