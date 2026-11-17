package search

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// uses returns n posts by author, ids start..start+n-1, all with tag, oldest first (inside the first window).
func uses(start int, author string, n int, tag string) []*posts.Post {
	var out []*posts.Post
	for i := 0; i < n; i++ {
		id := start + i
		out = append(out, post(id, author, ago(time.Duration(300-id)*time.Minute), tag))
	}
	return out
}

func TestRefresh_ColdStartThresholdAndPerAuthorCap(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		minAuthors   int
		maxPerAuthor int
		posts        func() []*posts.Post
		want         []TrendItem
	}{
		{"one account, one use trends at the cold-start minimum of 1", 1, 5, func() []*posts.Post {
			return uses(1, "a", 1, "solo")
		}, []TrendItem{{Tag: "solo", Posts: 1, Authors: 1}}},
		{"one account, eight uses count 5 (the per-author cap)", 1, 5, func() []*posts.Post {
			return uses(1, "a", 8, "spam")
		}, []TrendItem{{Tag: "spam", Posts: 5, Authors: 1}}},
		{"a cap of 2 counts 2 of five uses", 1, 2, func() []*posts.Post {
			return uses(1, "a", 5, "capped")
		}, []TrendItem{{Tag: "capped", Posts: 2, Authors: 1}}},
		{"the cap is per author: capped posts add up across authors", 1, 2, func() []*posts.Post {
			return append(uses(1, "a", 5, "shared"), uses(10, "b", 1, "shared")...)
		}, []TrendItem{{Tag: "shared", Posts: 3, Authors: 2}}},
		{"a raised minimum still needs that many accounts", 2, 5, func() []*posts.Post {
			return uses(1, "a", 3, "lonely")
		}, []TrendItem{}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			h := newHarness(t, true, func(c *RefresherConfig) {
				c.MinAuthors = tc.minAuthors
				c.MaxPostsPerAuthor = tc.maxPerAuthor
			})
			h.scan.posts = tc.posts()
			if _, err := h.run(t); err != nil {
				t.Fatalf("run: %v", err)
			}
			got := h.items()
			if len(got) != len(tc.want) {
				t.Fatalf("items = %+v, want %+v", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("items[%d] = %+v, want %+v", i, got[i], tc.want[i])
				}
			}
		})
	}
}

func TestNewRefresher_ColdStartDefaults(t *testing.T) {
	t.Parallel()
	r := NewRefresher(nil, nil, nil, nil, nil, RefresherConfig{})
	if r.cfg.MinAuthors != 1 || r.cfg.MaxPostsPerAuthor != 5 {
		t.Fatalf("defaults = min authors %d, per author %d; want 1 and 5", r.cfg.MinAuthors, r.cfg.MaxPostsPerAuthor)
	}
}

// fakeRecent is the LatestSource: the posts it is given, newest first, at most limit.
type fakeRecent struct {
	posts []*posts.Post
	err   error
	calls int
}

func (f *fakeRecent) Recent(_ context.Context, limit int) ([]*posts.Post, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	var out []*posts.Post
	for _, p := range f.posts {
		if len(out) == limit {
			break
		}
		out = append(out, p)
	}
	return out, nil
}

