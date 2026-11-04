package ratelimit

import (
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// maxTrackedDailyKeys mirrors maxTrackedKeys's LRU-bounded-memory rationale for the per-instance daily cap.
const maxTrackedDailyKeys = 100_000

// DailyCap is an in-memory, per-instance, per-key counter that resets at the IST calendar-day boundary
// (quota.TodayAt) rather than continuously refilling like Limiter's token bucket (an
// extension of the existing limiter, not a second limiter: it reuses the same cache.LRU
// building block Limiter itself is built on, just with day-boundary semantics a token bucket cannot
// express). It counts calls (Allow) or units (AllowN) against the same per-key counter. Approximate by design: the bound is per instance
// LIFETIME, not per day. The counter lives in memory, so it resets whenever a Cloud Run instance scales to zero
// and a new one starts, and a key can touch several lifetimes in one IST day (3 on a steady day, up to 6 on a
// rollout day, many more if an attacker idle-cycles instances). The same accepted trade-off as every other in-memory limiter here (no Redis at Stage 0).
type DailyCap struct {
	limit int64
	items *cache.LRU[string, *dailyCounter]
	now   func() time.Time
}

type dailyCounter struct {
	mu    sync.Mutex
	day   string
	count int64
}

// NewDailyCap builds a DailyCap allowing limit units (calls, for Allow) per key per IST day. Memory is
// bounded by maxTrackedDailyKeys (LRU) only: there is deliberately no idle TTL. L1 (security review): an
// entry TTL made a counter vanish 24h after its first use (mid-day), granting a second full allowance
// inside one IST day; the IST midnight rollover (lock) is the only reset. A stale entry from a previous day
// is reset lazily on its next access.
func NewDailyCap(limit int64) *DailyCap {
	if limit <= 0 {
		limit = 1
	}
	return &DailyCap{
		limit: limit,
		items: cache.New[string, *dailyCounter](maxTrackedDailyKeys, 0),
		now:   time.Now,
	}
}

// WithClock replaces the cap's clock (fake-clock tests in other packages) and returns d.
func (d *DailyCap) WithClock(now func() time.Time) *DailyCap {
	d.now = now
	return d
}

// lock returns key's counter for the current IST day, locked and rolled over if its day is stale. The
// caller must unlock it.
func (d *DailyCap) lock(key string) *dailyCounter {
	today := quota.TodayAt(d.now())
	// GetOrSet (not Get-miss-then-Set): two concurrent first accesses must share one counter, or units
	// counted on the counter the second Set replaced would be lost.
	c := d.items.GetOrSet(key, func() *dailyCounter { return &dailyCounter{day: today} })
	c.mu.Lock()
	if c.day != today {
		c.day = today
		c.count = 0
	}
	return c
}

// Allow reports whether one more call for key is permitted today (IST) and, if so, counts it. Once the
// limit is reached for the day it stays rejected until the IST day rolls over, regardless of how long ago
// the limit was hit (unlike Limiter, there is no partial refill). It counts one unit atomically.
func (d *DailyCap) Allow(key string) bool {
	c := d.lock(key)
	defer c.mu.Unlock()
	if c.count >= d.limit {
		return false
	}
	c.count++
	return true
}

// AllowN reports whether n more units for key are permitted today (IST) and, if so, counts them, all or nothing:
// when count + n would pass the limit nothing is counted and false is returned (so a rejected batch does not eat
// the remaining allowance). n <= 0 is always allowed and counts nothing.
func (d *DailyCap) AllowN(key string, n int64) bool {
	if n <= 0 {
		return true
	}
	c := d.lock(key)
	defer c.mu.Unlock()
	if c.count+n > d.limit {
		return false
	}
	c.count += n
	return true
}

// Spent returns the units key has spent today (IST).
func (d *DailyCap) Spent(key string) int64 {
	c := d.lock(key)
	defer c.mu.Unlock()
	return c.count
}

// Refund returns n units to key's count for today (IST), never below 0. n <= 0 is a no-op. It is the inverse of
// AllowN for units that were counted up front but never spent (a Vision-units charge taken before a call
// that was never sent). A refund that crosses IST midnight lands on the new day's counter and is floored at 0, so it can
// never grant more than one day's allowance.
func (d *DailyCap) Refund(key string, n int64) {
	if n <= 0 {
		return
	}
	c := d.lock(key)
	defer c.mu.Unlock()
	c.count = max(c.count-n, 0)
}
