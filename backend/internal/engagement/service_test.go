package engagement

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

const (
	pidA   = "0000000000000000001"
	pidB   = "0000000000000000002"
	pidRep = "0000000000000000003"
	keyOK  = "engagement-key-0001"
)

type fakeRepo struct {
	likeErr      error
	replayed     bool
	unlikeResult bool
	repostRes    RepostResult
	repostErr    error
	undoRes      UndoResult
	loaded       UserLikes
	loadErr      error
	loads        int
	likeParams   []LikeParams
	repostParams []RepostParams
	trims        [][]string
	trimCtxErrs  []error
	trimRepost   [][]string
	undoIDs      []string
	unlikeIDs    []string
}

func (f *fakeRepo) LoadUserLikes(context.Context, string) (UserLikes, error) {
	f.loads++
	return f.loaded, f.loadErr
}

func (f *fakeRepo) Like(_ context.Context, p LikeParams) (bool, error) {
	f.likeParams = append(f.likeParams, p)
	return f.replayed, f.likeErr
}

func (f *fakeRepo) Unlike(_ context.Context, _, postID string) (bool, error) {
	f.unlikeIDs = append(f.unlikeIDs, postID)
	return f.unlikeResult, nil
}

func (f *fakeRepo) Repost(_ context.Context, p RepostParams) (RepostResult, error) {
	f.repostParams = append(f.repostParams, p)
	return f.repostRes, f.repostErr
}

func (f *fakeRepo) UndoRepost(_ context.Context, _, postID string) (UndoResult, error) {
	f.undoIDs = append(f.undoIDs, postID)
	return f.undoRes, nil
}

func (f *fakeRepo) TrimLikes(ctx context.Context, _ string, recent, reposts []string) error {
	f.trimCtxErrs = append(f.trimCtxErrs, ctx.Err())
	f.trims = append(f.trims, recent)
	f.trimRepost = append(f.trimRepost, reposts)
	return nil
}

// fakePosts is touched by concurrent like calls, so every recorder takes mu. Tests read the recorded fields only
// after the calls have returned (wg.Wait), which orders them after the writes.
type fakePosts struct {
	mu        sync.Mutex
	docs      map[string]*posts.Post
	hidden    map[string]bool
	counts    []string
	created   []*posts.Post
	removed   []string
	viewCalls int
}

func (f *fakePosts) Viewable(_ context.Context, _, id string) (*posts.Post, error) {
	f.mu.Lock()
	f.viewCalls++
	f.mu.Unlock()
	p, ok := f.docs[id]
	if !ok || f.hidden[id] {
		return nil, posts.ErrNotFound
	}
	return p, nil
}

func (f *fakePosts) CountsChanged(id string, l, r int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.counts = append(f.counts, fmt.Sprintf("%s:%d:%d", id, l, r))
}
func (f *fakePosts) RepostCreated(p *posts.Post) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.created = append(f.created, p)
}

func (f *fakePosts) RepostRemoved(a, id string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.removed = append(f.removed, a+"/"+id)
}

func (f *fakePosts) Get(_ context.Context, id string) (*posts.Post, error) {
	if p, ok := f.docs[id]; ok {
		return p, nil
	}
	return nil, posts.ErrNotFound
}

// The rest of posts.Reader is never used by the service.
func (f *fakePosts) GetMany(context.Context, []string) (map[string]*posts.Post, error) {
	return nil, nil
}
func (f *fakePosts) ByAuthors(context.Context, []string, posts.Window, int) ([]*posts.Post, error) {
	return nil, nil
}
func (f *fakePosts) ByAuthor(context.Context, string, bool, posts.Window, int) ([]*posts.Post, error) {
	return nil, nil
}
func (f *fakePosts) AuthorRecent(string) (posts.Recent, bool)                 { return posts.Recent{}, false }
func (f *fakePosts) StoreAuthorRecent(string, []*posts.Post, bool, time.Time) {}

type fakeDir struct {
	created time.Time
	missing bool
}