func TestGetTrends_LatestRow(t *testing.T) {
	t.Parallel()
	repost := func(p *posts.Post) *posts.Post { p.Kind = posts.KindRepost; return p }
	taken := func(p *posts.Post) *posts.Post { p.Moderation = posts.ModerationTakenDown; return p }
	tests := []struct {
		name    string
		posts   []*posts.Post
		protect []string
		absent  []string
		deny    []string
		hidden  []string
		prefix  string
		noList  bool
		srcErr  error
		want    string // "" means no Latest row
	}{
		{"the newest hashtag shows even with no list yet", []*posts.Post{
			post(9, "a", ago(time.Minute), "fresh"),
		}, nil, nil, nil, nil, "", true, nil, "fresh"},
		{"a protected author's newest post is skipped", []*posts.Post{
			post(9, "p", ago(time.Minute), "private"), post(8, "a", ago(2*time.Minute), "older"),
		}, []string{"p"}, nil, nil, nil, "", false, nil, "older"},
		{"a repost is skipped", []*posts.Post{
			repost(post(9, "a", ago(time.Minute), "rp")), post(8, "b", ago(2*time.Minute), "older"),
		}, nil, nil, nil, nil, "", false, nil, "older"},
		{"a taken-down post is skipped", []*posts.Post{
			taken(post(9, "a", ago(time.Minute), "bad")), post(8, "b", ago(2*time.Minute), "older"),
		}, nil, nil, nil, nil, "", false, nil, "older"},
		{"a newest post by an account that is not ACTIVE is skipped", []*posts.Post{
			post(9, "gone", ago(time.Minute), "ghost"), post(8, "a", ago(2*time.Minute), "older"),
		}, nil, []string{"gone"}, nil, nil, "", false, nil, "older"},
		{"a denylisted tag gives way to the next tag of the same post", []*posts.Post{
			post(9, "a", ago(time.Minute), "spam", "fine"),
		}, nil, nil, []string{"spam"}, nil, "", false, nil, "fine"},
		{"a hidden tag (trends/hidden) is skipped", []*posts.Post{
			post(9, "a", ago(time.Minute), "hidden1"), post(8, "b", ago(2*time.Minute), "older"),
		}, nil, nil, nil, []string{"hidden1"}, "", false, nil, "older"},
		{"no post passes gives no row", []*posts.Post{
			repost(post(9, "a", ago(time.Minute), "rp")),
		}, nil, nil, nil, nil, "", false, nil, ""},
		{"a prefix answer leaves the row out", []*posts.Post{
			post(9, "a", ago(time.Minute), "launch"),
		}, nil, nil, nil, nil, "la", false, nil, ""},
		{"a failed scan leaves the row out and the list still serves", []*posts.Post{
			post(9, "a", ago(time.Minute), "x"),
		}, nil, nil, nil, nil, "", false, errors.New("posts down"), ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			clk := &fakeClock{t: trendsT0}
			store := &fakeTrendsStore{doc: sampleDoc(), hidden: tc.hidden}
			if tc.noList {
				store.doc = nil
			}
			src := &fakeRecent{posts: tc.posts, err: tc.srcErr}
			prot := &trendsFakeProtected{set: map[string]bool{}}
			for _, u := range tc.protect {
				prot.set[u] = true
			}
			dir := newFakeAuthors()
			for _, u := range tc.absent {
				dir.absent[u] = true
			}
			reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On}, flags.Spec{Name: FlagSearch, Mode: flags.On})
			svc := New(reg, WithTrends(store, clk.now), WithTrendsDenylist(tc.deny), WithTrendsLatest(src, prot, dir)).(*service)
			got, err := svc.Trends(context.Background(), "u1", 0, tc.prefix)
			if err != nil {
				t.Fatalf("Trends: %v", err)
			}
			switch {
			case tc.want == "" && got.Latest != nil:
				t.Fatalf("Latest = %q, want no row", got.Latest.GetTag())
			case tc.want != "" && (got.Latest == nil || got.Latest.GetTag() != tc.want):
				t.Fatalf("Latest = %v, want %q", got.Latest, tc.want)
			}
			if !tc.noList && tc.prefix == "" && len(got.Trends) == 0 {
				t.Fatalf("Popular is empty: the Latest rule must not drop the list")
			}
		})
	}
}

func TestGetTrends_LatestIsCachedWithTheList(t *testing.T) {
	t.Parallel()
	clk := &fakeClock{t: trendsT0}
	store := &fakeTrendsStore{doc: sampleDoc()}
	src := &fakeRecent{posts: []*posts.Post{post(9, "a", ago(time.Minute), "fresh")}}
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On}, flags.Spec{Name: FlagSearch, Mode: flags.On})
	svc := New(reg, WithTrends(store, clk.now), WithTrendsLatest(src, &trendsFakeProtected{set: map[string]bool{}}, newFakeAuthors())).(*service)
	for range 2 {
		if _, err := svc.Trends(context.Background(), "u1", 0, ""); err != nil {
			t.Fatalf("Trends: %v", err)
		}
	}
	if src.calls != 1 {
		t.Fatalf("scan calls = %d within the TTL, want 1", src.calls)
	}
}
