package engagement

import (
	"context"
	"errors"
	"fmt"
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
	trimRepost   [][]string
}

func (f *fakeRepo) LoadUserLikes(context.Context, string) (UserLikes, error) {
	f.loads++
	return f.loaded, f.loadErr
}

func (f *fakeRepo) Like(_ context.Context, p LikeParams) (bool, error) {
	f.likeParams = append(f.likeParams, p)
	return f.replayed, f.likeErr
}

func (f *fakeRepo) Unlike(context.Context, string, string) (bool, error) { return f.unlikeResult, nil }

func (f *fakeRepo) Repost(_ context.Context, p RepostParams) (RepostResult, error) {
	f.repostParams = append(f.repostParams, p)
	return f.repostRes, f.repostErr
}

func (f *fakeRepo) UndoRepost(context.Context, string, string) (UndoResult, error) {
	return f.undoRes, nil
}

func (f *fakeRepo) TrimLikes(_ context.Context, _ string, recent, reposts []string) error {
	f.trims = append(f.trims, recent)
	f.trimRepost = append(f.trimRepost, reposts)
	return nil
}

type fakePosts struct {
	docs      map[string]*posts.Post
	hidden    map[string]bool
	counts    []string
	created   []*posts.Post
	removed   []string
	viewCalls int
}

func (f *fakePosts) Viewable(_ context.Context, _, id string) (*posts.Post, error) {
	f.viewCalls++
	p, ok := f.docs[id]
	if !ok || f.hidden[id] {
		return nil, posts.ErrNotFound
	}
	return p, nil
}

func (f *fakePosts) CountsChanged(id string, l, r int64) {
	f.counts = append(f.counts, fmt.Sprintf("%s:%d:%d", id, l, r))
}
func (f *fakePosts) RepostCreated(p *posts.Post) { f.created = append(f.created, p) }
func (f *fakePosts) RepostRemoved(a, id string)  { f.removed = append(f.removed, a+"/"+id) }

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

type fakeEvents struct{ likes, reposts int }

func (e *fakeEvents) Liked(context.Context, string, *posts.Post, time.Time) { e.likes++ }
func (e *fakeEvents) Reposted(context.Context, string, *posts.Post, string, time.Time) {
	e.reposts++
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
