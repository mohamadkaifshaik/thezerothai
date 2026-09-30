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
// (quota.TodayAt) rather than continuously refilling like Limiter's token bucket (ADR-0008 D7/T4: "an
// extension of the existing limiter... don't write a second limiter" — this reuses the same cache.LRU
// building block Limiter itself is built on, just with day-boundary semantics a token bucket cannot
// express). It counts calls (Allow) or arbitrary units such as Firestore reads (Reserve + Charge, the
// ADR-0010 D5 read budget) against the same per-key counter. Approximate by design: it resets whenever a
// Cloud Run instance scales to zero and a new one starts, and the effective ceiling is roughly
// limit x max-instances — the same accepted trade-off as every other in-memory limiter here (no Redis at
// Stage 0).
type DailyCap struct {
	limit int64
	// maxCallReads is one call's worst-case units (WithMaxCallReads); 0 disables the single-flight guard.
	maxCallReads int64
	items        *cache.LRU[string, *dailyCounter]
	now          func() time.Time
}

type dailyCounter struct {
	mu    sync.Mutex
	day   string
	count int64
	// inflight counts calls admitted by Reserve and not yet Released.
	inflight int
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

// WithMaxCallReads sets one call's worst-case units so Reserve can keep a single call in flight near the
// cap (ADR-0010 D5, M1) and returns d.
func (d *DailyCap) WithMaxCallReads(n int64) *DailyCap {
	d.maxCallReads = n
	return d
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
	// GetOrSet (not Get-miss-then-Set): two concurrent first accesses must share one counter, or a Charge
	// applied to the counter the second Set replaced would be lost.
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
// the limit was hit (unlike Limiter, there is no partial refill). It counts one unit atomically and never
// uses the in-flight count, so a cap that counts calls behaves exactly as before.
func (d *DailyCap) Allow(key string) bool {
	c := d.lock(key)
	defer c.mu.Unlock()
	if c.count >= d.limit {
		return false
	}
	c.count++
	return true
}

// Reserve admits one call for key and reports the units spent today, for the ADR-0010 D5 unit budget
// (Firestore reads): the check runs before the call and the actual cost is charged after by Release.
//
// It rejects (ok=false) when spent >= limit (the cap is reached: the caller retries at IST midnight) and,
// once WithMaxCallReads is set, also when another call is already in flight and spent + maxCallReads >
// limit (M1: near the cap only ONE call may be in flight, so concurrent callers cannot each pass the
// check and all overshoot; the caller retries in about a second, see IsTransient). An admitted call must
// be settled with exactly one Release.
func (d *DailyCap) Reserve(key string) (ok bool, spent int64) {
	c := d.lock(key)
	defer c.mu.Unlock()
	if c.count >= d.limit || (c.inflight > 0 && c.count+d.maxCallReads > d.limit) {
		return false, c.count
	}
	c.inflight++
	return true, c.count
}

// IsTransient reports whether a Reserve rejection that saw spent units is only the single-flight guard
// (retry in about a second) rather than the exhausted cap (retry at IST midnight).
func (d *DailyCap) IsTransient(spent int64) bool { return spent < d.limit }

// Charge adds n units to key's count for today (IST) without touching the in-flight count. n <= 0 is a
// no-op. It never rejects. Used directly by charge-only procedures (never reserved) and tests.
func (d *DailyCap) Charge(key string, n int64) {
	if n <= 0 {
		return
	}
	c := d.lock(key)
	defer c.mu.Unlock()
	c.count += n
}

// Release settles a call admitted by Reserve: it charges n units (n <= 0 charges nothing) and frees the
// in-flight slot in one step. It must run on every exit path of the call, including a panic.
func (d *DailyCap) Release(key string, n int64) {
	c := d.lock(key)
	defer c.mu.Unlock()
	if n > 0 {
		c.count += n
	}
	if c.inflight > 0 {
		c.inflight--
	}
}

// Spent returns the units key has spent today (IST).
func (d *DailyCap) Spent(key string) int64 {
	c := d.lock(key)
	defer c.mu.Unlock()
	return c.count
}
