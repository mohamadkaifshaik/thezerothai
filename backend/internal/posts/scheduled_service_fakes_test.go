package posts

import (
	"context"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// fakeSchedRepo is an in-memory ScheduledRepo for the Scheduler unit tests. It extends fakeScheduledStore (list,
// export, purge) with the schedule/count/cancel methods and charges the same reads and writes as FirestoreRepo:
// Get 1 read; each count 1 read; Create 1 read (quotas) + len(MediaIDs) and 2 writes (1 read at the daily cap, which
// is checked before the media read); Cancel 1 read and 1 write (0 writes when the item is already terminal).
type fakeSchedRepo struct {
	*fakeScheduledStore

	// schedules is quotas.schedules per uid (the test day never rolls over).
	schedules map[string]int64
	// mediaNotReady makes the media load fail with ErrMediaNotReady; mediaRefs are the refs it returns per id.
	mediaNotReady bool
	// raceDoc, when set, is inserted by CreateScheduled and reported as ErrScheduledExists: a concurrent first call of
	// the same key won the create.
	raceDoc *ScheduledPost

	// Error injection (the first non-nil wins for its method) and call counters.
	getErr, countPendingErr, countWindowErr, createErr, cancelErr error
	gets, pendingCounts, windowCounts, creates, cancels           int
	lastCreate                                                    ScheduledCreateParams
	lastPendingLimit, lastWindowLimit                             int
	lastWindowCenter                                              time.Time
	lastCancelTTL                                                 time.Duration
}

func newFakeSchedRepo(ps ...*ScheduledPost) *fakeSchedRepo {
	return &fakeSchedRepo{fakeScheduledStore: newFakeScheduledStore(ps...), schedules: map[string]int64{}}
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
	budget.FromContext(ctx).AddReads(1)
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
	budget.FromContext(ctx).AddReads(1)
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

func (f *fakeSchedRepo) CountWindow(ctx context.Context, uid string, center time.Time, limit int) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.windowCounts++
	f.lastWindowLimit, f.lastWindowCenter = limit, center
	budget.FromContext(ctx).AddReads(1)
	if f.countWindowErr != nil {
		return 0, f.countWindowErr
	}
	var n int64
	for _, p := range f.docs[uid] {
		if p.Status == ScheduledPending && !p.PublishAt.Before(center.Add(-ScheduledWindowRadius)) && !p.PublishAt.After(center.Add(ScheduledWindowRadius)) {
			n++
		}
	}
	return min(n, int64(limit)), nil
}

func (f *fakeSchedRepo) CreateScheduled(ctx context.Context, p ScheduledCreateParams) (*ScheduledPost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates++
	f.lastCreate = p
	c := budget.FromContext(ctx)
	c.AddReads(1) // quotas
	if f.createErr != nil {
		return nil, f.createErr
	}
	if f.schedules[p.UID] >= p.QuotaLimit {
		return nil, quota.ExceededError(quota.Schedules, p.Now)
	}
	var refs []MediaRef
	if len(p.MediaIDs) > 0 {
		c.AddReads(int64(len(p.MediaIDs)))
		if f.mediaNotReady {
			return nil, ErrMediaNotReady
		}
		for _, id := range p.MediaIDs {
			refs = append(refs, MediaRef{ID: id, URL: "https://m/" + id, ThumbURL: "https://m/t" + id})
		}
		refs = mediaWithAlts(refs, p.MediaAlts)
	}
	if f.raceDoc != nil {
		f.docs[f.raceDoc.UID] = append(f.docs[f.raceDoc.UID], f.raceDoc)
		return nil, ErrScheduledExists
	}
	if f.find(p.UID, p.ID) != nil {
		return nil, ErrScheduledExists
	}
	draft := p.Draft
	draft.Media = refs
	doc := &ScheduledPost{
		ID: p.ID, UID: p.UID, SchemaVersion: ScheduledSchemaVersion, Draft: &draft,
		PublishAt: p.PublishAt.UTC().Truncate(time.Minute), Status: ScheduledPending, RequestHash: p.RequestHash,
		CreatedAt: p.Now.UTC(), UpdatedAt: p.Now.UTC(),
	}
	f.docs[p.UID] = append(f.docs[p.UID], doc)
	f.schedules[p.UID]++
	c.AddWrites(2)
	return copyScheduled(doc), nil
}

func (f *fakeSchedRepo) CancelScheduled(ctx context.Context, uid, id string, now time.Time, ttl time.Duration) (*ScheduledPost, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancels++
	f.lastCancelTTL = ttl
	c := budget.FromContext(ctx)
	c.AddReads(1)
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
	c.AddWrites(1)
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
