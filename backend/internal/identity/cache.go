package identity

import (
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

const (
	// cacheCapacity bounds memory for each LRU independent of DAU.
	cacheCapacity = 20_000
	// unreadTTL matches the proto doc comment ("cached 30 s") for GetMe's notification count.
	unreadTTL = 30 * time.Second
	// pendingTTL bounds GetMe's pending_follow_request_count: at most 30 s stale on this instance, and
	// evicted by any Forget or ForgetUnread on this instance (an accept, a notification row, a counter change), even when
	// ForgetUnread keeps an unread count that is at the cap.
	pendingTTL = 30 * time.Second
	// convBadgeTTL bounds GetMe's unread_conversation_count: at most 30 s stale on this
	// instance, evicted earlier by MessageBadgeCache.Forget (a send to or a mark-read by that user on this instance).
	convBadgeTTL = 30 * time.Second
	// notFoundTTL (M1) is deliberately short: a signed-up-but-profile-less caller hitting any non-exempt
	// RPC would otherwise re-read users/{uid} on every single call (authn.AccountStatusInterceptor ->
	// AccountStatus -> getProfileCached), burning the daily Firestore read quota for free before rate
	// limiting even has a chance to matter across a burst. ~10s bounds that to at most one read per 10s per
	// uid, while staying short enough that a real CreateProfile (which also actively clears this entry,
	// see SetProfile) is never masked by a stale negative result for long.
	notFoundTTL = 10 * time.Second
	// publicIDTTL bounds the two public id maps. The mapping is immutable (an id is never reissued or reused), so the TTL
	// is only a memory refresh, not a correctness bound. Erasure: the erasing instance evicts both directions, but that
	// is not reliable (a later SetProfile of the DELETING profile, from any read of it, re-adds both entries), and every
	// other instance keeps its entries; so a public id -> uid entry of an erased account can live up to this TTL on any
	// instance. That is safe only because every consumer re-checks users/{uid} (GetProfile's status check answers the
	// uniform NOT_FOUND for a DELETING or absent account, exactly as for an unknown id). The uid -> public id direction
	// only names the id the account had.
	publicIDTTL = time.Hour
)

// Cache is identity's instance cache (users/{uid} cached 60s; project rule: "update the instance cache from written data instead of re-reading").
// One per process; safe for concurrent use.
type Cache struct {
	profiles  *cache.LRU[string, Profile]
	handles   *cache.LRU[string, handleEntry] // handleLower -> uid and when it was learned
	unread    *cache.LRU[string, int64]
	convBadge *cache.LRU[string, int64]    // uid -> unread conversation count (callers with messaging on only)
	pending   *cache.LRU[string, int64]    // uid -> pending follow request count (protected callers only)
	notFound  *cache.LRU[string, struct{}] // uid -> "no profile yet" (M1 negative cache)
	// handleFree is the negative handle cache: handleLower -> "ResolveHandle said NotFound" for
	// notFoundTTL. Only a hint: CreateProfile/ChangeHandle stay transactional (handles Create), so a stale
	// "free" answer can never produce a duplicate handle.
	handleFree *cache.LRU[string, struct{}]
	// pubToUID and uidToPub are the public id maps (publicIDTTL); pubFree is the 10 s negative cache of unknown public ids.
	pubToUID *cache.LRU[string, string]
	uidToPub *cache.LRU[string, string]
	pubFree  *cache.LRU[string, struct{}]
	now      func() time.Time // overridable for tests
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
		pending:    cache.New[string, int64](cacheCapacity, pendingTTL),
		convBadge:  cache.New[string, int64](cacheCapacity, convBadgeTTL),
		notFound:   cache.New[string, struct{}](cacheCapacity, notFoundTTL),
		handleFree: cache.New[string, struct{}](cacheCapacity, notFoundTTL),
		pubToUID:   cache.New[string, string](cacheCapacity, publicIDTTL),
		uidToPub:   cache.New[string, string](cacheCapacity, publicIDTTL),
		pubFree:    cache.New[string, struct{}](cacheCapacity, notFoundTTL),
		now:        time.Now,
	}
}

// SetPublicID records the immutable pair in both directions and clears a negative entry for the id.
func (c *Cache) SetPublicID(uid, publicID string) {
	if uid == "" || publicID == "" {
		return
	}
	c.pubToUID.Set(publicID, uid)
	c.uidToPub.Set(uid, publicID)
	c.pubFree.Delete(publicID)
}

// UIDForPublicID returns the cached owner of publicID.
func (c *Cache) UIDForPublicID(publicID string) (string, bool) { return c.pubToUID.Get(publicID) }

// PublicIDForUID returns the cached public id of uid.
func (c *Cache) PublicIDForUID(uid string) (string, bool) { return c.uidToPub.Get(uid) }

// GetPublicIDFree reports whether publicID was confirmed unknown within the last notFoundTTL.
func (c *Cache) GetPublicIDFree(publicID string) bool {
	_, ok := c.pubFree.Get(publicID)
	return ok
}

// SetPublicIDFree records that publicID has no lookup document, for notFoundTTL.
func (c *Cache) SetPublicIDFree(publicID string) { c.pubFree.Set(publicID, struct{}{}) }

// InvalidatePublicID drops both directions (the account's erasure removed the lookup).
func (c *Cache) InvalidatePublicID(uid, publicID string) {
	if publicID != "" {
		c.pubToUID.Delete(publicID)
	}
	if uid != "" {
		c.uidToPub.Delete(uid)
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
	c.SetPublicID(p.UserID, p.PublicID)
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
	c.pending.Delete(uid)
}

// InvalidateUnreadBelowCap is InvalidateUnreadCount for a new notification row: a cached unread count already at
// UnreadBadgeCap is kept (a new row cannot raise a capped badge, and that miss is the most expensive one, audit L1),
// any lower count is evicted. The pending follow request count is always evicted (the row may be a follow request).
// A kept count still expires with its own unreadTTL; Forget and InvalidateUnreadCount always evict.
func (c *Cache) InvalidateUnreadBelowCap(uid string) {
	if n, ok := c.unread.Get(uid); !ok || n < UnreadBadgeCap {
		c.unread.Delete(uid)
	}
	c.pending.Delete(uid)
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

// GetPendingCount returns the cached pending follow request count of a protected account (30 s).
func (c *Cache) GetPendingCount(uid string) (int64, bool) { return c.pending.Get(uid) }

// SetPendingCount caches the count for pendingTTL.
func (c *Cache) SetPendingCount(uid string, n int64) { c.pending.Set(uid, n) }

// GetConversationBadge returns the cached unread conversation count (30 s).
func (c *Cache) GetConversationBadge(uid string) (int64, bool) { return c.convBadge.Get(uid) }

// SetConversationBadge caches the count for convBadgeTTL.
func (c *Cache) SetConversationBadge(uid string, n int64) { c.convBadge.Set(uid, n) }

// InvalidateConversationBadge drops uid's cached unread conversation count only.
func (c *Cache) InvalidateConversationBadge(uid string) { c.convBadge.Delete(uid) }
