// protected_set.go is identity's side of the protected-author set (ADR-0025 D2, D3): the immutable instance copy
// (identity.ProtectedSet) and the loader that implements identity.ProtectedAuthors. The set is a derived index of
// users.isPrivate, written only by the UpdateProfile toggle transaction and the identity eraser step.
package identity

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
)

const (
	// privacyCollection holds the one derived doc privacy/protectedAuthors (ADR-0025 D2). Identity owns it.
	privacyCollection = "privacy"
	// protectedAuthorsDoc is its document id.
	protectedAuthorsDoc = "protectedAuthors"

	protectedSetReadTimeout = 3 * time.Second
	// protectedSetRetryBackoff is the pause after a failed refresh before the next attempt, so an outage costs one
	// attempt per backoff on an instance rather than one per request.
	protectedSetRetryBackoff = 5 * time.Second

	fieldProtectedSetReads = "protected_set_reads"
)

// ErrProtectedSetUnavailable is returned by ProtectedAuthors.Current when the instance has no set younger than
// PROTECTED_SET_MAX_STALE (never loaded, or every refresh failed for that long). Callers answer UNAVAILABLE
// (retryable) and must never treat it as "everyone is public" (ADR-0025 D3). It carries no uid.
var ErrProtectedSetUnavailable = errors.New("identity: protected set unavailable")

// protectedSet is the immutable snapshot behind ProtectedSet. Nothing mutates a published map: updates build a new one.
type protectedSet struct {
	uids map[string]struct{}
}

var _ ProtectedSet = (*protectedSet)(nil)

func newProtectedSet(uids []string) *protectedSet {
	m := make(map[string]struct{}, len(uids))
	for _, u := range uids {
		m[u] = struct{}{}
	}
	return &protectedSet{uids: m}
}

// Has implements ProtectedSet.
func (s *protectedSet) Has(uid string) bool {
	_, ok := s.uids[uid]
	return ok
}

// CanSee implements ProtectedSet: the one expression of the D3 predicate (AQ2).
func (s *protectedSet) CanSee(viewerUID, authorUID string, following bool) bool {
	return viewerUID == authorUID || !s.Has(authorUID) || following
}

// with returns a copy that holds (add) or lacks (!add) uid.
func (s *protectedSet) with(uid string, add bool) *protectedSet {
	m := make(map[string]struct{}, len(s.uids)+1)
	for u := range s.uids {
		m[u] = struct{}{}
	}
	if add {
		m[uid] = struct{}{}
	} else {
		delete(m, uid)
	}
	return &protectedSet{uids: m}
}

// ProtectedSetSource reads privacy/protectedAuthors. FirestoreRepo implements it.
type ProtectedSetSource interface {
	// LoadProtectedSet reads the set doc: 1 read (charged to the budget.Counter in ctx). A missing doc is an empty set.
	LoadProtectedSet(ctx context.Context) ([]string, error)
}

// ProtectedSetLoader implements ProtectedAuthors (ADR-0025 D3). Lazy: it reads only when a caller asks and its copy is
// older than ttl. Concurrent callers share one refresh (singleflight). The read runs on a detached counter logged as
// protected_set_reads, never charged to a caller. Reads: at most 1 per instance per ttl (60 s), plus at most one retry
// per 5 s while refreshes fail; 0 while idle.
//
// Staleness bound: a served set is at most ttl old, or, while refreshes fail, at most maxStale old (WARN
// protected_set_stale). Past maxStale, or never loaded, Current returns ErrProtectedSetUnavailable (ERROR
// protected_set_unavailable). The committing instance installs its own toggle at once (Install, Apply); other
// instances see it within ttl.
type ProtectedSetLoader struct {
	src      ProtectedSetSource
	ttl      time.Duration
	maxStale time.Duration
	now      func() time.Time
	log      *slog.Logger
	sf       singleflight.Group

	mu        sync.Mutex
	set       *protectedSet
	fetchedAt time.Time // when the read that produced set started (conservative)
	lastFail  time.Time
	gen       uint64 // bumped by Install and Apply so a refresh in flight can tell a local write landed during its read
	installs  uint64 // bumped by Install only: a fresh transaction copy that a refresh in flight must not replace
	inflight  bool   // a refresh read is in flight: Apply logs its deltas in applied (W3-40a, W3-36 L-3)
	applied   []setDelta
}

// setDelta is one Apply that landed while a refresh read was in flight, replayed onto the fetched copy.
type setDelta struct {
	uid       string
	protected bool
}

var _ ProtectedAuthors = (*ProtectedSetLoader)(nil)

