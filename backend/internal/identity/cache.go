package identity

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

const (
	// cacheCapacity bounds memory for each LRU independent of DAU (skill: "LRU-bounded").
	cacheCapacity = 20_000
	// unreadTTL matches the proto doc comment ("cached 30 s") for GetMe's notification count.
	unreadTTL = 30 * time.Second
	// notFoundTTL (M1) is deliberately short: a signed-up-but-profile-less caller hitting any non-exempt
	// RPC would otherwise re-read users/{uid} on every single call (authn.AccountStatusInterceptor ->
	// AccountStatus -> getProfileCached), burning the daily Firestore read quota for free before rate
	// limiting even has a chance to matter across a burst. ~10s bounds that to at most one read per 10s per
	// uid, while staying short enough that a real CreateProfile (which also actively clears this entry,
	// see SetProfile) is never masked by a stale negative result for long.
	notFoundTTL = 10 * time.Second
)

// Cache is identity's instance cache (ADR-0003: users/{uid} cached 60s; CLAUDE.md: "update the instance
// cache from written data instead of re-reading"). One per process; safe for concurrent use.
type Cache struct {
	profiles *cache.LRU[string, Profile]
	handles  *cache.LRU[string, handleEntry] // handleLower -> uid and when it was learned (ADR-0010 D21 G5)
	unread   *cache.LRU[string, int64]
	notFound *cache.LRU[string, struct{}] // uid -> "no profile yet" (M1 negative cache)
	// handleFree is the ADR-0010 D5 negative handle cache: handleLower -> "ResolveHandle said NotFound" for
	// notFoundTTL. Only a hint: CreateProfile/ChangeHandle stay transactional (handles Create), so a stale
	// "free" answer can never produce a duplicate handle.
	handleFree *cache.LRU[string, struct{}]
	now        func() time.Time // overridable for tests
}

// handleEntry is a positive handle-cache entry. at lets ResolveHandles honour a shorter bound than the 60 s
// TTL: mentions are stored permanently, so a stale handle->uid mapping must not outlive notFoundTTL (G5).
type handleEntry struct {
	uid string
	at  time.Time
}

// NewCache builds the cache. ttl is the profile/handle TTL (config.CacheTTL, default 60s).
func NewCache(ttl time.Duration) *Cache {
	return &Cache{
		profiles:   cache.New[string, Profile](cacheCapacity, ttl),
		handles:    cache.New[string, handleEntry](cacheCapacity, ttl),
		unread:     cache.New[string, int64](cacheCapacity, unreadTTL),
		notFound:   cache.New[string, struct{}](cacheCapacity, notFoundTTL),
		handleFree: cache.New[string, struct{}](cacheCapacity, notFoundTTL),
		now:        time.Now,
	}
}

func (c *Cache) GetProfile(uid string) (Profile, bool) {
	return c.profiles.Get(uid)
}

// SetProfile caches p and its handle->uid mapping. Call this with data just written, not a re-read. Also
// clears any "no profile yet" negative-cache entry for this uid (M1: CreateProfile overwrites it) — after
// this call, GetProfile already answers positively before GetNotFound would ever be consulted, but
// clearing it too avoids a stale entry lingering for its remaining TTL.
func (c *Cache) SetProfile(p Profile) {
	c.profiles.Set(p.UserID, p)
	if p.HandleLower != "" {
		c.handles.Set(p.HandleLower, handleEntry{uid: p.UserID, at: c.now()})
		c.handleFree.Delete(p.HandleLower)
	}
	c.notFound.Delete(p.UserID)
}

// GetNotFound reports whether uid was confirmed to have no profile within the last notFoundTTL (M1).
func (c *Cache) GetNotFound(uid string) bool {
	_, ok := c.notFound.Get(uid)
	return ok
}

// SetNotFound records that uid has no profile, for notFoundTTL.
func (c *Cache) SetNotFound(uid string) {
	c.notFound.Set(uid, struct{}{})
}

func (c *Cache) InvalidateProfile(uid string) {
	c.profiles.Delete(uid)
}

func (c *Cache) GetHandleUID(handleLower string) (string, bool) {
	e, ok := c.handles.Get(handleLower)
	return e.uid, ok
}

// GetHandleUIDFresh is GetHandleUID for entries learned at most maxAge ago; an older entry is a miss (it is left
// in place and replaced by the next fresh read).
func (c *Cache) GetHandleUIDFresh(handleLower string, maxAge time.Duration) (string, bool) {
	e, ok := c.handles.Get(handleLower)
	if !ok || c.now().Sub(e.at) > maxAge {
		return "", false
	}
	return e.uid, true
}

// SetHandleUID records that handleLower is owned by uid, from a fresh handles/* read (ResolveHandles). It never
// touches the profile cache.
func (c *Cache) SetHandleUID(handleLower, uid string) {
	c.handles.Set(handleLower, handleEntry{uid: uid, at: c.now()})
	c.handleFree.Delete(handleLower)
}

// InvalidateHandle drops a stale handle->uid mapping (e.g. after ChangeHandle frees the old handle).
func (c *Cache) InvalidateHandle(handleLower string) {
	c.handles.Delete(handleLower)
}

func (c *Cache) GetUnreadCount(uid string) (int64, bool) {
	return c.unread.Get(uid)
}

func (c *Cache) SetUnreadCount(uid string, n int64) {
	c.unread.Set(uid, n)
}

func (c *Cache) InvalidateUnreadCount(uid string) {
	c.unread.Delete(uid)
}

// GetHandleFree reports whether handleLower was confirmed unclaimed within the last notFoundTTL.
func (c *Cache) GetHandleFree(handleLower string) bool {
	_, ok := c.handleFree.Get(handleLower)
	return ok
}

// SetHandleFree records that handleLower resolved to NotFound, for notFoundTTL.
func (c *Cache) SetHandleFree(handleLower string) {
	c.handleFree.Set(handleLower, struct{}{})
}

// InvalidateHandleFree drops a negative handle entry (the handle was just claimed).
func (c *Cache) InvalidateHandleFree(handleLower string) {
	c.handleFree.Delete(handleLower)
}
