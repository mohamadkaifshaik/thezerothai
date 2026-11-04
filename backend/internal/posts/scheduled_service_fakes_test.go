package posts

import (
	"context"
	"errors"
	"time"
)

// fakeSchedRepo is an in-memory ScheduledRepo for the Scheduler unit tests. It extends fakeScheduledStore (list,
// export, purge) with the schedule/count/cancel methods.
type fakeSchedRepo struct {
	*fakeScheduledStore

	// mediaNotReady makes the media load fail with ErrMediaNotReady; mediaRefs are the refs it returns per id.
	mediaNotReady bool
	// raceDoc, when set, is inserted by CreateScheduled and reported as ErrScheduledExists: a concurrent first call of
	// the same key won the create.
	raceDoc *ScheduledPost
	// attemptWinners models the transaction retry: after the attempt with that number has read everything, the document
	// is committed by a concurrent call, the attempt conflicts and CreateScheduled runs the next attempt, which must
	// evaluate its checks again against the new state (the window cap lives inside the attempt).
	attemptWinners map[int]*ScheduledPost

	// Error injection (the first non-nil wins for its method) and call counters.
	getErr, countPendingErr, createErr, cancelErr error
	// windowErr fails the in-transaction window count (after the quotas read).
	windowErr                             error
	gets, pendingCounts, creates, cancels int
	windowEvals                           int // in-transaction window counts, one per attempt
	lastCreate                            ScheduledCreateParams
	lastPendingLimit                      int
	lastCancelTTL                         time.Duration
}

func newFakeSchedRepo(ps ...*ScheduledPost) *fakeSchedRepo {
	return &fakeSchedRepo{fakeScheduledStore: newFakeScheduledStore(ps...)}
}

var _ ScheduledRepo = (*fakeSchedRepo)(nil)

func copyScheduled(p *ScheduledPost) *ScheduledPost {
	cp := *p
	if p.Draft != nil {
		d := *p.Draft
		d.Media = append([]MediaRef(nil), p.Draft.Media...)
		cp.Draft = &d
	}
	return &cp
}

func (f *fakeSchedRepo) find(uid, id string) *ScheduledPost {
	for _, p := range f.docs[uid] {
		if p.ID == id {
			return p
		}
	}
	return nil
}

// stored returns the live document (for assertions); nil when absent.
func (f *fakeSchedRepo) stored(uid, id string) *ScheduledPost {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.find(uid, id)
}

func (f *fakeSchedRepo) GetScheduled(ctx context.Context, uid, id string) (*ScheduledPost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	if f.getErr != nil {
		return nil, f.getErr
	}
	p := f.find(uid, id)
	if p == nil {
		return nil, ErrScheduledNotFound
	}
	return copyScheduled(p), nil
}

func (f *fakeSchedRepo) CountPending(ctx context.Context, uid string, limit int) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.pendingCounts++
	f.lastPendingLimit = limit
	if f.countPendingErr != nil {
		return 0, f.countPendingErr
	}
	var n int64
	for _, p := range f.docs[uid] {
		if p.Status == ScheduledPending {
			n++
		}
	}
	return min(n, int64(limit)), nil
}

// windowCount counts uid's PENDING items within +/-ScheduledWindowRadius of center (inclusive), like windowQuery.
func (f *fakeSchedRepo) windowCount(uid string, center time.Time, limit int) int64 {
	var n int64
	for _, p := range f.docs[uid] {
		if p.Status == ScheduledPending && !p.PublishAt.Before(center.Add(-ScheduledWindowRadius)) && !p.PublishAt.After(center.Add(ScheduledWindowRadius)) {
			n++
		}
	}
	return min(n, int64(limit))
}

