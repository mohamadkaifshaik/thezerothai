package media

import (
	"context"
	"sort"
	"sync"
	"time"
)

// fakeOrphanRepo is the in-memory OrphanRepo over a fakeRepo's documents, with the same UpdateTime preconditions as
// FirestoreRepo.
type fakeOrphanRepo struct {
	*fakeRepo
	dueLimits []int // the limit of every DueOrphans call
	sets      int   // SetOrphanState calls, won or lost
	deletes   int   // DeleteOrphan calls, won or lost
	// beforeSet, when set, runs at the start of every SetOrphanState with the document id (outside the lock): a concurrent
	// writer (an attach, another run) that commits first.
	beforeSet func(id string)
	setErr    error
}

func newFakeOrphanRepo() *fakeOrphanRepo { return &fakeOrphanRepo{fakeRepo: newFakeRepo()} }

func (r *fakeOrphanRepo) DueOrphans(_ context.Context, now time.Time, limit int) ([]*Doc, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dueLimits = append(r.dueLimits, limit)
	var due []*Doc
	for _, d := range r.docs {
		if d.OrphanCheckAt != nil && !d.OrphanCheckAt.After(now) {
			c := *d
			due = append(due, &c)
		}
	}
	sort.Slice(due, func(i, j int) bool {
		if !due[i].OrphanCheckAt.Equal(*due[j].OrphanCheckAt) {
			return due[i].OrphanCheckAt.Before(*due[j].OrphanCheckAt)
		}
		return due[i].ID < due[j].ID
	})
	if len(due) > limit {
		due = due[:limit]
	}
	return due, nil
}

func optTime(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func (r *fakeOrphanRepo) SetOrphanState(_ context.Context, id string, updateTime time.Time, st OrphanState) (time.Time, error) {
	if r.beforeSet != nil {
		r.beforeSet(id)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sets++
	if r.setErr != nil {
		return time.Time{}, r.setErr
	}
	d, ok := r.docs[id]
	if !ok || !d.UpdateTime.Equal(updateTime) {
		return time.Time{}, ErrConflict
	}
	d.OrphanCheckAt, d.OrphanedAt = optTime(st.CheckAt), optTime(st.OrphanedAt)
	d.UpdateTime = d.UpdateTime.Add(time.Second)
	return d.UpdateTime, nil
}

func (r *fakeOrphanRepo) DeleteOrphan(_ context.Context, id string, updateTime time.Time) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.deletes++
	d, ok := r.docs[id]
	switch {
	case !ok:
		return nil
	case !d.UpdateTime.Equal(updateTime):
		return ErrConflict
	}
	delete(r.docs, id)
	return nil
}

// attach models Claim.Attach committing: postId set, orphanCheckAt removed, a new UpdateTime.
func (r *fakeOrphanRepo) attach(id, postID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	d := r.docs[id]
	d.PostID, d.OrphanCheckAt = postID, nil
	d.UpdateTime = d.UpdateTime.Add(time.Second)
}

// fakeDraftHolds answers HeldByDrafts from a set of held ids per uid.
type fakeDraftHolds struct {
	mu    sync.Mutex
	held  map[string]map[string]bool
	calls []string // the uid of every call
	err   error
}

func (f *fakeDraftHolds) HeldByDrafts(_ context.Context, uid string, ids []string) (map[string]bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, uid)
	if f.err != nil {
		return nil, f.err
	}
	out := map[string]bool{}
	for _, id := range ids {
		if f.held[uid][id] {
			out[id] = true
		}
	}
	return out, nil
}
