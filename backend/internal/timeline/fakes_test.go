package timeline

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// fakeClock is a settable clock.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newClock() *fakeClock { return &fakeClock{t: time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// fakePosts is an in-memory posts.Reader with the real contract: createdAt DESC order, window semantics, Limit
// clamped to 1..50, reads = max(len(result), 1) charged to the request's budget counter, 60 s author-recent.
type fakePosts struct {
	posts.Reader // unused methods panic via nil embed
	clock        *fakeClock
	mu           sync.Mutex
	byAuthor     map[string][]*posts.Post // any order
	recent       map[string]posts.Recent
	queries      []string // "ByAuthors(n)" / "ByAuthor"
	maxInFlight  int
	inFlight     int
	seq          int64
	hook         func() // called inside every query (concurrency probes)
}

func newFakePosts(c *fakeClock) *fakePosts {
	return &fakePosts{clock: c, byAuthor: map[string][]*posts.Post{}, recent: map[string]posts.Recent{}}
}

func pid(n int64) string { return fmt.Sprintf("%019d", n) }

// add stores a root post by author at ms offset ms from the clock's epoch; the id embeds ms so ids sort by time.
func (f *fakePosts) add(author string, ms int64) *posts.Post {
	f.seq++
	return f.addAt(author, ms, pid(ms*1000+f.seq%1000))
}

func (f *fakePosts) addAt(author string, ms int64, id string) *posts.Post {
	p := &posts.Post{
		ID: id, AuthorID: author, Author: posts.AuthorSnapshot{UserID: author, Handle: "h_" + author},
		Kind: posts.KindPost, Text: "t" + id, ConversationID: id, Visibility: posts.VisibilityPublic,
		CreatedAt: time.UnixMilli(ms).UTC(),
	}
	f.byAuthor[author] = append(f.byAuthor[author], p)
	return p
}

func inWin(p *posts.Post, w posts.Window) bool {
	pos := PositionOf(p)
	if w.Before != nil && Compare(pos, *w.Before) <= 0 {
		return false
	}
	if w.After != nil && Compare(pos, *w.After) >= 0 {
		return false
	}
	return true
}

func (f *fakePosts) query(ctx context.Context, label string, authors []string, w posts.Window, limit int, rootOnly bool) []*posts.Post {
	f.mu.Lock()
	f.inFlight++
	f.maxInFlight = max(f.maxInFlight, f.inFlight)
	f.queries = append(f.queries, label)
	hook := f.hook
	f.mu.Unlock()
	if hook != nil {
		hook()
	}
	f.mu.Lock()
	defer func() { f.inFlight--; f.mu.Unlock() }()
	limit = min(max(limit, 1), posts.MaxLimit)
	var out []*posts.Post
	for _, a := range authors {
		for _, p := range f.byAuthor[a] {
			if inWin(p, w) && (!rootOnly || !p.IsReply) {
				out = append(out, p)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return Compare(PositionOf(out[i]), PositionOf(out[j])) < 0 })
	if len(out) > limit {
		out = out[:limit]
	}
	budget.FromContext(ctx).AddReads(int64(max(len(out), 1)))
	return out
}

func (f *fakePosts) ByAuthors(ctx context.Context, authors []string, w posts.Window, limit int) ([]*posts.Post, error) {
	if len(authors) > posts.MaxByAuthors {
		return nil, fmt.Errorf("too many authors %d", len(authors))
	}
	return f.query(ctx, fmt.Sprintf("ByAuthors(%d)", len(authors)), authors, w, limit, true), nil
}

func (f *fakePosts) ByAuthor(ctx context.Context, author string, includeReplies bool, w posts.Window, limit int) ([]*posts.Post, error) {
	return f.query(ctx, "ByAuthor", []string{author}, w, limit, !includeReplies), nil
}

func (f *fakePosts) AuthorRecent(a string) (posts.Recent, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	r, ok := f.recent[a]
	if !ok || f.clock.Now().Sub(r.LoadedAt) >= 60*time.Second {
		return posts.Recent{}, false
	}
	return r, true
}

func (f *fakePosts) StoreAuthorRecent(a string, newest []*posts.Post, truncated bool, loadedAt time.Time) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(newest) > posts.MaxRecent {
		newest, truncated = newest[:posts.MaxRecent], true
	}
	f.recent[a] = posts.Recent{Posts: append([]*posts.Post(nil), newest...), Truncated: truncated, LoadedAt: loadedAt}
}

func (f *fakePosts) queryCount(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, q := range f.queries {
		if strings.HasPrefix(q, prefix) {
			n++
		}
	}
	return n
}

// fakeGraph serves a per-uid Snapshot and charges 1 read per call (a cold graph read).
type fakeGraph struct {
	snaps map[string]graph.Snapshot
	calls []string
}

func (g *fakeGraph) Snapshot(ctx context.Context, uid string) (graph.Snapshot, error) {
	g.calls = append(g.calls, uid)
	budget.FromContext(ctx).AddReads(1)
	return g.snaps[uid], nil
}

func following(uids ...string) map[string]bool {
	m := map[string]bool{}
	for _, u := range uids {
		m[u] = true
	}
	return m
}

// fakeDirectory returns the ACTIVE profiles it was given and charges 1 read per call (a cold users read).
type fakeDirectory struct {
	identity.Directory
	profiles map[string]identity.Profile
}

func (d *fakeDirectory) GetProfiles(ctx context.Context, uids []string) (map[string]identity.Profile, error) {
	budget.FromContext(ctx).AddReads(1)
	out := map[string]identity.Profile{}
	for _, u := range uids {
		if p, ok := d.profiles[u]; ok {
			out[u] = p
		}
	}
	return out, nil
}
