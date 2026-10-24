package posts

import (
	"context"
	"sort"
	"sync"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeScheduledStore is an in-memory ScheduledLister, ScheduledPurger and ScheduledExportSource. It charges reads and
// deletes the way FirestoreRepo does (a query: one per document, minimum 1; a purge: one delete per document).
type fakeScheduledStore struct {
	mu    sync.Mutex
	docs  map[string][]*ScheduledPost // uid -> documents
	calls int
	err   error
}

func newFakeScheduledStore(ps ...*ScheduledPost) *fakeScheduledStore {
	f := &fakeScheduledStore{docs: map[string][]*ScheduledPost{}}
	for _, p := range ps {
		f.docs[p.UID] = append(f.docs[p.UID], p)
	}
	return f
}

// sorted returns uid's documents ordered like the queries: publishAt, then id.
func (f *fakeScheduledStore) sorted(uid string, keep func(*ScheduledPost) bool, after *Position) []*ScheduledPost {
	var out []*ScheduledPost
	for _, p := range f.docs[uid] {
		if keep(p) {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].PublishAt.Equal(out[j].PublishAt) {
			return out[i].PublishAt.Before(out[j].PublishAt)
		}
		return out[i].ID < out[j].ID
	})
	if after != nil {
		i := sort.Search(len(out), func(i int) bool {
			if !out[i].PublishAt.Equal(after.CreatedAt) {
				return out[i].PublishAt.After(after.CreatedAt)
			}
			return out[i].ID > after.ID
		})
		out = out[i:]
	}
	return out
}

func (f *fakeScheduledStore) page(ctx context.Context, uid string, keep func(*ScheduledPost) bool, after *Position, limit int) ([]*ScheduledPost, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	out := f.sorted(uid, keep, after)
	if len(out) > limit {
		out = out[:limit]
	}
	budget.FromContext(ctx).AddQueryReads(len(out))
	return out, nil
}

func (f *fakeScheduledStore) ListScheduled(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error) {
	return f.page(ctx, uid, func(p *ScheduledPost) bool {
		return p.Status == ScheduledPending || p.Status == ScheduledFailed
	}, after, limit)
}

func (f *fakeScheduledStore) ExportScheduledPage(ctx context.Context, uid string, after *Position, limit int) ([]*ScheduledPost, error) {
	return f.page(ctx, uid, func(*ScheduledPost) bool { return true }, after, limit)
}

func (f *fakeScheduledStore) PurgeScheduledPage(ctx context.Context, uid string) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return 0, f.err
	}
	all := f.sorted(uid, func(*ScheduledPost) bool { return true }, nil)
	n := min(len(all), opsPage)
	budget.FromContext(ctx).AddQueryReads(n)
	budget.FromContext(ctx).AddDeletes(int64(n))
	f.docs[uid] = all[n:]
	return n, nil
}