func (d fakeDir) GetProfiles(_ context.Context, uids []string) (map[string]identity.Profile, error) {
	if d.missing {
		return map[string]identity.Profile{}, nil
	}
	out := map[string]identity.Profile{}
	for _, u := range uids {
		out[u] = identity.Profile{UserID: u, Handle: "h_" + u, DisplayName: "D", CreatedAt: d.created}
	}
	return out, nil
}
func (fakeDir) LookupProfiles(context.Context, []string) (map[string]identity.Profile, []string, error) {
	return nil, nil, nil
}
func (fakeDir) ResolveHandles(context.Context, []string) (map[string]string, error) { return nil, nil }
func (fakeDir) Forget(...string)                                                    {}

type fakeEvents struct {
	mu             sync.Mutex
	likes, reposts int
	ctxErrs        []error // ctx.Err() seen by each Liked/Reposted: the effects must not run on a cancelled ctx
}

func (e *fakeEvents) Liked(ctx context.Context, _ string, _ *posts.Post, _ time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.likes++
	e.ctxErrs = append(e.ctxErrs, ctx.Err())
}

func (e *fakeEvents) Reposted(ctx context.Context, _ string, _ *posts.Post, _ string, _ time.Time) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.reposts++
	e.ctxErrs = append(e.ctxErrs, ctx.Err())
}

