package posts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeRepo is an in-memory Repo; the call counters and last-argument fields let the unit tests assert what reached
// the repository.
type fakeRepo struct {
	docs map[string]*Post

	getAllCalls   int
	lastGetAllIDs []string
	queryCalls    int
	lastAuthors   []string
	lastAuthor    string
	lastReplies   bool
	lastMedia     bool
	lastTag       string
	lastCommunity string
	lastCAfter    Position
	lastKind      Kind
	lastWindow    Window
	lastLimit     int
	beforeReturn  func()
	queryResult   []*Post
	queryErr      error
	getAllErr     error

	// CreatePost model (create_fakes_test.go).
	idem        map[string]fakeIdem
	createCalls int
	createErr   error
	onCreate    func() // runs inside Create just before createErr is returned (e.g. the caller cancels mid-transaction)
	postsCount  int64
	nextID      int64
	lastCreate  CreateParams

	// DeletePost model.
	deleteCalls int
	deleteErr   error
	deleteRace  bool // the post vanishes between the read and the batch (a concurrent delete won)

	// Replies model.
	parentGone        bool // the parent is deleted between the visibility check and the commit
	conversationCalls int
	conversationErr   error
	lastAfter         *Position
	replyCountCalls   int
	replyCountErr     error
}

func newFakeRepo(ps ...*Post) *fakeRepo {
	r := &fakeRepo{docs: map[string]*Post{}}
	for _, p := range ps {
		r.docs[p.ID] = p
	}
	return r
}

func (r *fakeRepo) GetAll(ctx context.Context, ids []string) (map[string]*Post, error) {
	r.getAllCalls++
	r.lastGetAllIDs = append([]string(nil), ids...)
	if r.getAllErr != nil {
		return nil, r.getAllErr
	}
	out := map[string]*Post{}
	for _, id := range ids {
		if p, ok := r.docs[id]; ok {
			out[id] = p
		}
	}
	return out, nil
}

func (r *fakeRepo) query(ctx context.Context, w Window, limit int) ([]*Post, error) {
	r.queryCalls++
	r.lastWindow, r.lastLimit = w, limit
	if r.beforeReturn != nil {
		r.beforeReturn() // models a write landing while the query is in flight
	}
	return r.queryResult, r.queryErr
}

func (r *fakeRepo) ByAuthors(ctx context.Context, authorIDs []string, w Window, limit int) ([]*Post, error) {
	r.lastAuthors = append([]string(nil), authorIDs...)
	return r.query(ctx, w, limit)
}

func (r *fakeRepo) ByAuthor(ctx context.Context, authorID string, includeReplies bool, w Window, limit int) ([]*Post, error) {
	r.lastAuthor, r.lastReplies = authorID, includeReplies
	return r.query(ctx, w, limit)
}

// ByAuthorMedia and ByAuthorKind record what the service asked (lastMedia / lastKind) and answer like ByAuthor.
func (r *fakeRepo) ByAuthorMedia(ctx context.Context, authorID string, w Window, limit int) ([]*Post, error) {
	r.lastAuthor, r.lastMedia = authorID, true
	return r.query(ctx, w, limit)
}

func (r *fakeRepo) ByHashtag(ctx context.Context, tag string, w Window, limit int) ([]*Post, error) {
	r.lastTag = tag
	return r.query(ctx, w, limit)
}

func (r *fakeRepo) ByCommunity(ctx context.Context, cid string, w Window, limit int) ([]*Post, error) {
	r.lastCommunity = cid
	return r.query(ctx, w, limit)
}

func (r *fakeRepo) CreatedAfter(ctx context.Context, after Position, limit int) ([]*Post, error) {
	r.lastCAfter = after
	return r.query(ctx, Window{}, limit)
}

func (r *fakeRepo) ByAuthorKind(ctx context.Context, authorID string, kind Kind, w Window, limit int) ([]*Post, error) {
	r.lastAuthor, r.lastKind = authorID, kind
	return r.query(ctx, w, limit)
}

func post(id, author string) *Post {
	return &Post{ID: id, AuthorID: author, Kind: KindPost, Visibility: VisibilityPublic, ConversationID: id, Text: "t " + id}
}