// NewProtectedSetLoader builds the loader. ttl is config.CacheTTL, maxStale PROTECTED_SET_MAX_STALE; now nil means
// time.Now (tests inject a fake clock); log nil means slog.Default().
func NewProtectedSetLoader(src ProtectedSetSource, ttl, maxStale time.Duration, now func() time.Time, log *slog.Logger) *ProtectedSetLoader {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.Default()
	}
	return &ProtectedSetLoader{src: src, ttl: ttl, maxStale: maxStale, now: now, log: log}
}

// Current implements ProtectedAuthors.
func (l *ProtectedSetLoader) Current(ctx context.Context) (ProtectedSet, error) {
	now := l.now()
	l.mu.Lock()
	set, fetched, failed := l.set, l.fetchedAt, l.lastFail
	l.mu.Unlock()
	if set != nil && now.Sub(fetched) < l.ttl {
		return set, nil
	}
	if !failed.IsZero() && now.Sub(failed) < protectedSetRetryBackoff {
		return l.fallback(ctx, set, fetched, now)
	}
	ch := l.sf.DoChan("refresh", func() (any, error) { return nil, l.refresh(ctx) })
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case res := <-ch:
		l.mu.Lock()
		set, fetched = l.set, l.fetchedAt
		l.mu.Unlock()
		if res.Err == nil && set != nil {
			return set, nil
		}
		return l.fallback(ctx, set, fetched, l.now())
	}
}

// fallback serves the last good copy while it is younger than maxStale, otherwise fails closed.
func (l *ProtectedSetLoader) fallback(ctx context.Context, set *protectedSet, fetched, now time.Time) (ProtectedSet, error) {
	if set != nil && now.Sub(fetched) <= l.maxStale {
		l.log.WarnContext(ctx, "protected_set_stale", "age_s", int64(now.Sub(fetched).Seconds()))
		return set, nil
	}
	mw.ReportError(ctx, l.log, "protected_set_unavailable", ErrProtectedSetUnavailable)
	return nil, ErrProtectedSetUnavailable
}

// refresh runs the one shared read. It uses its own context (not the first caller's cancellation) and its own counter.
func (l *ProtectedSetLoader) refresh(reqCtx context.Context) error {
	rctx, cancel := context.WithTimeout(context.WithoutCancel(reqCtx), protectedSetReadTimeout)
	defer cancel()
	rctx, counter := budget.WithCounter(rctx)
	l.mu.Lock()
	// Re-check inside the flight: a flight that finished just before this one started has already refreshed.
	if l.set != nil && l.now().Sub(l.fetchedAt) < l.ttl {
		l.mu.Unlock()
		return nil
	}
	gen, installs := l.gen, l.installs
	l.inflight, l.applied = true, nil
	l.mu.Unlock()
	started := l.now()
	uids, err := l.src.LoadProtectedSet(rctx)
	logger.SetRequestField(reqCtx, fieldProtectedSetReads, counter.Reads())
	l.mu.Lock()
	defer l.mu.Unlock()
	deltas := l.applied
	l.inflight, l.applied = false, nil
	if err != nil {
		l.lastFail = started
		return fmt.Errorf("identity: load protected set: %w", err)
	}
	l.lastFail = time.Time{}
	if l.installs != installs {
		// A transaction copy was installed while the read was in flight: it is fresher than the read. Keep it.
		return nil
	}
	fetched := newProtectedSet(uids)
	if l.gen != gen {
		// A local toggle landed while the read was in flight, so the fetched copy may predate it. Install the fetched
		// copy with those toggles re-applied: the local write is kept and the copy's age is the read's, so Current
		// never serves a copy older than maxStale because a refresh was thrown away (W3-36 L-3).
		for _, d := range deltas {
			fetched = fetched.with(d.uid, d.protected)
		}
	}
	l.set, l.fetchedAt = fetched, started
	return nil
}

// Install replaces the instance copy with uids read inside a committed transaction (fresh at commitAt), so the
// committing instance applies a toggle at once even if it never loaded the set.
func (l *ProtectedSetLoader) Install(uids []string, commitAt time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.set, l.fetchedAt, l.lastFail = newProtectedSet(uids), commitAt, time.Time{}
	l.gen++
	l.installs++
}

// Apply records a committed toggle in the instance copy. An instance that never loaded a set keeps none (it must not
// invent one) and will read it on demand. The copy's age is unchanged, so the next refresh still reads the truth.
func (l *ProtectedSetLoader) Apply(uid string, protected bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.set == nil {
		return
	}
	l.set = l.set.with(uid, protected)
	l.gen++
	if l.inflight {
		l.applied = append(l.applied, setDelta{uid: uid, protected: protected})
	}
}