type env struct {
	m      *Module
	repo   *fakeRepo
	posts  *fakePosts
	events *fakeEvents
	ctx    context.Context
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{repo: &fakeRepo{}, events: &fakeEvents{}}
	e.posts = &fakePosts{docs: map[string]*posts.Post{
		pidA:   {ID: pidA, AuthorID: "author", Author: posts.AuthorSnapshot{UserID: "author"}, Kind: posts.KindPost, LikeCount: 4, RepostCount: 2},
		pidB:   {ID: pidB, AuthorID: "author", Kind: posts.KindPost},
		pidRep: {ID: pidRep, AuthorID: "other", Kind: posts.KindRepost, RepostOfID: pidA, Embedded: &posts.Embedded{PostID: pidA}},
	}, hidden: map[string]bool{}}
	m, err := New(Deps{
		Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
		Events: e.events, LikesPerDay: 500, NewAccountLikesPerDay: 100, PostsPerDay: 100, NewAccountPostsPerDay: 20,
		NewAccountWindow: 24 * time.Hour, CacheTTL: time.Minute, AllowAnonymous: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.m = m
	e.ctx = authn.WithClaims(context.Background(), authn.Claims{UID: "viewer", SignInProvider: authn.SignInProviderGoogle})
	return e
}

func requireCode(t *testing.T, err error, code connect.Code) *apierr.Error {
	t.Helper()
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code != code {
		t.Fatalf("err = %v, want %v", err, code)
	}
	return ae
}

func TestLike(t *testing.T) {
	t.Run("first like", func(t *testing.T) {
		e := newEnv(t)
		r, err := e.m.Like(e.ctx, "viewer", keyOK, pidA)
		if err != nil {
			t.Fatal(err)
		}
		if r.PostID != pidA || r.LikeCount != 5 || !r.LikedByViewer {
			t.Fatalf("result = %+v", r)
		}
		if e.events.likes != 1 || len(e.posts.counts) != 1 || e.posts.counts[0] != pidA+":1:0" {
			t.Fatalf("events=%d counts=%v", e.events.likes, e.posts.counts)
		}
		if got := e.repo.likeParams[0]; got.QuotaLimit != 500 || got.PostID != pidA || got.UID != "viewer" {
			t.Fatalf("params = %+v", got)
		}
	})
	t.Run("replay writes nothing and notifies nobody", func(t *testing.T) {
		e := newEnv(t)
		e.repo.replayed = true
		r, err := e.m.Like(e.ctx, "viewer", keyOK, pidA)
		if err != nil || r.LikeCount != 4 || !r.LikedByViewer {
			t.Fatalf("r=%+v err=%v", r, err)
		}
		if e.events.likes != 0 || len(e.posts.counts) != 0 {
			t.Fatalf("events=%d counts=%v", e.events.likes, e.posts.counts)
		}
	})
	t.Run("a REPOST id acts on the original", func(t *testing.T) {
		e := newEnv(t)
		r, err := e.m.Like(e.ctx, "viewer", keyOK, pidRep)
		if err != nil || r.PostID != pidA || e.repo.likeParams[0].PostID != pidA {
			t.Fatalf("r=%+v err=%v params=%+v", r, err, e.repo.likeParams)
		}
		if e.posts.viewCalls != 2 {
			t.Errorf("viewable calls = %d, want 2 (repost, original)", e.posts.viewCalls)
		}
	})
	t.Run("new accounts get the smaller quota", func(t *testing.T) {
		e := newEnv(t)
		m, _ := New(Deps{Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-time.Hour)},
			LikesPerDay: 500, NewAccountLikesPerDay: 100, NewAccountWindow: 24 * time.Hour, AllowAnonymous: true})
		if _, err := m.Like(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		if got := e.repo.likeParams[0].QuotaLimit; got != 100 {
			t.Fatalf("limit = %d, want 100", got)
		}
	})
	tests := []struct {
		name    string
		key     string
		post    string
		prep    func(*env)
		code    connect.Code
		message string
	}{
		{"short key", "short", pidA, nil, connect.CodeInvalidArgument, ""},
		{"bad post id", keyOK, "12", nil, connect.CodeInvalidArgument, ""},
		{"unknown post", keyOK, "0000000000000000099", nil, connect.CodeNotFound, "post not found"},
		{"hidden post is the same answer", keyOK, pidB, func(e *env) { e.posts.hidden[pidB] = true }, connect.CodeNotFound, "post not found"},
		{"post deleted before commit", keyOK, pidA, func(e *env) { e.repo.likeErr = ErrPostGone }, connect.CodeNotFound, "post not found"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t)
			if tt.prep != nil {
				tt.prep(e)
			}
			_, err := e.m.Like(e.ctx, "viewer", tt.key, tt.post)
			ae := requireCode(t, err, tt.code)
			if tt.message != "" && ae.Message != tt.message {
				t.Fatalf("message = %q, want %q", ae.Message, tt.message)
			}
			if e.events.likes != 0 {
				t.Fatal("a rejected like notified")
			}
		})
	}
	t.Run("quota exceeded passes through", func(t *testing.T) {
		e := newEnv(t)
		e.repo.likeErr = quota.ExceededError(quota.Likes, time.Now())
		_, err := e.m.Like(e.ctx, "viewer", keyOK, pidA)
		ae := requireCode(t, err, connect.CodeResourceExhausted)
		if ae.Metadata["quota"] != "likes" {
			t.Fatalf("metadata = %v", ae.Metadata)
		}
	})
	t.Run("a cached like survives the daily limit as a replay", func(t *testing.T) {
		e := newEnv(t)
		e.repo.loaded = UserLikes{Recent: []string{pidA}}
		_ = e.m.Viewer(e.ctx, "viewer") // fills the cache
		e.repo.likeErr = quota.ExceededError(quota.Likes, time.Now())
		r, err := e.m.Like(e.ctx, "viewer", keyOK, pidA)
		if err != nil || !r.LikedByViewer {
			t.Fatalf("r=%+v err=%v", r, err)
		}
	})
}

func TestUnlike(t *testing.T) {
	tests := []struct {
		name      string
		removed   bool
		post      string
		wantLikes int64
		wantCount string
	}{
		{"removed", true, pidA, 3, pidA + ":-1:0"},
		{"noop", false, pidA, 4, ""},
		{"post gone: counts are zero, delete still runs", true, "0000000000000000099", 0, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t)
			e.repo.unlikeResult = tt.removed
			r, err := e.m.Unlike(e.ctx, "viewer", keyOK, tt.post)
			if err != nil {
				t.Fatal(err)
			}
			if r.LikeCount != tt.wantLikes || r.LikedByViewer {
				t.Fatalf("r = %+v", r)
			}
			if tt.wantCount == "" && len(e.posts.counts) != 0 {
				t.Fatalf("counts = %v", e.posts.counts)
			}
			if tt.wantCount != "" && (len(e.posts.counts) != 1 || e.posts.counts[0] != tt.wantCount) {
				t.Fatalf("counts = %v, want %s", e.posts.counts, tt.wantCount)
			}
		})
	}
	t.Run("an unlike needs no visibility", func(t *testing.T) {
		e := newEnv(t)
		e.posts.hidden[pidA] = true
		e.repo.unlikeResult = true
		if _, err := e.m.Unlike(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		if e.posts.viewCalls != 0 {
			t.Fatalf("viewable called %d times", e.posts.viewCalls)
		}
	})
}

