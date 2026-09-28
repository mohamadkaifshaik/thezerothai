package ratelimit

import (
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// maxTrackedDailyKeys mirrors maxTrackedKeys's LRU-bounded-memory rationale for the per-instance daily cap.
const maxTrackedDailyKeys = 100_000

// DailyCap is an in-memory, per-instance, per-uid counter that resets at the IST calendar-day boundary
// (quota.TodayAt) rather than continuously refilling like Limiter's token bucket (ADR-0008 D7/T4: "an
// extension of the existing limiter... don't write a second limiter" — this reuses the same cache.LRU
// building block Limiter itself is built on, just with day-boundary semantics a token bucket cannot
// express). Approximate by design: it resets whenever a Cloud Run instance scales to zero and a new one
// starts, and the effective ceiling is roughly limit x max-instances — the same accepted trade-off as every
// other in-memory limiter here (no Redis at Stage 0).
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

// NewDailyCap builds a DailyCap allowing limit calls/key/IST-day. idleTTL bounds memory (a key idle for
// idleTTL is evicted regardless of its count, alongside maxTrackedDailyKeys).
func NewDailyCap(limit int64, idleTTL time.Duration) *DailyCap {
	if limit <= 0 {
		limit = 1
	}
	return &DailyCap{
		limit: limit,
		items: cache.New[string, *dailyCounter](maxTrackedDailyKeys, idleTTL),
		now:   time.Now,
	}
}

// Allow reports whether one more call for key is permitted today (IST). Once the limit is reached for the
// day it stays rejected until the IST day rolls over, regardless of how long ago the limit was hit (unlike
// Limiter, there is no partial refill).
func (d *DailyCap) Allow(key string) bool {
	today := quota.TodayAt(d.now())
	c, ok := d.items.Get(key)
	if !ok {
		c = &dailyCounter{day: today}
		d.items.Set(key, c)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.day != today {
		c.day = today
		c.count = 0
	}
	if c.count >= d.limit {
		return false
	}
	c.count++
	return true
}
