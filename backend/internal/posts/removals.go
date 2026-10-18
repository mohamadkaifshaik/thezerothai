// removals.go is the read side of the moderation removal log (ADR-0016 D10, plan T15): a bounded, instance-cached
// view of postRemovals/{postId} that tells a refreshing timeline client which posts a moderator hid after the
// client's since token was issued, so the client can drop those cards. The write side is in moderate.go (the
// same transaction or batch as the moderation field, so a crash can never hide a post without logging it).
//
// Cost (rule 3, "bounded"): the instance holds at most removalKeep entries. Cold start: one query for the newest
// RemovalMaxIDs entries (1 read when the log is empty, never more than 50). Warm: the cache serves with 0 reads;
// once it is older than the TTL, one incremental query ordered by (createdAt, doc id) that starts strictly after
// the last entry seen (Limit 50; 1 read when nothing changed). It never re-reads an entry the instance already
// holds, so a burst of 250 entries sharing one commit timestamp costs the cold load once and 1 read per TTL
// after that. A full incremental page means genuinely new activity (a suspension): the cache is reloaded from
// the newest 50 instead of paging forward (RemovalWorstReads = 100, once), lastSeen moves past the whole burst,
// and a client whose token is older than the oldest loaded entry is told to reset (truncated) rather than being
// served a partial list.
//
// Failure (ADR-0016 D10 implementation notes): the log query runs under its own removalQueryTimeout, a request
// waiting for another request's refresh gives up on its own context, and a refresh that fails on an instance that
// already holds data serves that stale data (logged at ERROR) instead of failing the timeline refresh.
package posts

import (
	"context"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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
	// (about 135 s) + the 24 h Firestore TTL deletion lag, rounded up. A configured token TTL beyond this is
	// still safe: the reader refuses to answer for a token older than its coverage floor (truncated).
	RemovalRetention = 32 * 24 * time.Hour

	// RemovalMaxIDs is the most removed ids one response carries (and the page of every log query, CLAUDE.md rule 5).
	RemovalMaxIDs = MaxLimit

	// RemovalWorstReads is the most Firestore reads one RemovedSince call can charge: a full incremental page (50)
	// followed by the reload of the newest 50. config.RemovalLogMaxReads is the copy the read budget uses; a test
	// pins them equal.
	RemovalWorstReads = 2 * RemovalMaxIDs

	// RemovalLag is how far before a since token's issue time the log is consulted (timeline passes
	// issued - RemovalLag as the cutoff). A card can reach a client up to CACHE_TTL after a moderator hid its post
	// (the author-recent and post caches), and the log cache of the serving instance can lag the log by another
	// CACHE_TTL, so a removal can first become visible to a refresh up to 2 x CACHE_TTL after it was written; the
	// margin covers clock skew between instances. The cost of being generous is a few ids repeated in a response
	// (which the client ignores) and, after a big burst, tokens issued up to RemovalLag after it being rejected too.
	RemovalLag = 2*config.MaxCacheTTL + 15*time.Second

	// removalKeep bounds the instance's in-memory set. Entries older than the newest removalKeep are dropped and
	// the coverage floor moves up with them.
	removalKeep = 200

	// removalQueryTimeout bounds one log query (the request deadline is 10 s; the log is one Limit-50 query).
	removalQueryTimeout = 2 * time.Second
	// removalRetryBackoff is how soon a failed refresh is retried while stale data is being served, so a Firestore
	// outage costs one 2 s attempt per backoff rather than one per request.
	removalRetryBackoff = 5 * time.Second
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
	// Newest returns up to limit entries with At > floor, newest first, ordered by (At, post id) descending.
	Newest(ctx context.Context, floor time.Time, limit int) ([]RemovalEntry, error)
	// After returns up to limit entries strictly after the position (afterAt, afterID) in (At, post id) ascending
	// order, oldest first. afterID may be empty, meaning every entry with At > afterAt. Entries with At == afterAt
	// and a larger id are returned, so entries that share one commit timestamp are never skipped or re-read.
	After(ctx context.Context, afterAt time.Time, afterID string, limit int) ([]RemovalEntry, error)
}

// RemovalLog implements Removals over a RemovalSource with a TTL'd instance cache.
type RemovalLog struct {
	src          RemovalSource
	ttl          time.Duration
	now          func() time.Time
	queryTimeout time.Duration

	// sem (capacity 1) is held across the refresh query so concurrent requests on a cold or expired cache share one
	// read. It is a channel rather than a sync.Mutex so a waiter can give up on its own context.
	sem       chan struct{}
	loaded    bool
	fetchedAt time.Time
	// lastAt/lastID is the greatest (createdAt, post id) position seen: the next incremental query starts after it.
	lastAt    time.Time
	lastID    string
	coverFrom time.Time
	entries   map[string]RemovalEntry
}

var _ Removals = (*RemovalLog)(nil)

// NewRemovalLog builds the cache. ttl is config.CacheTTL; now nil means time.Now (tests inject a fake clock).
func NewRemovalLog(src RemovalSource, ttl time.Duration, now func() time.Time) *RemovalLog {
	if now == nil {
		now = time.Now
	}
	return &RemovalLog{src: src, ttl: ttl, now: now, queryTimeout: removalQueryTimeout, sem: make(chan struct{}, 1)}
}

// RemovedSince implements Removals.
func (l *RemovalLog) RemovedSince(ctx context.Context, cutoff time.Time) ([]string, bool, error) {
	select {
	case l.sem <- struct{}{}:
	case <-ctx.Done():
		return nil, false, fmt.Errorf("posts: removal log: waiting for refresh: %w", ctx.Err())
	}
	defer func() { <-l.sem }()
	now := l.now()
	if !l.loaded || now.Sub(l.fetchedAt) >= l.ttl {
		qctx, cancel := context.WithTimeout(ctx, l.queryTimeout)
		err := l.refreshLocked(qctx, now)
		cancel()
		if err != nil {
			if !l.loaded {
				return nil, false, err
			}
			// Serve the stale cache: this instance has data, and failing every refresh for the length of a Firestore
			// blip is worse than a removal reaching clients one TTL late.
			slog.ErrorContext(ctx, "removal_log_refresh_failed_serving_stale", "err", logger.RedactErr(err),
				"entries", len(l.entries), "stale_for_ms", now.Sub(l.fetchedAt).Milliseconds())
			l.fetchedAt = now.Add(min(l.ttl, removalRetryBackoff) - l.ttl)
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
	es, err := l.src.After(ctx, l.lastAt, l.lastID, RemovalMaxIDs)
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
		if afterPos(e.At, e.PostID, l.lastAt, l.lastID) {
			l.lastAt, l.lastID = e.At, e.PostID
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
	cover, lastAt, lastID := floor, floor, ""
	for _, e := range es {
		m[e.PostID] = e
		if afterPos(e.At, e.PostID, lastAt, lastID) {
			lastAt, lastID = e.At, e.PostID
		}
	}
	if len(es) >= RemovalMaxIDs {
		cover = es[len(es)-1].At // newest first: the last one is the oldest loaded
	}
	l.entries, l.coverFrom, l.lastAt, l.lastID, l.loaded, l.fetchedAt = m, cover, lastAt, lastID, true, now
	return nil
}

// afterPos reports whether (at, id) sorts strictly after (refAt, refID) in (createdAt, doc id) order.
func afterPos(at time.Time, id string, refAt time.Time, refID string) bool {
	return at.After(refAt) || (at.Equal(refAt) && id > refID)
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
