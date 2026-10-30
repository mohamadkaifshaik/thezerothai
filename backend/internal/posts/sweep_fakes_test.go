package posts

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
)

// The fakes of the publish sweep's unit tests. Everything is goroutine-safe: the sweep runs author workers in parallel.

// sweepCall is one recorded repository call, in the order the fake saw it.
type sweepCall struct {
	kind string // "due", "publish", "transition", "bump"
	uid  string
	id   string
	t    ScheduledTransition
	ref  ScheduledRef
}

// fakeSweepRepo is an in-memory SweepRepo. Docs carry an UpdateTime that moves on every write, so the LastUpdateTime
// precondition of TransitionScheduled and BumpScheduledAttempts behaves like Firestore's.
type fakeSweepRepo struct {
	mu    sync.Mutex
	docs  map[string]*ScheduledPost // uid + "/" + id
	tick  int64
	calls []sweepCall

	// Paging of the due query: a page is `limit` items; cursors map to the offset they resume at.
	cursorPos map[*ScheduledDueCursor]int
	dueErr    error
	dueErrAt  int // 1-based DueScheduled call that fails (0: none)
	dueCalls  int
	// bad / undecodable are reported on the first page.
	bad, undecodable int

	// publish replaces the default publish (nil: the default, which publishes). It runs WITHOUT f.mu held.
	publish func(ctx context.Context, p PublishParams) (PublishResult, error)
	// transitionErr / bumpErr fail the bookkeeping writes.
	transitionErr, bumpErr error

	// inflight tracking of PublishScheduled, per uid and overall.
	inflight, maxInflight     int
	inflightBy, maxInflightBy map[string]int
	published                 int64
	publishedPosts            []*Post
	params                    []PublishParams
	// afterDue runs after a due page was built, without the lock held: a test changes a document in the window between the
	// query and the item.
	afterDue func()
	// transitionPanic, when set, makes TransitionScheduled panic with it (a second panic while an item's panic is handled).
	transitionPanic            any
	publishReads, publishWrite int64 // charged by the default publish
	// authorCreatedAt is what the default publish reports as the author's account creation time.
	authorCreatedAt time.Time
}

func newFakeSweepRepo() *fakeSweepRepo {
	return &fakeSweepRepo{
		docs: map[string]*ScheduledPost{}, cursorPos: map[*ScheduledDueCursor]int{},
		inflightBy: map[string]int{}, maxInflightBy: map[string]int{}, publishReads: 3, publishWrite: 4,
	}
}

var _ SweepRepo = (*fakeSweepRepo)(nil)

func (f *fakeSweepRepo) touch(p *ScheduledPost) {
	f.tick++
	p.UpdateTime = time.Unix(1_700_000_000+f.tick, 0).UTC()
}

// put stores a copy of p (with a fresh UpdateTime) and returns a copy of what was stored.
func (f *fakeSweepRepo) put(p *ScheduledPost) *ScheduledPost {
	f.mu.Lock()
	defer f.mu.Unlock()
	cp := copyScheduled(p)
	f.touch(cp)
	f.docs[cp.UID+"/"+cp.ID] = cp
	return copyScheduled(cp)
}

// doc returns a copy of the stored document (nil when absent).
func (f *fakeSweepRepo) doc(uid, id string) *ScheduledPost {
	f.mu.Lock()
	defer f.mu.Unlock()
	if d := f.docs[uid+"/"+id]; d != nil {
		return copyScheduled(d)
	}
	return nil
}

func (f *fakeSweepRepo) record(c sweepCall) { f.calls = append(f.calls, c) }

// callsOf returns the recorded calls of one kind, in order.
func (f *fakeSweepRepo) callsOf(kind string) []sweepCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []sweepCall
	for _, c := range f.calls {
		if c.kind == kind {
			out = append(out, c)
		}
	}
	return out
}

