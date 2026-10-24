package media

import (
	"context"
	"sync"
	"time"
)

// visionBudget is the SafeSearch cost meter: the month's unit count is read from admin/vision-{yyyymm} at most
// once per 60 s per instance and advanced locally by what this instance reserves, so up to max-instances (3)
// instances may overshoot the cap by a few units, which the cap's headroom already covers (ADR-0005).
type visionBudget struct {
	repo Repo
	cap  int64
	now  func() time.Time

	mu     sync.Mutex
	month  string
	used   int64
	loaded time.Time
}

const visionCacheTTL = 60 * time.Second

// monthKey is the counter's month, in UTC like Google Cloud billing.
func monthKey(t time.Time) string { return t.UTC().Format("200601") }

// reserve takes n units if they fit under the cap. It reads the counter (1 read) when the cached value is older
// than visionCacheTTL or from another month.
func (v *visionBudget) reserve(ctx context.Context, n int64) (bool, error) {
	if v.cap <= 0 {
		return false, nil
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	now, month := v.now(), monthKey(v.now())
	if v.month != month || now.Sub(v.loaded) >= visionCacheTTL {
		used, err := v.repo.VisionUsed(ctx, month)
		if err != nil {
			return false, err
		}
		v.month, v.used, v.loaded = month, used, now
	}
	if v.used+n > v.cap {
		return false, nil
	}
	v.used += n
	return true, nil
}

// release returns units reserved for a screening that failed before spending them.
func (v *visionBudget) release(n int64) {
	v.mu.Lock()
	v.used -= n
	v.mu.Unlock()
}
