// removals.go is the read side of the moderation removal log (ADR-0016 D10, plan T15): a bounded, instance-cached
// view of postRemovals/{postId} that tells a refreshing timeline client which posts a moderator hid after the
// client's since token was issued, so the client can drop those cards. The write side is in moderate.go (the
// same transaction or batch as the moderation field, so a crash can never hide a post without logging it).
//
// Cost (rule 3, "bounded"): the instance holds at most removalKeep entries. Cold start: one query for the newest
// removalPage entries (1 read when the log is empty, never more than 50). Warm: the cache serves with 0 reads;
// once it is older than the TTL, one incremental query (createdAt > lastSeen - overlap, Limit 50, ascending; 1
// read when nothing changed). A full incremental page means the log moved a lot (a suspension): the cache is
// reloaded from the newest 50 instead of paging forward, and a client whose token is older than the oldest
// loaded entry is told to reset (truncated) rather than being served a partial list.
package posts

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

// RemovalState is what the log says about a post.
type RemovalState string

const (
	// RemovalRemoved: a moderator hid the post (TAKEN_DOWN or SUSPENDED_AUTHOR).
	RemovalRemoved RemovalState = "REMOVED"
	// RemovalRestored: a moderator un-hid the post. The entry overwrites the REMOVED one (same doc id) with a newer
	// createdAt, which is how a warm instance that cached the removal learns it no longer applies (an incremental
	// createdAt query never sees a delete).
	RemovalRestored RemovalState = "RESTORED"
)

const (
	removalsCollection = "postRemovals"

	// RemovalRetention is how long a log entry lives (its expireAt). It is set against the timeline since token:
	// default TTL 30 days (config.TimelineTokenTTL) + the lag the reader subtracts from the token's issue time
	// (about 100 s) + the 24 h Firestore TTL deletion lag, rounded up. A configured token TTL beyond this is
	// still safe: the reader refuses to answer for a token older than its coverage floor (truncated).
	RemovalRetention = 32 * 24 * time.Hour

	// RemovalMaxIDs is the most removed ids one response carries (and the page of every log query, CLAUDE.md rule 5).
	RemovalMaxIDs = MaxLimit

	// removalKeep bounds the instance's in-memory set. Entries older than the newest removalKeep are dropped and
	// the coverage floor moves up with them.
	removalKeep = 200

	// removalOverlap re-reads this much of the log behind lastSeen on every incremental query. createdAt is a
	// server timestamp taken at commit, but two commits can land out of order by a few milliseconds; the overlap
	// is deduplicated by post id, so it costs only the reads of entries newer than lastSeen - overlap.
	removalOverlap = 10 * time.Second
)

// RemovalEntry is one log row. It holds no user id: the log is not personal data (ADR-0011 Q10 table row).
type RemovalEntry struct {
	PostID string
	State  RemovalState
	// At is the server commit time of the entry (createdAt).
	At time.Time
}

// RemovalSource is the storage the RemovalLog reads. Every method issues exactly one query with the given Limit
// and charges its reads (one per document, minimum 1) to the budget counter in ctx.
type RemovalSource interface {
	// Newest returns up to limit entries with At > floor, newest first.
	Newest(ctx context.Context, floor time.Time, limit int) ([]RemovalEntry, error)
	// After returns up to limit entries with At > after, oldest first.
	After(ctx context.Context, after time.Time, limit int) ([]RemovalEntry, error)
}

// RemovalLog implements Removals over a RemovalSource with a TTL'd instance cache.
type RemovalLog struct {
	src RemovalSource
	ttl time.Duration
	now func() time.Time

	// mu is held across the refresh query so concurrent requests on a cold or expired cache share one read. The
	// query runs under the first caller's context (10 s deadline); a refresh is one Limit-50 query.
	mu        sync.Mutex
	loaded    bool
	fetchedAt time.Time
	lastSeen  time.Time
	coverFrom time.Time
	entries   map[string]RemovalEntry
}

var _ Removals = (*RemovalLog)(nil)