func (f *fakeSweepRepo) DueScheduled(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error) {
	page, err := f.duePage(ctx, now, limit, after)
	f.mu.Lock()
	hook := f.afterDue
	f.mu.Unlock()
	if err == nil && hook != nil {
		hook()
	}
	return page, err
}

func (f *fakeSweepRepo) duePage(ctx context.Context, now time.Time, limit int, after *ScheduledDueCursor) (ScheduledDuePage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.dueCalls++
	f.record(sweepCall{kind: "due"})
	if f.dueErr != nil && f.dueCalls == f.dueErrAt {
		return ScheduledDuePage{}, f.dueErr
	}
	var due []*ScheduledPost
	for _, d := range f.docs {
		if d.Status == ScheduledPending && !d.PublishAt.After(now) {
			due = append(due, d)
		}
	}
	sort.Slice(due, func(i, j int) bool { // publishAt, then the full path, like the collection-group query
		if !due[i].PublishAt.Equal(due[j].PublishAt) {
			return due[i].PublishAt.Before(due[j].PublishAt)
		}
		return due[i].UID+"/"+due[i].ID < due[j].UID+"/"+due[j].ID
	})
	start := 0
	if after != nil {
		start = f.cursorPos[after]
	}
	start = min(start, len(due))
	end := min(start+limit, len(due))
	page := ScheduledDuePage{}
	for _, d := range due[start:end] {
		page.Items = append(page.Items, copyScheduled(d))
	}
	read := len(page.Items)
	if after == nil {
		page.SkippedBadPath, page.Undecodable = f.bad, f.undecodable
		read += f.bad + f.undecodable
	}
	budget.FromContext(ctx).AddQueryReads(read)
	if end-start >= limit {
		next := &ScheduledDueCursor{}
		f.cursorPos[next] = end
		page.Next = next
	}
	return page, nil
}

func (f *fakeSweepRepo) TransitionScheduled(ctx context.Context, ref ScheduledRef, t ScheduledTransition, now time.Time, ttl time.Duration) (ScheduledRef, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record(sweepCall{kind: "transition", uid: ref.UID, id: ref.ID, t: t, ref: ref})
	if f.transitionPanic != nil {
		panic(f.transitionPanic)
	}
	if f.transitionErr != nil {
		return ref, false, f.transitionErr
	}
	d := f.docs[ref.UID+"/"+ref.ID]
	if d == nil || !d.UpdateTime.Equal(ref.UpdateTime) {
		return ref, false, nil // the precondition failed: changed since the query read it, or gone
	}
	if _, err := t.updates(now, ttl); err != nil {
		return ref, false, err
	}
	t.apply(d, now, ttl)
	f.touch(d)
	budget.FromContext(ctx).AddWrites(1)
	return d.Ref(), true, nil
}

func (f *fakeSweepRepo) BumpScheduledAttempts(ctx context.Context, ref ScheduledRef, now time.Time) (ScheduledRef, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.record(sweepCall{kind: "bump", uid: ref.UID, id: ref.ID, ref: ref})
	if f.bumpErr != nil {
		return ref, false, f.bumpErr
	}
	d := f.docs[ref.UID+"/"+ref.ID]
	if d == nil || !d.UpdateTime.Equal(ref.UpdateTime) {
		return ref, false, nil
	}
	d.Attempts++
	d.UpdatedAt = now
	f.touch(d)
	budget.FromContext(ctx).AddWrites(1)
	return d.Ref(), true, nil
}

func (f *fakeSweepRepo) PublishScheduled(ctx context.Context, p PublishParams) (PublishResult, error) {
	f.mu.Lock()
	f.record(sweepCall{kind: "publish", uid: p.UID, id: p.ID})
	f.params = append(f.params, p)
	f.inflight++
	f.inflightBy[p.UID]++
	f.maxInflight = max(f.maxInflight, f.inflight)
	f.maxInflightBy[p.UID] = max(f.maxInflightBy[p.UID], f.inflightBy[p.UID])
	hook := f.publish
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.inflight--
		f.inflightBy[p.UID]--
		f.mu.Unlock()
	}()

	if hook != nil {
		return hook(ctx, p)
	}
	return f.publishDefault(ctx, p)
}