func TestRepostAndUndo(t *testing.T) {
	t.Run("first repost", func(t *testing.T) {
		e := newEnv(t)
		e.repo.repostRes = RepostResult{Post: &posts.Post{ID: pidRep, AuthorID: "viewer"}}
		r, err := e.m.Repost(e.ctx, "viewer", keyOK, pidA)
		if err != nil || r.RepostPostID != pidRep || r.RepostCount != 3 || !r.RepostedByViewer {
			t.Fatalf("r=%+v err=%v", r, err)
		}
		if len(e.posts.created) != 1 || e.events.reposts != 1 || e.posts.counts[0] != pidA+":0:1" {
			t.Fatalf("created=%d events=%d counts=%v", len(e.posts.created), e.events.reposts, e.posts.counts)
		}
		if got := e.repo.repostParams[0]; got.QuotaLimit != 100 || got.Original.ID != pidA || got.Author.Handle != "h_viewer" {
			t.Fatalf("params = %+v", got)
		}
	})
	t.Run("replay returns the existing repost and changes nothing", func(t *testing.T) {
		e := newEnv(t)
		e.repo.repostRes = RepostResult{ReplayPostID: pidRep}
		r, err := e.m.Repost(e.ctx, "viewer", keyOK, pidA)
		if err != nil || r.RepostPostID != pidRep || r.RepostCount != 2 {
			t.Fatalf("r=%+v err=%v", r, err)
		}
		if len(e.posts.created) != 0 || e.events.reposts != 0 || len(e.posts.counts) != 0 {
			t.Fatal("a replay changed state")
		}
	})
	t.Run("original gone", func(t *testing.T) {
		e := newEnv(t)
		e.repo.repostErr = ErrPostGone
		_, err := e.m.Repost(e.ctx, "viewer", keyOK, pidA)
		_ = requireCode(t, err, connect.CodeNotFound)
	})
	t.Run("posts quota", func(t *testing.T) {
		e := newEnv(t)
		e.repo.repostErr = quota.ExceededError(quota.Posts, time.Now())
		_, err := e.m.Repost(e.ctx, "viewer", keyOK, pidA)
		ae := requireCode(t, err, connect.CodeResourceExhausted)
		if ae.Reason != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || ae.Metadata["quota"] != "posts" {
			t.Fatalf("err = %+v", ae)
		}
	})
	t.Run("undo", func(t *testing.T) {
		e := newEnv(t)
		e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
		r, err := e.m.UndoRepost(e.ctx, "viewer", keyOK, pidA)
		if err != nil || r.RepostedByViewer || r.PostID != pidA {
			t.Fatalf("r=%+v err=%v", r, err)
		}
		if len(e.posts.removed) != 1 || e.posts.removed[0] != "viewer/"+pidRep || e.posts.counts[0] != pidA+":0:-1" {
			t.Fatalf("removed=%v counts=%v", e.posts.removed, e.posts.counts)
		}
	})
	t.Run("undo of nothing is a no-op", func(t *testing.T) {
		e := newEnv(t)
		if _, err := e.m.UndoRepost(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		if len(e.posts.removed) != 0 || len(e.posts.counts) != 0 {
			t.Fatal("a no-op changed state")
		}
	})
}

func TestViewer_CachesOneReadAndDegrades(t *testing.T) {
	e := newEnv(t)
	e.repo.loaded = UserLikes{Recent: []string{pidA}, RecentReposts: []string{pidB}}
	vs := e.m.Viewer(e.ctx, "viewer")
	liked, reposted := vs.Flags(&posts.Post{ID: pidA, Kind: posts.KindPost})
	if !liked || reposted {
		t.Fatalf("flags = %v %v", liked, reposted)
	}
	// A REPOST item's flags describe its original.
	liked, _ = vs.Flags(&posts.Post{ID: pidRep, Kind: posts.KindRepost, Embedded: &posts.Embedded{PostID: pidA}})
	if !liked {
		t.Fatal("a REPOST item must carry the original's flags")
	}
	_ = e.m.Viewer(e.ctx, "viewer")
	if e.repo.loads != 1 {
		t.Fatalf("loads = %d, want 1 (cached)", e.repo.loads)
	}
	e.repo.loadErr = errors.New("firestore down")
	got := e.m.Viewer(e.ctx, "someone-else")
	if l, r := got.Flags(&posts.Post{ID: pidA}); l || r {
		t.Fatal("a failed read must degrade to false flags")
	}
}

func TestLike_TrimsOldestHundredOverCapPlusSlack(t *testing.T) {
	e := newEnv(t)
	recent := make([]string, MaxRecentLikes+trimSlack)
	for i := range recent {
		recent[i] = fmt.Sprintf("%019d", 1000+i)
	}
	e.repo.loaded = UserLikes{Recent: recent}
	_ = e.m.Viewer(e.ctx, "viewer")
	if _, err := e.m.Like(e.ctx, "viewer", keyOK, pidA); err != nil {
		t.Fatal(err)
	}
	if len(e.repo.trims) != 1 || len(e.repo.trims[0]) != trimChunk || e.repo.trims[0][0] != recent[0] {
		t.Fatalf("trims = %v", e.repo.trims)
	}
	// The trimmed ids left the cached list; the new like is in it.
	st, _ := e.m.s.cache.get("viewer")
	if len(st.recent) != MaxRecentLikes+trimSlack+1-trimChunk {
		t.Fatalf("cached len = %d", len(st.recent))
	}
}

func TestCacheListHelpers(t *testing.T) {
	if got := withID([]string{"a"}, "a"); len(got) != 1 {
		t.Fatal("withID duplicated")
	}
	if got := withID([]string{"a"}, "b"); len(got) != 2 || got[1] != "b" {
		t.Fatalf("withID = %v", got)
	}
	if got := withoutID([]string{"a", "b", "a"}, "a"); len(got) != 1 || got[0] != "b" {
		t.Fatalf("withoutID = %v", got)
	}
	if got := withoutIDs([]string{"a", "b", "c"}, []string{"a", "c"}); len(got) != 1 || got[0] != "b" {
		t.Fatalf("withoutIDs = %v", got)
	}
}

// gateRepo blocks Like until released and counts the calls that reach it. started is closed by the first call.
type gateRepo struct {
	*fakeRepo
	mu      sync.Mutex
	calls   int
	started chan struct{}
	once    sync.Once
	release chan struct{}
	// sawCancel records whether the context handed to Like was already cancelled when the gate opened.
	sawCancel bool
}

func (g *gateRepo) Like(ctx context.Context, _ LikeParams) (bool, error) {
	g.mu.Lock()
	g.calls++
	g.mu.Unlock()
	g.once.Do(func() { close(g.started) })
	<-g.release
	g.mu.Lock()
	g.sawCancel = ctx.Err() != nil
	g.mu.Unlock()
	return false, nil
}

// newGateEnv builds an env whose repo blocks Like at a gate. joined is closed once n callers have joined a flight
// already in progress (flight.onJoin), the deterministic replacement for yielding to the scheduler: when it is
// closed every follower is parked on the leader's flight, so opening the gate cannot race a late arrival.
func newGateEnv(t *testing.T, n int32) (*env, *gateRepo, chan struct{}) {
	t.Helper()
	e := newEnv(t)
	g := &gateRepo{fakeRepo: e.repo, started: make(chan struct{}), release: make(chan struct{})}
	m, err := New(Deps{
		Repo: g, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-48 * time.Hour)},
		Events: e.events, LikesPerDay: 500, NewAccountLikesPerDay: 100, NewAccountWindow: 24 * time.Hour,
		CacheTTL: time.Minute, AllowAnonymous: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.m = m
	joined := make(chan struct{})
	var seen atomic.Int32
	m.s.likeFlight.onJoin = func(string) {
		if seen.Add(1) == n {
			close(joined)
		}
	}
	return e, g, joined
}

func TestLike_ConcurrentCallsCollapseIntoOneTransaction(t *testing.T) {
	const n = 8
	e, g, joined := newGateEnv(t, n-1)
	var wg sync.WaitGroup
	results := make([]Result, n)
	errs := make([]error, n)
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], errs[i] = e.m.Like(e.ctx, "viewer", keyOK, pidA)
		}()
	}
	<-g.started
	<-joined
	close(g.release)
	wg.Wait()
	for i := range n {
		if errs[i] != nil || !results[i].LikedByViewer {
			t.Fatalf("call %d: %+v, %v", i, results[i], errs[i])
		}
		// Leader and followers agree on the count (4 stored + the leader's single increment).
		if results[i].LikeCount != 5 {
			t.Errorf("call %d: LikeCount = %d, want 5", i, results[i].LikeCount)
		}
	}
	if g.calls != 1 {
		t.Errorf("repo.Like calls = %d, want exactly 1 (every other caller joined the flight)", g.calls)
	}
	if e.events.likes != g.calls || len(e.posts.counts) != g.calls {
		t.Errorf("events=%d counts=%v calls=%d: one notification and counter bump per transaction", e.events.likes, e.posts.counts, g.calls)
	}
}