// CreateScheduled models FirestoreRepo.CreateScheduled: attempts repeat while a concurrent winner is committed after an
// attempt's reads (attemptWinners), and every attempt evaluates the window and the daily cap against the state it sees.
func (f *fakeSchedRepo) CreateScheduled(ctx context.Context, p ScheduledCreateParams) (*ScheduledPost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates++
	f.lastCreate = p
	if p.WindowCap < 1 {
		return nil, errors.New("fake: window cap must be at least 1") // the repository refuses it too
	}
	for attempt := 1; ; attempt++ {
		doc, conflicted, err := f.createAttempt(ctx, p, attempt)
		if conflicted {
			continue
		}
		return doc, err
	}
}

// createAttempt is one transaction attempt. conflicted reports that a concurrent winner committed while it was open,
// so the caller must run another attempt (nothing of this one was written).
func (f *fakeSchedRepo) createAttempt(ctx context.Context, p ScheduledCreateParams, attempt int) (doc *ScheduledPost, conflicted bool, err error) {
	if f.createErr != nil {
		return nil, false, f.createErr
	}
	f.windowEvals++
	if f.windowErr != nil {
		return nil, false, f.windowErr
	}
	if f.windowCount(p.UID, p.PublishAt.UTC().Truncate(time.Minute), p.WindowCap+1) >= int64(p.WindowCap) {
		if f.find(p.UID, p.ID) != nil {
			return nil, false, ErrScheduledExists
		}
		return nil, false, ErrScheduledWindowFull
	}
	var refs []MediaRef
	if len(p.MediaIDs) > 0 {
		if f.mediaNotReady {
			return nil, false, ErrMediaNotReady
		}
		for _, id := range p.MediaIDs {
			refs = append(refs, MediaRef{ID: id, URL: "https://m/" + id, ThumbURL: "https://m/t" + id})
		}
		refs = mediaWithAlts(refs, p.MediaAlts)
	}
	if f.raceDoc != nil {
		f.docs[f.raceDoc.UID] = append(f.docs[f.raceDoc.UID], f.raceDoc)
		return nil, false, ErrScheduledExists
	}
	if f.find(p.UID, p.ID) != nil {
		return nil, false, ErrScheduledExists
	}
	if w := f.attemptWinners[attempt]; w != nil {
		f.docs[w.UID] = append(f.docs[w.UID], w) // committed by another call while this attempt was open: it conflicts
		return nil, true, nil
	}
	draft := p.Draft
	draft.Media = refs
	created := &ScheduledPost{
		ID: p.ID, UID: p.UID, SchemaVersion: ScheduledSchemaVersion, Draft: &draft,
		PublishAt: p.PublishAt.UTC().Truncate(time.Minute), Status: ScheduledPending, RequestHash: p.RequestHash,
		CreatedAt: p.Now.UTC(), UpdatedAt: p.Now.UTC(),
	}
	f.docs[p.UID] = append(f.docs[p.UID], created)
	return copyScheduled(created), false, nil
}

func (f *fakeSchedRepo) CancelScheduled(ctx context.Context, uid, id string, now time.Time, ttl time.Duration) (*ScheduledPost, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancels++
	f.lastCancelTTL = ttl
	if f.cancelErr != nil {
		return nil, false, f.cancelErr
	}
	p := f.find(uid, id)
	if p == nil {
		return nil, false, ErrScheduledNotFound
	}
	if p.Status != ScheduledPending && p.Status != ScheduledFailed {
		return copyScheduled(p), false, nil
	}
	ScheduledTransition{To: ScheduledCancelled}.apply(p, now, ttl)
	return copyScheduled(p), true, nil
}

func (f *fakeSchedRepo) TransitionScheduled(context.Context, ScheduledRef, ScheduledTransition, time.Time, time.Duration) (ScheduledRef, bool, error) {
	panic("fakeSchedRepo: the sweep is not part of this change")
}

func (f *fakeSchedRepo) BumpScheduledAttempts(context.Context, ScheduledRef, time.Time) (ScheduledRef, bool, error) {
	panic("fakeSchedRepo: the sweep is not part of this change")
}

func (f *fakeSchedRepo) DueScheduled(context.Context, time.Time, int, *ScheduledDueCursor) (ScheduledDuePage, error) {
	panic("fakeSchedRepo: the sweep is not part of this change")
}