func newSvc(repo Repo) (*service, *Cache) {
	c := NewCache(time.Minute, 0, 0)
	return New(Deps{Repo: repo, Cache: c}).(*service), c
}

func TestGet(t *testing.T) {
	p := post("0000000000000000001", "a")
	repo := newFakeRepo(p)
	svc, _ := newSvc(repo)

	ctx := context.Background()
	got, err := svc.Get(ctx, p.ID)
	if err != nil || got != p || repo.getAllCalls != 1 {
		t.Fatalf("cold Get: got=%v err=%v getAllCalls=%d, want the post, nil, 1", got, err, repo.getAllCalls)
	}
	got, err = svc.Get(ctx, p.ID)
	if err != nil || got != p || repo.getAllCalls != 1 {
		t.Fatalf("warm Get: got=%v err=%v getAllCalls=%d, want the post from the cache, nil, 1", got, err, repo.getAllCalls)
	}

	// Absence is never cached, or a just-created post would stay NOT_FOUND until the entry expired: each Get of a
	// missing id goes back to the repo.
	for i := 0; i < 2; i++ {
		before := repo.getAllCalls
		_, err = svc.Get(ctx, "0000000000000000999")
		if !errors.Is(err, ErrNotFound) || repo.getAllCalls != before+1 {
			t.Fatalf("missing Get #%d: err=%v getAllCalls=%d, want ErrNotFound, %d", i, err, repo.getAllCalls, before+1)
		}
	}
	repo.getAllErr = errors.New("boom")
	if _, err := svc.Get(context.Background(), "0000000000000000555"); err == nil || errors.Is(err, ErrNotFound) {
		t.Fatalf("a repo failure must not look like not-found: %v", err)
	}
}

// TestGetMany_TwelveOfTwentyCached is the acceptance: 20 ids with 12 cached fetch only the other 8, in one GetAll.
func TestGetMany_TwelveOfTwentyCached(t *testing.T) {
	var all []*Post
	var ids []string
	for i := 0; i < 20; i++ {
		p := post(fmt.Sprintf("%019d", i+1), "a")
		all = append(all, p)
		ids = append(ids, p.ID)
	}
	repo := newFakeRepo(all...)
	svc, cache := newSvc(repo)
	for _, p := range all[:12] {
		cache.SetPost(p)
	}

	got, err := svc.GetMany(context.Background(), ids)
	if err != nil || len(got) != 20 {
		t.Fatalf("GetMany: len=%d err=%v", len(got), err)
	}
	if repo.getAllCalls != 1 || len(repo.lastGetAllIDs) != 8 {
		t.Fatalf("getAllCalls=%d fetched=%d, want 1, 8", repo.getAllCalls, len(repo.lastGetAllIDs))
	}
	// Everything is cached now: a repeat makes no GetAll.
	if _, err := svc.GetMany(context.Background(), ids); err != nil {
		t.Fatalf("repeat GetMany: %v", err)
	}
	if repo.getAllCalls != 1 {
		t.Fatalf("repeat: getAllCalls=%d, want 1", repo.getAllCalls)
	}
}

func TestGetMany_EdgeCases(t *testing.T) {
	p1, p2 := post("0000000000000000001", "a"), post("0000000000000000002", "a")
	dedupeRepo := newFakeRepo(p1, p2)
	svc, _ := newSvc(dedupeRepo)

	t.Run("duplicates are fetched once and missing ids are absent", func(t *testing.T) {
		got, _ := svc.GetMany(context.Background(), []string{p1.ID, p1.ID, "0000000000000000404", p2.ID})
		if len(got) != 2 || got[p1.ID] != p1 || got[p2.ID] != p2 {
			t.Fatalf("got=%v, want 2 posts", got)
		}
		if len(dedupeRepo.lastGetAllIDs) != 3 {
			t.Fatalf("fetched ids = %v, want 3 with the duplicate dropped", dedupeRepo.lastGetAllIDs)
		}
	})
	t.Run("no ids", func(t *testing.T) {
		repo := newFakeRepo()
		s, _ := newSvc(repo)
		got, err := s.GetMany(context.Background(), nil)
		if err != nil || len(got) != 0 || repo.getAllCalls != 0 {
			t.Fatalf("got=%v err=%v getAllCalls=%d", got, err, repo.getAllCalls)
		}
	})
	t.Run("more than 50 distinct ids is an error before any read", func(t *testing.T) {
		repo := newFakeRepo()
		s, _ := newSvc(repo)
		var ids []string
		for i := 0; i <= MaxGetMany; i++ {
			ids = append(ids, fmt.Sprintf("%019d", i))
		}
		if _, err := s.GetMany(context.Background(), ids); err == nil || repo.getAllCalls != 0 {
			t.Fatalf("err=%v getAllCalls=%d, want an error and no GetAll", err, repo.getAllCalls)
		}
	})
	t.Run("a repo error is returned", func(t *testing.T) {
		repo := newFakeRepo()
		repo.getAllErr = errors.New("boom")
		s, _ := newSvc(repo)
		if _, err := s.GetMany(context.Background(), []string{"1"}); err == nil {
			t.Fatal("want an error")
		}
	})
}