// assertLikeEffects checks the post-commit effects of one committed like: the notification, the counter hook and
// the viewer's cached userLikes.
func assertLikeEffects(t *testing.T, e *env) {
	t.Helper()
	e.events.mu.Lock()
	likes := e.events.likes
	ctxErrs := append([]error(nil), e.events.ctxErrs...)
	e.events.mu.Unlock()
	for _, ce := range append(ctxErrs, e.repo.trimCtxErrs...) {
		if ce != nil {
			t.Errorf("post-commit effect ran on a cancelled ctx (%v): the notification would be lost", ce)
		}
	}
	if likes != 1 || len(e.posts.counts) != 1 || e.posts.counts[0] != pidA+":1:0" {
		t.Errorf("events.likes=%d counts=%v, want 1 and [%s:1:0]", likes, e.posts.counts, pidA)
	}
	st, ok := e.m.s.cache.get("viewer")
	if !ok {
		t.Fatal("viewer's userLikes cache entry is gone")
	}
	if liked, _ := st.set.Flags(e.posts.docs[pidA]); !liked {
		t.Errorf("cache recent = %v, want it to contain %s", st.recent, pidA)
	}
}

// A leader whose request context is cancelled mid-flight still waits for its own flight (the transaction commits
// on a detached context), so the post-commit effects run exactly once and the follower is not failed.
func TestLike_LeaderCancellationStillRunsEffectsAndKeepsFollowers(t *testing.T) {
	e, g, joined := newGateEnv(t, 1)
	e.m.s.cache.set("viewer", UserLikes{}) // a warm viewer entry, as after the first timeline read
	leaderCtx, cancelLeader := context.WithCancel(e.ctx)
	var wg sync.WaitGroup
	var leaderRes, followerRes Result
	var leaderErr, followerErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		leaderRes, leaderErr = e.m.Like(leaderCtx, "viewer", keyOK, pidA)
	}()
	<-g.started // the leader is inside the repo
	wg.Add(1)
	go func() {
		defer wg.Done()
		followerRes, followerErr = e.m.Like(e.ctx, "viewer", keyOK, pidA)
	}()
	<-joined // the follower is parked on the leader's flight
	cancelLeader()
	close(g.release)
	wg.Wait()
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.calls != 1 {
		t.Fatalf("repo.Like calls = %d, want 1 (follower joined the flight)", g.calls)
	}
	if g.sawCancel {
		t.Error("the flight's context was cancelled with the leader's request")
	}
	if followerErr != nil || !followerRes.LikedByViewer || followerRes.LikeCount != 5 {
		t.Errorf("follower: %+v, %v", followerRes, followerErr)
	}
	if leaderErr != nil || !leaderRes.LikedByViewer || leaderRes.LikeCount != 5 {
		t.Errorf("leader: %+v, %v", leaderRes, leaderErr)
	}
	assertLikeEffects(t, e)
}

