package engagement

import (
	"context"
	"errors"
	"testing"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// fakeBMRepo is the BookmarkRepo of the service tests: it records the params and answers with the configured result.
type fakeBMRepo struct {
	addRes, rmRes BookmarkResult
	addErr, rmErr error
	adds          []AddBookmarkParams
	removes       []RemoveBookmarkParams
}

func (f *fakeBMRepo) Add(_ context.Context, p AddBookmarkParams) (BookmarkResult, error) {
	f.adds = append(f.adds, p)
	if f.addRes.State.PostID == "" {
		f.addRes.State = BookmarkState{PostID: p.PostID, Bookmarked: true}
	}
	return f.addRes, f.addErr
}

func (f *fakeBMRepo) Remove(_ context.Context, p RemoveBookmarkParams) (BookmarkResult, error) {
	f.removes = append(f.removes, p)
	if f.rmRes.State.PostID == "" {
		f.rmRes.State = BookmarkState{PostID: p.PostID}
	}
	return f.rmRes, f.rmErr
}

// bmEnv is env plus the bookmark repo; the module is rebuilt with the bookmark deps (200 / 50 a day, cap 1,000).
type bmEnv struct {
	*env
	bm *fakeBMRepo
}

func newBMEnv(t *testing.T, accountAge time.Duration) *bmEnv {
	t.Helper()
	e := newEnv(t)
	bm := &fakeBMRepo{}
	m, err := New(Deps{
		Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{created: time.Now().Add(-accountAge)},
		Events: e.events, LikesPerDay: 500, NewAccountLikesPerDay: 100, PostsPerDay: 100, NewAccountPostsPerDay: 20,
		NewAccountWindow: 24 * time.Hour, CacheTTL: time.Minute, AllowAnonymous: true,
		BookmarkRepo: bm, BookmarksPerDay: 200, NewAccountBookmarksPerDay: 50, BookmarksMaxPerUser: 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.m = m
	return &bmEnv{env: e, bm: bm}
}

func requireReason(t *testing.T, err error, code connect.Code, reason commonv1.ErrorReason) *apierr.Error {
	t.Helper()
	ae := requireCode(t, err, code)
	if ae.Reason != reason {
		t.Fatalf("reason = %v, want %v (err %v)", ae.Reason, reason, err)
	}
	return ae
}

func TestAddBookmark(t *testing.T) {
	t.Run("first add", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		st, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		if err != nil {
			t.Fatal(err)
		}
		if st != (BookmarkState{PostID: pidA, Bookmarked: true}) {
			t.Fatalf("state = %+v", st)
		}
		if len(e.bm.adds) != 1 {
			t.Fatalf("repo adds = %d, want 1", len(e.bm.adds))
		}
		got := e.bm.adds[0]
		want := AddBookmarkParams{
			UID: "viewer", PostID: pidA, IdemKey: idempotency.Key("viewer", "AddBookmark", keyOK),
			RequestHash: bookmarkRequestHash(pidA), QuotaLimit: 200, MaxPerUser: 1000,
		}
		if got != want {
			t.Fatalf("params = %+v, want %+v", got, want)
		}
		// A bookmark is private: no counter, no notification, no event of any kind.
		if e.events.likes != 0 || e.events.reposts != 0 || len(e.posts.counts) != 0 || len(e.posts.created) != 0 {
			t.Fatalf("side effects: events %d/%d counts %v created %v", e.events.likes, e.events.reposts, e.posts.counts, e.posts.created)
		}
	})

	t.Run("new accounts get the smaller daily quota", func(t *testing.T) {
		for _, tt := range []struct {
			name string
			age  time.Duration
			want int64
		}{
			{"1 hour old", time.Hour, 50},
			{"just inside the window", 24*time.Hour - time.Minute, 50},
			{"just outside the window", 24*time.Hour + time.Minute, 200},
		} {
			t.Run(tt.name, func(t *testing.T) {
				e := newBMEnv(t, tt.age)
				if _, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA); err != nil {
					t.Fatal(err)
				}
				if got := e.bm.adds[0].QuotaLimit; got != tt.want {
					t.Fatalf("quota limit = %d, want %d", got, tt.want)
				}
			})
		}
	})

	t.Run("a REPOST id bookmarks its original, keyed by the id as sent", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		st, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidRep)
		if err != nil {
			t.Fatal(err)
		}
		if st.PostID != pidA || !st.Bookmarked {
			t.Fatalf("state = %+v, want the original %s", st, pidA)
		}
		if got := e.bm.adds[0]; got.PostID != pidA || got.RequestHash != bookmarkRequestHash(pidRep) {
			t.Fatalf("params = %+v, want doc id %s and the hash of the id as sent", got, pidA)
		}
	})

	t.Run("a REPOST whose original is hidden is NOT_FOUND", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.posts.hidden[pidA] = true
		_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidRep)
		_ = requireCode(t, err, connect.CodeNotFound)
		if len(e.bm.adds) != 0 {
			t.Fatal("the repo must not be reached")
		}
	})

	t.Run("not visible: the one NOT_FOUND, byte-identical to GetPost, 0 repo calls", func(t *testing.T) {
		for name, setup := range map[string]func(*bmEnv){
			"missing": func(*bmEnv) {},
			"hidden (deleted, taken down, blocking author)": func(e *bmEnv) { e.posts.hidden[pidB] = true },
		} {
			t.Run(name, func(t *testing.T) {
				e := newBMEnv(t, 48*time.Hour)
				setup(e)
				id := pidB
				if name == "missing" {
					id = "0000000000000000099"
				}
				_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, id)
				ae := requireReason(t, err, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED)
				if ae.Message != "post not found" || len(ae.Metadata) != 0 {
					t.Fatalf("not-found answer = %+v, want the bare %q", ae, "post not found")
				}
				if len(e.bm.adds) != 0 {
					t.Fatal("the repo must not be reached")
				}
			})
		}
	})

	t.Run("the cap is LIMIT_REACHED limit=bookmarks", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.addErr = ErrBookmarkLimit
		_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		ae := requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED)
		if ae.Metadata["limit"] != "bookmarks" {
			t.Fatalf("metadata = %v, want limit=bookmarks", ae.Metadata)
		}
	})

	t.Run("the daily quota is QUOTA_EXCEEDED quota=bookmarks", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.addErr = quota.ExceededError(quota.Bookmarks, time.Now())
		_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		ae := requireReason(t, err, connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
		if ae.Metadata["quota"] != "bookmarks" {
			t.Fatalf("metadata = %v, want quota=bookmarks", ae.Metadata)
		}
	})

	t.Run("a key used for another post is IDEMPOTENCY_KEY_REUSED", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.addErr = ErrIdempotencyKeyReused
		_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		_ = requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
	})

	t.Run("an unexpected repo error is a redacted internal error, not an apierr", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.addErr = errors.New("firestore exploded")
		_, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a plain error that maps to INTERNAL", err)
		}
	})

	t.Run("replay and existing bookmark answer with the state and log their outcome", func(t *testing.T) {
		for name, o := range map[string]BookmarkOutcome{"replay": BookmarkReplayed, "existing": BookmarkUnchanged} {
			t.Run(name, func(t *testing.T) {
				e := newBMEnv(t, 48*time.Hour)
				e.bm.addRes = BookmarkResult{Outcome: o, State: BookmarkState{PostID: pidA, Bookmarked: true}}
				st, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
				if err != nil || st != (BookmarkState{PostID: pidA, Bookmarked: true}) {
					t.Fatalf("state = %+v err = %v", st, err)
				}
			})
		}
	})

	t.Run("validation fails before any read", func(t *testing.T) {
		for name, tt := range map[string]struct{ key, post string }{
			"short key":  {"short", pidA},
			"bad key":    {"has spaces in it!!", pidA},
			"empty post": {keyOK, ""},
			"bad post":   {keyOK, "12"},
		} {
			t.Run(name, func(t *testing.T) {
				e := newBMEnv(t, 48*time.Hour)
				_, err := e.m.AddBookmark(e.ctx, "viewer", tt.key, tt.post)
				_ = requireCode(t, err, connect.CodeInvalidArgument)
				if len(e.bm.adds) != 0 || e.posts.viewCalls != 0 {
					t.Fatalf("repo adds %d, visibility checks %d, want 0/0", len(e.bm.adds), e.posts.viewCalls)
				}
			})
		}
	})

	t.Run("no profile yet is PROFILE_REQUIRED", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		m, err := New(Deps{
			Repo: e.repo, Posts: e.posts, Reader: e.posts, Directory: fakeDir{missing: true}, BookmarkRepo: e.bm,
			BookmarksPerDay: 200, NewAccountBookmarksPerDay: 50, BookmarksMaxPerUser: 1000, NewAccountWindow: time.Hour,
		})
		if err != nil {
			t.Fatal(err)
		}
		_, err = m.AddBookmark(e.ctx, "viewer", keyOK, pidA)
		_ = requireReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
	})

	t.Run("an unwired repo fails without panicking", func(t *testing.T) {
		e := newEnv(t) // no BookmarkRepo
		if _, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA); err == nil {
			t.Fatal("want an error")
		}
		if _, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestRemoveBookmark(t *testing.T) {
	t.Run("removes without a visibility check or a profile read", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.posts.hidden[pidA] = true // a hidden or deleted post can still be removed
		e.bm.rmRes = BookmarkResult{Outcome: BookmarkWritten}
		st, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA)
		if err != nil || st != (BookmarkState{PostID: pidA}) {
			t.Fatalf("state = %+v err = %v", st, err)
		}
		if e.posts.viewCalls != 0 {
			t.Fatalf("visibility checks = %d, want 0", e.posts.viewCalls)
		}
		want := RemoveBookmarkParams{UID: "viewer", PostID: pidA, IdemKey: idempotency.Key("viewer", "RemoveBookmark", keyOK), RequestHash: bookmarkRequestHash(pidA)}
		if len(e.bm.removes) != 1 || e.bm.removes[0] != want {
			t.Fatalf("params = %+v, want %+v", e.bm.removes, want)
		}
	})

	t.Run("a REPOST id is not resolved: it is a no-op for the repo to find", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.rmRes = BookmarkResult{Outcome: BookmarkUnchanged}
		st, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidRep)
		if err != nil || st != (BookmarkState{PostID: pidRep}) || e.bm.removes[0].PostID != pidRep {
			t.Fatalf("state = %+v err = %v params = %+v", st, err, e.bm.removes)
		}
	})

	t.Run("a missing bookmark and a replay are successes", func(t *testing.T) {
		for name, o := range map[string]BookmarkOutcome{"no-op": BookmarkUnchanged, "replay": BookmarkReplayed} {
			t.Run(name, func(t *testing.T) {
				e := newBMEnv(t, 48*time.Hour)
				e.bm.rmRes = BookmarkResult{Outcome: o, State: BookmarkState{PostID: pidA}}
				st, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA)
				if err != nil || st.Bookmarked {
					t.Fatalf("state = %+v err = %v", st, err)
				}
			})
		}
	})

	t.Run("errors", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.rmErr = ErrIdempotencyKeyReused
		_, err := e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA)
		_ = requireReason(t, err, connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
		e.bm.rmErr = errors.New("boom")
		_, err = e.m.RemoveBookmark(e.ctx, "viewer", keyOK, pidA)
		var ae *apierr.Error
		if err == nil || errors.As(err, &ae) {
			t.Fatalf("err = %v, want a plain error", err)
		}
		_, err = e.m.RemoveBookmark(e.ctx, "viewer", "short", pidA)
		_ = requireCode(t, err, connect.CodeInvalidArgument)
	})
}