// TestByAuthors_ThreeAuthorsNoMatches is the acceptance: 3 authors with 0 matching posts run one query.
func TestByAuthors_ThreeAuthorsNoMatches(t *testing.T) {
	repo := newFakeRepo()
	svc, _ := newSvc(repo)
	got, err := svc.ByAuthors(context.Background(), []string{"a", "b", "c"}, Window{}, 10)
	if err != nil || len(got) != 0 || repo.queryCalls != 1 {
		t.Fatalf("got=%v err=%v queryCalls=%d, want empty, nil, 1", got, err, repo.queryCalls)
	}
}

func TestByAuthors(t *testing.T) {
	older := &Position{CreatedAt: time.UnixMilli(1000), ID: "0000000000000000010"}
	newer := &Position{CreatedAt: time.UnixMilli(2000), ID: "0000000000000000020"}
	res := []*Post{post("0000000000000000015", "a"), post("0000000000000000012", "b")}

	tests := []struct {
		name      string
		authors   []string
		window    Window
		limit     int
		wantErr   bool
		wantCalls int
		wantLimit int
	}{
		{"no authors means no query", nil, Window{}, 5, false, 0, 0},
		{"limit 0 is the default page size", []string{"a"}, Window{}, 0, false, 1, 20},
		{"negative limit is the default", []string{"a"}, Window{}, -3, false, 1, 20},
		{"limit above 50 is clamped", []string{"a"}, Window{}, 500, false, 1, 50},
		{"limit in range is kept", []string{"a", "b"}, Window{}, 7, false, 1, 7},
		{"window is passed through", []string{"a"}, Window{Before: newer, After: older}, 7, false, 1, 7},
		{"30 authors is the most", authorsN(MaxByAuthors), Window{}, 7, false, 1, 7},
		{"31 authors is rejected", authorsN(MaxByAuthors + 1), Window{}, 7, true, 0, 0},
		{"a bound without an id is rejected", []string{"a"}, Window{Before: &Position{CreatedAt: time.UnixMilli(1)}}, 7, true, 0, 0},
		{"an After bound without an id is rejected", []string{"a"}, Window{After: &Position{CreatedAt: time.UnixMilli(1)}}, 7, true, 0, 0},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.queryResult = res
			svc, cache := newSvc(repo)
			got, err := svc.ByAuthors(context.Background(), tc.authors, tc.window, tc.limit)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if repo.queryCalls != tc.wantCalls {
				t.Fatalf("queryCalls = %d, want %d", repo.queryCalls, tc.wantCalls)
			}
			if tc.wantCalls == 0 {
				if len(got) != 0 {
					t.Fatalf("no query must return nothing: got=%v", got)
				}
				return
			}
			if repo.lastLimit != tc.wantLimit {
				t.Fatalf("limit = %d, want %d", repo.lastLimit, tc.wantLimit)
			}
			if repo.lastWindow != tc.window {
				t.Fatalf("window = %+v, want %+v", repo.lastWindow, tc.window)
			}
			if len(got) != len(res) {
				t.Fatalf("got=%d, want %d", len(got), len(res))
			}
			for _, p := range res {
				if cp, ok := cache.GetPost(p.ID); !ok || cp != p {
					t.Fatalf("result %s was not put in the posts cache", p.ID)
				}
			}
		})
	}

	t.Run("a repo error is returned and caches nothing", func(t *testing.T) {
		repo := newFakeRepo()
		repo.queryErr = errors.New("boom")
		svc, _ := newSvc(repo)
		if _, err := svc.ByAuthors(context.Background(), []string{"a"}, Window{}, 5); err == nil {
			t.Fatal("want an error")
		}
	})
}