// The same with no follower at all: a cancelled leader must still count, cache and notify the committed like.
func TestLike_LeaderCancelledWithoutFollowerStillRunsEffects(t *testing.T) {
	e, g, _ := newGateEnv(t, 0)
	e.m.s.cache.set("viewer", UserLikes{})
	leaderCtx, cancelLeader := context.WithCancel(e.ctx)
	done := make(chan struct{})
	var res Result
	var err error
	go func() {
		defer close(done)
		res, err = e.m.Like(leaderCtx, "viewer", keyOK, pidA)
	}()
	<-g.started
	cancelLeader()
	close(g.release)
	<-done
	if err != nil || !res.LikedByViewer {
		t.Fatalf("leader: %+v, %v", res, err)
	}
	assertLikeEffects(t, e)
}

// A follower that gives up returns its own context error while the flight and the leader carry on.
func TestLike_FollowerCancellationDoesNotFailTheLeader(t *testing.T) {
	e, g, joined := newGateEnv(t, 1)
	followerCtx, cancelFollower := context.WithCancel(e.ctx)
	var wg sync.WaitGroup
	var leaderRes Result
	var leaderErr, followerErr error
	followerDone := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		leaderRes, leaderErr = e.m.Like(e.ctx, "viewer", keyOK, pidA)
	}()
	<-g.started
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(followerDone)
		_, followerErr = e.m.Like(followerCtx, "viewer", keyOK, pidA)
	}()
	<-joined
	cancelFollower()
	<-followerDone // the follower returned while the flight is still gated
	close(g.release)
	wg.Wait()
	_ = requireCode(t, followerErr, connect.CodeCanceled)
	if leaderErr != nil || !leaderRes.LikedByViewer || leaderRes.LikeCount != 5 {
		t.Errorf("leader: %+v, %v", leaderRes, leaderErr)
	}
}