// The instance userLikes cache follows the caller's own writes (read-your-writes) but never a replay, and an own write
// never creates an entry (it would hide the user's other bookmarks).
func TestBookmarks_ViewerCache(t *testing.T) {
	post := &posts.Post{ID: pidA, Kind: posts.KindPost}
	rep := &posts.Post{ID: pidRep, Kind: posts.KindRepost, Embedded: &posts.Embedded{PostID: pidA}}

	t.Run("Viewer hydrates the bookmarks of the userLikes doc, REPOST items by their original", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.repo.loaded = UserLikes{Recent: []string{pidB}, Bookmarks: []string{pidA}}
		vs := e.m.Viewer(e.ctx, "viewer")
		if !vs.Bookmarked(post) || !vs.Bookmarked(rep) || vs.Bookmarked(&posts.Post{ID: pidB}) {
			t.Fatal("bookmarked flags wrong")
		}
		if liked, _ := vs.Flags(&posts.Post{ID: pidB}); !liked {
			t.Fatal("liked flag lost")
		}
		if e.repo.loads != 1 {
			t.Fatalf("userLikes loads = %d, want 1", e.repo.loads)
		}
	})

	t.Run("add and remove update a present entry and keep the liked ids", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.repo.loaded = UserLikes{Recent: []string{pidB}}
		e.m.Viewer(e.ctx, "viewer") // fills the cache
		if _, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		vs := e.m.Viewer(e.ctx, "viewer")
		if liked, _ := vs.Flags(&posts.Post{ID: pidB}); !vs.Bookmarked(post) || !liked {
			t.Fatal("after add: want bookmarked and the like kept")
		}
		e.bm.rmRes = BookmarkResult{Outcome: BookmarkWritten}
		if _, err := e.m.RemoveBookmark(e.ctx, "viewer", "engagement-key-0002", pidA); err != nil {
			t.Fatal(err)
		}
		vs = e.m.Viewer(e.ctx, "viewer")
		if liked, _ := vs.Flags(&posts.Post{ID: pidB}); vs.Bookmarked(post) || !liked {
			t.Fatal("after remove: want not bookmarked and the like kept")
		}
		if e.repo.loads != 1 {
			t.Fatalf("userLikes loads = %d, want 1 (the writes update the cache)", e.repo.loads)
		}
	})

	t.Run("a like or an unlike keeps the bookmarks", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.repo.loaded = UserLikes{Bookmarks: []string{pidB}}
		e.m.Viewer(e.ctx, "viewer")
		if _, err := e.m.Like(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		if _, err := e.m.Unlike(e.ctx, "viewer", "engagement-key-0002", pidA); err != nil {
			t.Fatal(err)
		}
		if vs := e.m.Viewer(e.ctx, "viewer"); !vs.Bookmarked(&posts.Post{ID: pidB}) {
			t.Fatal("bookmarks lost by a like/unlike cache update")
		}
	})

	t.Run("a replay leaves the cache alone, an own write never creates an entry", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		e.bm.addRes = BookmarkResult{Outcome: BookmarkReplayed}
		if _, err := e.m.AddBookmark(e.ctx, "viewer", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		e.repo.loaded = UserLikes{} // the doc: not bookmarked (removed since)
		if e.m.Viewer(e.ctx, "viewer").Bookmarked(post) {
			t.Fatal("a replay or an add without an entry must not make the cache claim a bookmark")
		}
		if e.repo.loads != 1 {
			t.Fatalf("loads = %d, want 1: the add created no entry, so the Viewer call loaded the doc", e.repo.loads)
		}
	})

	t.Run("a user and its claims are independent", func(t *testing.T) {
		e := newBMEnv(t, 48*time.Hour)
		ctx := authn.WithClaims(context.Background(), authn.Claims{UID: "other", SignInProvider: authn.SignInProviderGoogle})
		if _, err := e.m.AddBookmark(ctx, "other", keyOK, pidA); err != nil {
			t.Fatal(err)
		}
		if e.bm.adds[0].UID != "other" {
			t.Fatalf("uid = %s", e.bm.adds[0].UID)
		}
	})
}