func authorsN(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("author-%d", i)
	}
	return out
}

func TestByAuthor(t *testing.T) {
	res := []*Post{post("0000000000000000015", "a")}
	tests := []struct {
		name        string
		author      string
		replies     bool
		window      Window
		wantErr     bool
		wantReplies bool
	}{
		{"Posts tab", "a", false, Window{}, false, false},
		{"Replies tab runs the unfiltered query", "a", true, Window{}, false, true},
		{"empty author", "", false, Window{}, true, false},
		{"bad window", "a", false, Window{Before: &Position{}}, true, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := newFakeRepo()
			repo.queryResult = res
			svc, _ := newSvc(repo)
			got, err := svc.ByAuthor(context.Background(), tc.author, tc.replies, tc.window, 0)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tc.wantErr)
			}
			if tc.wantErr {
				if repo.queryCalls != 0 {
					t.Fatalf("a rejected call must not query: calls=%d", repo.queryCalls)
				}
				return
			}
			if repo.lastAuthor != tc.author || repo.lastReplies != tc.wantReplies || repo.lastLimit != 20 {
				t.Fatalf("author=%q replies=%v limit=%d", repo.lastAuthor, repo.lastReplies, repo.lastLimit)
			}
			if len(got) != 1 {
				t.Fatalf("got=%d, want 1", len(got))
			}
		})
	}

	t.Run("empty result", func(t *testing.T) {
		svc, _ := newSvc(newFakeRepo())
		got, _ := svc.ByAuthor(context.Background(), "a", false, Window{}, 10)
		if len(got) != 0 {
			t.Fatalf("got=%d, want 0", len(got))
		}
	})
	t.Run("a repo error is returned", func(t *testing.T) {
		repo := newFakeRepo()
		repo.queryErr = errors.New("boom")
		svc, _ := newSvc(repo)
		if _, err := svc.ByAuthor(context.Background(), "a", false, Window{}, 5); err == nil {
			t.Fatal("want an error")
		}
	})
}

func TestAuthorRecentThroughReader(t *testing.T) {
	svc, cache := newSvc(newFakeRepo())
	now := time.Now()
	ps := []*Post{post("0000000000000000003", "a"), post("0000000000000000002", "a")}
	svc.StoreAuthorRecent("a", ps, false, now)

	got, ok := svc.AuthorRecent("a")
	if !ok || len(got.Posts) != 2 || got.Truncated || !got.LoadedAt.Equal(now) {
		t.Fatalf("AuthorRecent = %+v, %v", got, ok)
	}
	// Storing an entry also fills the posts cache, so those posts are 0-read for GetMany.
	if p, ok := cache.GetPost(ps[0].ID); !ok || p != ps[0] {
		t.Fatal("StoreAuthorRecent did not fill the posts cache")
	}
	if _, ok := svc.AuthorRecent("nobody"); ok {
		t.Fatal("unknown author must miss")
	}
}

func TestClampLimit(t *testing.T) {
	for in, want := range map[int]int{-1: 20, 0: 20, 1: 1, 49: 49, 50: 50, 51: 50, 1 << 20: 50} {
		if got := clampLimit(in); got != want {
			t.Errorf("clampLimit(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestNew_DefaultsEventsToNop(t *testing.T) {
	s := New(Deps{Repo: newFakeRepo(), Cache: NewCache(time.Minute, 0, 0)}).(*service)
	if _, ok := s.events.(NopEvents); !ok {
		t.Fatalf("events = %T, want NopEvents", s.events)
	}
	// The no-op hook is callable and does nothing.
	s.events.Created(context.Background(), post("1", "a"))
	s.events.Deleted(context.Background(), "1", "a")
	if s.now == nil {
		t.Fatal("now must default")
	}
}

func TestSentinelAndFlagName(t *testing.T) {
	if !strings.Contains(ErrNotFound.Error(), "not found") || FlagName != "posts" {
		t.Fatalf("ErrNotFound=%q FlagName=%q", ErrNotFound, FlagName)
	}
}