// Unlike and UndoRepost when the post (or the original behind a REPOST id) is gone: the delete still runs, the
// answer carries the id and zero counts, and no counter hook fires for a post that no longer exists.
func TestUndoAndUnlike_OriginalGone(t *testing.T) {
	const goneID = "0000000000000000099"
	t.Run("undo repost, original gone", func(t *testing.T) {
		e := newEnv(t)
		e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
		r, err := e.m.UndoRepost(e.ctx, "viewer", keyOK, goneID)
		if err != nil {
			t.Fatal(err)
		}
		if r.PostID != goneID || r.RepostCount != 0 || r.RepostedByViewer {
			t.Fatalf("r = %+v", r)
		}
		if len(e.posts.counts) != 0 {
			t.Fatalf("counts = %v, want none for a gone original", e.posts.counts)
		}
		if len(e.posts.removed) != 1 {
			t.Fatalf("the REPOST removal was not announced: %v", e.posts.removed)
		}
	})
	t.Run("undo repost by the REPOST's own id resolves the original", func(t *testing.T) {
		e := newEnv(t)
		e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
		r, err := e.m.UndoRepost(e.ctx, "viewer", keyOK, pidRep)
		if err != nil {
			t.Fatal(err)
		}
		if len(e.repo.undoIDs) != 1 || e.repo.undoIDs[0] != pidA {
			t.Fatalf("repo undo ids = %v, want the original %s", e.repo.undoIDs, pidA)
		}
		if r.PostID != pidA || r.RepostCount != 1 || len(e.posts.counts) != 1 || e.posts.counts[0] != pidA+":0:-1" {
			t.Fatalf("r=%+v counts=%v", r, e.posts.counts)
		}
	})
	t.Run("undo repost by a REPOST id whose original is gone", func(t *testing.T) {
		e := newEnv(t)
		delete(e.posts.docs, pidA)
		e.repo.undoRes = UndoResult{Removed: true, RepostPostID: pidRep}
		r, err := e.m.UndoRepost(e.ctx, "viewer", keyOK, pidRep)
		if err != nil || r.PostID != pidA {
			t.Fatalf("r=%+v err=%v", r, err)
		}
		if len(e.repo.undoIDs) != 1 || e.repo.undoIDs[0] != pidA {
			t.Fatalf("repo undo ids = %v, want the original %s (not the REPOST id)", e.repo.undoIDs, pidA)
		}
	})
	t.Run("unlike by a REPOST id whose original is gone", func(t *testing.T) {
		e := newEnv(t)
		delete(e.posts.docs, pidA)
		e.repo.unlikeResult = true
		r, err := e.m.Unlike(e.ctx, "viewer", keyOK, pidRep)
		if err != nil || r.LikeCount != 0 || len(e.posts.counts) != 0 {
			t.Fatalf("r=%+v err=%v counts=%v", r, err, e.posts.counts)
		}
		if len(e.repo.unlikeIDs) != 1 || e.repo.unlikeIDs[0] != pidA {
			t.Fatalf("repo unlike ids = %v, want the original %s (not the REPOST id)", e.repo.unlikeIDs, pidA)
		}
		if r.PostID != pidA {
			t.Fatalf("r.PostID = %s, want %s", r.PostID, pidA)
		}
	})
}

