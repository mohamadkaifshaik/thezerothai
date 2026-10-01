// Package ratelimit implements the in-memory, per-instance token buckets from ADR-0006 §3. Limits are
// approximate (effective ceiling is roughly limit x Cloud Run max-instances) — that's an accepted
// trade-off for $0 (no Redis).
package ratelimit

import (
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/cache"
)

// maxTrackedKeys bounds memory: idle buckets fall out of the LRU well before this many distinct
// uids/IPs are seen inside one TTL window (skill: "LRU-bounded").
const maxTrackedKeys = 100_000

// Limiter is a keyed token bucket: each key (uid or IP) gets its own bucket, refilled at ratePerMinute
// and capped at burst tokens.
type Limiter struct {
	ratePerSecond float64
	burst         float64
	buckets       *cache.LRU[string, *bucket]
	now           func() time.Time
}

type bucket struct {
	mu     sync.Mutex
	tokens float64
	last   time.Time
}

// NewLimiter builds a limiter allowing ratePerMinute requests/minute/key with a short burst allowance.
// idleTTL bounds how long an unused key's bucket is kept (also bounds memory alongside maxTrackedKeys).
func NewLimiter(ratePerMinute int, idleTTL time.Duration) *Limiter {
	if ratePerMinute <= 0 {
		ratePerMinute = 1
	}
	return &Limiter{
		ratePerSecond: float64(ratePerMinute) / 60.0,
		burst:         float64(ratePerMinute),
		buckets:       cache.New[string, *bucket](maxTrackedKeys, idleTTL),
		now:           time.Now,
	}
}

// Allow reports whether a request for key is permitted right now, and if not, how long the caller
// should wait before retrying (RESOURCE_EXHAUSTED + retry_after, ADR-0006 §3).
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	now := l.now()
	// GetOrSet: two concurrent first requests for a key must share one bucket (a Get-miss-then-Set pair let
	// the second Set replace the first, refunding a token). A new bucket starts full; the refill code below
	// then takes the first token, so the result is burst-1 exactly as before.
	b := l.buckets.GetOrSet(key, func() *bucket { return &bucket{tokens: l.burst, last: now} })

	b.mu.Lock()
	defer b.mu.Unlock()

	elapsed := now.Sub(b.last).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * l.ratePerSecond
		if b.tokens > l.burst {
			b.tokens = l.burst
		}
		b.last = now
	}
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.ratePerSecond * float64(time.Second))
	return false, wait
}