// publishDefault is a successful publish: it requires the doc to be PENDING (else a no-op), resolves the mentions like
// the real transaction does, marks the item PUBLISHED and returns the post.
func (f *fakeSweepRepo) publishDefault(ctx context.Context, p PublishParams) (PublishResult, error) {
	var mentions []Mention
	if p.ResolveMentions != nil {
		m, err := p.ResolveMentions(ctx)
		if err != nil {
			return PublishResult{}, err
		}
		mentions = m
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.docs[p.UID+"/"+p.ID]
	if d == nil || d.Status != ScheduledPending {
		budget.FromContext(ctx).AddReads(1)
		return PublishResult{Outcome: PublishNoop, Attempts: 1}, nil
	}
	f.published++
	id := fmt.Sprintf("%019d", 1_000_000_000_000_000_000+f.published)
	post := p.Draft
	post.ID, post.ConversationID, post.AuthorID, post.Mentions = id, id, p.UID, mentions
	post.CreatedAt = p.Now
	post.Author = AuthorSnapshot{UserID: p.UID, Handle: "h-" + p.UID}
	(ScheduledTransition{To: ScheduledPublished, PostID: id}).apply(d, p.Now, p.TerminalTTL)
	f.touch(d)
	f.publishedPosts = append(f.publishedPosts, &post)
	c := budget.FromContext(ctx)
	c.AddReads(f.publishReads)
	c.AddWrites(f.publishWrite)
	return PublishResult{Outcome: PublishPublished, Post: &post, Attempts: 1, AuthorCreatedAt: f.authorCreatedAt}, nil
}

// sweepFlags is a GloballyOffChecker: the named flags are off for everyone.
type sweepFlags map[string]bool

func (f sweepFlags) GloballyOff(name string) bool { return f[name] }

// sweepDirectory is the Directory subset the sweep touches, goroutine-safe: Forget after a publish and ResolveHandles
// for mentions.
type sweepDirectory struct {
	mu        sync.Mutex
	handles   map[string]string
	forgotten []string
	resolved  [][]string
}

var _ identity.Directory = (*sweepDirectory)(nil)

func (d *sweepDirectory) GetProfiles(context.Context, []string) (map[string]identity.Profile, error) {
	return nil, fmt.Errorf("sweepDirectory: the sweep must not read profiles through the cached directory")
}

func (d *sweepDirectory) LookupProfiles(context.Context, []string) (map[string]identity.Profile, []string, error) {
	return nil, nil, fmt.Errorf("sweepDirectory: the sweep must not read profiles through the cached directory")
}

func (d *sweepDirectory) ResolveHandles(_ context.Context, lowers []string) (map[string]string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.resolved = append(d.resolved, append([]string(nil), lowers...))
	out := map[string]string{}
	for _, h := range lowers {
		if u, ok := d.handles[h]; ok {
			out[h] = u
		}
	}
	return out, nil
}

func (d *sweepDirectory) Forget(uids ...string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.forgotten = append(d.forgotten, uids...)
}

func (d *sweepDirectory) ForgetUnread(...string) {}

// sweepEvents is a goroutine-safe PostEvents.
type sweepEvents struct {
	mu      sync.Mutex
	created []*Post
	panicOn func(*Post) bool
	// onCreated runs first, without the lock held.
	onCreated func(*Post)
	// ctxErrs is ctx.Err() of each Created call: a notification publish must not be cancelled with the run.
	ctxErrs []error
}

func (e *sweepEvents) Created(ctx context.Context, p *Post) {
	if e.onCreated != nil {
		e.onCreated(p)
	}
	e.mu.Lock()
	panics := e.panicOn != nil && e.panicOn(p)
	e.created = append(e.created, p)
	e.ctxErrs = append(e.ctxErrs, ctx.Err())
	e.mu.Unlock()
	if panics {
		panic("events boom")
	}
}

func (e *sweepEvents) Deleted(context.Context, string, string) {}

// lockedBuffer is a bytes.Buffer safe for the concurrent writes of the workers' log lines.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// lines returns the log lines containing substr.
func (b *lockedBuffer) lines(substr string) []string {
	var out []string
	for _, l := range strings.Split(b.String(), "\n") {
		if strings.Contains(l, substr) {
			out = append(out, l)
		}
	}
	return out
}

// sweepEnv is a service wired for sweep unit tests: fake repository, directory, events and flags, a JSON log capture
// and a fixed clock.
type sweepEnv struct {
	svc    *service
	repo   *fakeSweepRepo
	dir    *sweepDirectory
	events *sweepEvents
	cache  *Cache
	logs   *lockedBuffer
	now    time.Time
}

// defaultSweepLimits are the documented defaults of the SCHEDULED_* keys.
func defaultSweepLimits() SweepLimits {
	return SweepLimits{
		PerAuthorPerRun: 3, AuthorReadsWarn: 40, Limit: 50, MaxPages: 2, Concurrency: 4,
		MaxLateness: 6 * time.Hour, MaxAttempts: 3, TerminalTTL: 168 * time.Hour,
	}
}

func newSweepEnv(t *testing.T, mut ...func(*SweepDeps, *sweepEnv)) *sweepEnv {
	t.Helper()
	e := &sweepEnv{
		repo: newFakeSweepRepo(), dir: &sweepDirectory{handles: map[string]string{"bob": "uid-bob"}}, events: &sweepEvents{},
		cache: NewCache(time.Minute, 0, 0), logs: &lockedBuffer{}, now: schedNow,
	}
	deps := SweepDeps{
		Repo: e.repo, Limits: defaultSweepLimits(), Flags: sweepFlags{}, Log: slog.New(slog.NewJSONHandler(e.logs, &slog.HandlerOptions{Level: slog.LevelDebug})),
	}
	for _, m := range mut {
		m(&deps, e)
	}
	e.svc = New(Deps{
		Repo: newFakeRepo(), Cache: e.cache, Events: e.events, Directory: e.dir,
		PostsPerDay: 100, NewAccountPostsPerDay: 20, NewAccountWindow: 24 * time.Hour,
		Sweep: deps, Now: func() time.Time { return e.now },
	}).(*service)
	return e
}

// dueItem is a PENDING item of uid, due 10 minutes before the clock (+ n seconds, so n orders the items), with a
// valid draft. mut adjusts it.
func (e *sweepEnv) dueItem(uid string, n int, mut ...func(*ScheduledPost)) *ScheduledPost {
	id, err := ScheduledID(uid, schedKeyFor(n))
	if err != nil {
		panic(err)
	}
	p := &ScheduledPost{
		ID: id, UID: uid, SchemaVersion: ScheduledSchemaVersion, PublishAt: e.now.Add(-10 * time.Minute).Add(time.Duration(n) * time.Second),
		Status: ScheduledPending, RequestHash: "h", CreatedAt: e.now.Add(-time.Hour), UpdatedAt: e.now.Add(-time.Hour),
		Draft: &ScheduledDraft{Text: fmt.Sprintf("hello %d #go", n)},
	}
	for _, m := range mut {
		m(p)
	}
	return e.repo.put(p)
}

// sweep runs one sweep with a budget counter and returns the result and the counter.
func (e *sweepEnv) sweep(ctx context.Context) (SweepResult, *budget.Counter, error) {
	ctx, c := budget.WithCounter(ctx)
	res, err := e.svc.Sweep(ctx)
	return res, c, err
}

// SearchHandles satisfies identity.Directory; this fake never serves handle-prefix search.
func (d *sweepDirectory) SearchHandles(context.Context, string, int) ([]identity.Profile, error) {
	return nil, nil
}