// A REPOST id acts on its original; a broken or hidden original is the one NOT_FOUND.
func TestLike_ResolvesRepostIDs(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(e *env)
		wantID  string
		wantErr bool
	}{
		{"repost id acts on the original", func(*env) {}, pidA, false},
		{"repost without an original id", func(e *env) { e.posts.docs[pidRep].RepostOfID = "" }, "", true},
		{"original hidden", func(e *env) { e.posts.hidden[pidA] = true }, "", true},
		{"original deleted", func(e *env) { delete(e.posts.docs, pidA) }, "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := newEnv(t)
			tt.mutate(e)
			r, err := e.m.Like(e.ctx, "viewer", keyOK, pidRep)
			if tt.wantErr {
				_ = requireCode(t, err, connect.CodeNotFound)
				return
			}
			if err != nil || r.PostID != tt.wantID {
				t.Fatalf("r=%+v err=%v", r, err)
			}
		})
	}
}

// Released drops the reposted id from a cached userLikes entry even when the repo has no release seam, and
// ForgetUser drops the entry.
func TestReleasedAndForgetUser(t *testing.T) {
	e := newEnv(t)
	e.repo.loaded = UserLikes{Recent: []string{pidB}, RecentReposts: []string{pidA}}
	_ = e.m.Viewer(e.ctx, "viewer")
	if err := e.m.Released(e.ctx, pidA, "viewer"); err != nil {
		t.Fatal(err)
	}
	st, ok := e.m.s.cache.get("viewer")
	if !ok || len(st.reposts) != 0 || len(st.recent) != 1 {
		t.Fatalf("state after release = %+v ok=%v", st, ok)
	}
	e.m.StageRelease(nil, pidA, "viewer") // the fake repo is no releaser: a no-op, must not panic
	e.m.ForgetUser("viewer")
	if _, ok := e.m.s.cache.get("viewer"); ok {
		t.Fatal("ForgetUser left the cached entry")
	}
}

// Concurrent updates of one user's cached state (separate flights for different posts) never lose an id.
func TestUserCache_ConcurrentUpdatesKeepEveryID(t *testing.T) {
	c := newUserCache(time.Minute, 10)
	c.set("u", UserLikes{})
	const n = 50
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c.update("u", func(recent, reposts []string) ([]string, []string) {
				return withID(recent, fmt.Sprintf("%019d", i)), reposts
			})
		}()
	}
	wg.Wait()
	if st, _ := c.get("u"); len(st.recent) != n {
		t.Fatalf("recent has %d ids, want %d (a concurrent update was lost)", len(st.recent), n)
	}
}