// NewRemovalLog builds the cache. ttl is config.CacheTTL; now nil means time.Now (tests inject a fake clock).
func NewRemovalLog(src RemovalSource, ttl time.Duration, now func() time.Time) *RemovalLog {
	if now == nil {
		now = time.Now
	}
	return &RemovalLog{src: src, ttl: ttl, now: now}
}

// RemovedSince implements Removals.
func (l *RemovalLog) RemovedSince(ctx context.Context, cutoff time.Time) ([]string, bool, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if !l.loaded || now.Sub(l.fetchedAt) >= l.ttl {
		if err := l.refreshLocked(ctx, now); err != nil {
			return nil, false, err
		}
	}
	if cutoff.Before(l.coverFrom) {
		return nil, true, nil
	}
	var hits []RemovalEntry
	for _, e := range l.entries {
		if e.State == RemovalRemoved && e.At.After(cutoff) {
			hits = append(hits, e)
		}
	}
	if len(hits) > RemovalMaxIDs {
		return nil, true, nil
	}
	if len(hits) == 0 {
		return nil, false, nil
	}
	sort.Slice(hits, func(i, j int) bool {
		if !hits[i].At.Equal(hits[j].At) {
			return hits[i].At.After(hits[j].At)
		}
		return hits[i].PostID > hits[j].PostID
	})
	ids := make([]string, len(hits))
	for i, e := range hits {
		ids[i] = e.PostID
	}
	return ids, false, nil
}

func (l *RemovalLog) refreshLocked(ctx context.Context, now time.Time) error {
	if !l.loaded {
		return l.reloadLocked(ctx, now)
	}
	es, err := l.src.After(ctx, l.lastSeen.Add(-removalOverlap), RemovalMaxIDs)
	if err != nil {
		return fmt.Errorf("posts: removal log: incremental read: %w", err)
	}
	if len(es) >= RemovalMaxIDs {
		return l.reloadLocked(ctx, now) // a burst (suspension): do not page forward
	}
	for _, e := range es {
		if cur, ok := l.entries[e.PostID]; !ok || !e.At.Before(cur.At) {
			l.entries[e.PostID] = e
		}
		if e.At.After(l.lastSeen) {
			l.lastSeen = e.At
		}
	}
	l.pruneLocked(now)
	l.fetchedAt = now
	return nil
}

// reloadLocked replaces the cache with the newest RemovalMaxIDs live entries. A short answer means the whole live
// log is loaded (coverage reaches the retention floor); a full one covers only back to its oldest entry.
func (l *RemovalLog) reloadLocked(ctx context.Context, now time.Time) error {
	floor := now.Add(-RemovalRetention)
	es, err := l.src.Newest(ctx, floor, RemovalMaxIDs)
	if err != nil {
		return fmt.Errorf("posts: removal log: load: %w", err)
	}
	m := make(map[string]RemovalEntry, len(es))
	cover, last := floor, floor
	for _, e := range es {
		m[e.PostID] = e
		if e.At.After(last) {
			last = e.At
		}
	}
	if len(es) >= RemovalMaxIDs {
		cover = es[len(es)-1].At // newest first: the last one is the oldest loaded
	}
	l.entries, l.coverFrom, l.lastSeen, l.loaded, l.fetchedAt = m, cover, last, true, now
	return nil
}

// pruneLocked drops expired entries and keeps at most removalKeep, raising the coverage floor past what it drops.
func (l *RemovalLog) pruneLocked(now time.Time) {
	floor := now.Add(-RemovalRetention)
	if floor.After(l.coverFrom) {
		l.coverFrom = floor
	}
	for id, e := range l.entries {
		if !e.At.After(floor) {
			delete(l.entries, id)
		}
	}
	if len(l.entries) <= removalKeep {
		return
	}
	all := make([]RemovalEntry, 0, len(l.entries))
	for _, e := range l.entries {
		all = append(all, e)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].At.After(all[j].At) })
	for _, e := range all[removalKeep:] {
		delete(l.entries, e.PostID)
		if e.At.After(l.coverFrom) {
			l.coverFrom = e.At
		}
	}
}
