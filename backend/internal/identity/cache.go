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
	handles  *cache.LRU[string, string] // handleLower -> uid
	unread   *cache.LRU[string, int64]
	notFound *cache.LRU[string, struct{}] // uid -> "no profile yet" (M1 negative cache)
}

// NewCache builds the cache. ttl is the profile/handle TTL (config.CacheTTL, default 60s).
func NewCache(ttl time.Duration) *Cache {
	return &Cache{
		profiles: cache.New[string, Profile](cacheCapacity, ttl),
		handles:  cache.New[string, string](cacheCapacity, ttl),
		unread:   cache.New[string, int64](cacheCapacity, unreadTTL),
		notFound: cache.New[string, struct{}](cacheCapacity, notFoundTTL),
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
		c.handles.Set(p.HandleLower, p.UserID)
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
	return c.handles.Get(handleLower)
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
