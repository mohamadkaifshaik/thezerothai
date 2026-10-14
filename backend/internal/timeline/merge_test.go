package timeline

import (
	"fmt"
	"math/rand"
	"sort"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

func mk(id int64, ms int64) *posts.Post {
	return &posts.Post{ID: pid(id), AuthorID: "a", CreatedAt: time.UnixMilli(ms).UTC()}
}

func idsOf(ps []*posts.Post) []string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = p.ID
	}
	return out
}

func sortDesc(ps []*posts.Post) {
	sort.Slice(ps, func(i, j int) bool { return Compare(PositionOf(ps[i]), PositionOf(ps[j])) < 0 })
}

func TestMerge_Table(t *testing.T) {
	t.Parallel()
	a := []*posts.Post{mk(9, 90), mk(7, 70), mk(5, 50)}
	b := []*posts.Post{mk(8, 80), mk(6, 60), mk(1, 10)}
	tests := []struct {
		name     string
		sources  []Source
		limit    int
		keep     func(*posts.Post) bool
		want     []string
		wantMore bool
		wantLast string
		filtered int
	}{
		{name: "empty", limit: 5},
		{name: "no source filled returns everything", sources: []Source{{Posts: a}, {Posts: b}}, limit: 10,
			want: idsOf(append(append([]*posts.Post{}, a[0], b[0], a[1], b[1], a[2]), b[2])), wantLast: pid(1)},
		{name: "filled source bounds the prefix at B", sources: []Source{{Posts: a, Filled: true}, {Posts: b}}, limit: 10,
			want: []string{pid(9), pid(8), pid(7), pid(6), pid(5)}, wantMore: true, wantLast: pid(5)},
		{name: "newest last item wins when several are filled", sources: []Source{{Posts: a, Filled: true}, {Posts: b, Filled: true}}, limit: 10,
			want: []string{pid(9), pid(8), pid(7), pid(6), pid(5)}, wantMore: true, wantLast: pid(5)},
		{name: "limit cut", sources: []Source{{Posts: a}, {Posts: b}}, limit: 2,
			want: []string{pid(9), pid(8)}, wantMore: true, wantLast: pid(8)},
		{name: "exactly limit and exhausted has no more", sources: []Source{{Posts: a}}, limit: 3,
			want: []string{pid(9), pid(7), pid(5)}, wantLast: pid(5)},
		{name: "duplicates across sources collapse", sources: []Source{{Posts: a}, {Posts: a}}, limit: 10,
			want: []string{pid(9), pid(7), pid(5)}, wantLast: pid(5)},
		{name: "filter drops but resume point is the last examined", sources: []Source{{Posts: a, Filled: true}}, limit: 10,
			keep: func(p *posts.Post) bool { return p.ID != pid(5) }, want: []string{pid(9), pid(7)}, wantMore: true, wantLast: pid(5), filtered: 1},
		{name: "filled source with every item filtered still resumes", sources: []Source{{Posts: a, Filled: true}}, limit: 10,
			keep: func(*posts.Post) bool { return false }, wantMore: true, wantLast: pid(5), filtered: 3},
		{name: "ties on createdAt order by id desc", sources: []Source{{Posts: []*posts.Post{mk(2, 50)}}, {Posts: []*posts.Post{mk(3, 50)}}}, limit: 10,
			want: []string{pid(3), pid(2)}, wantLast: pid(2)},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := Merge(tc.sources, tc.limit, tc.keep)
			gotIDs := idsOf(got.Items)
			if fmt.Sprint(gotIDs) != fmt.Sprint(tc.want) && (len(gotIDs) != 0 || len(tc.want) != 0) {
				t.Fatalf("items = %v, want %v", gotIDs, tc.want)
			}
			if got.HasMore != tc.wantMore {
				t.Fatalf("HasMore = %v, want %v", got.HasMore, tc.wantMore)
			}
			if tc.wantLast != "" && got.Last.ID != tc.wantLast {
				t.Fatalf("Last = %s, want %s", got.Last.ID, tc.wantLast)
			}
			if got.Filtered != tc.filtered {
				t.Fatalf("Filtered = %d, want %d", got.Filtered, tc.filtered)
			}
		})
	}
}

// simulate runs the home read loop over fixed chunks the way service.go does: per page, each chunk is queried
// with k and the page window, merged, and the next page resumes below Last (until !HasMore). after, when set,
// is a gap/since lower bound.
func simulate(chunks [][]*posts.Post, limit int, after *posts.Position, keep func(*posts.Post) bool) (out []*posts.Post, pages int) {
	k := min(max((2*limit+len(chunks)-1)/len(chunks), 1), posts.MaxLimit)
	var before *posts.Position
	for {
		pages++
		w := posts.Window{Before: before, After: after}
		var srcs []Source
		for _, c := range chunks {
			var hit []*posts.Post
			for _, p := range c {
				if inWin(p, w) {
					hit = append(hit, p)
				}
			}
			sortDesc(hit)
			if len(hit) > k {
				hit = hit[:k]
			}
			srcs = append(srcs, Source{Posts: hit, Filled: len(hit) >= k})
		}
		pg := Merge(srcs, limit, keep)
		out = append(out, pg.Items...)
		if !pg.HasMore || pages > 100000 {
			return out, pages
		}
		last := pg.Last
		before = &last
	}
}

// TestMerge_PagesAreAStrictPrefixOfTheTrueMerge is the ADR-0004 handoff property: over adversarial chunk
// distributions (one chunk with 1,000 recent posts, sparse others, many ties on createdAt) successive pages
// concatenate to exactly the true descending merge, no duplicates and no gaps.
func TestMerge_PagesAreAStrictPrefixOfTheTrueMerge(t *testing.T) {
	t.Parallel()
	rng := rand.New(rand.NewSource(11))
	for iter := 0; iter < 60; iter++ {
		nChunks := 1 + rng.Intn(6)
		chunks := make([][]*posts.Post, nChunks)
		var all []*posts.Post
		nextID := int64(1)
		dense := false
		for c := range chunks {
			n := rng.Intn(40)
			if rng.Intn(5) == 0 {
				n, dense = 1000, true // dense chunk
			}
			if rng.Intn(4) == 0 {
				n = 0
			}
			msRange := int64(1 + rng.Intn(500)) // small range => many ties on createdAt
			for i := 0; i < n; i++ {
				p := &posts.Post{ID: pid(nextID), AuthorID: fmt.Sprint(c), CreatedAt: time.UnixMilli(1000 + rng.Int63n(msRange)).UTC()}
				nextID++
				chunks[c] = append(chunks[c], p)
				all = append(all, p)
			}
		}
		sortDesc(all)
		limit := 1 + rng.Intn(50)
		if dense {
			limit = 25 + rng.Intn(26) // keeps the walk at tens of pages, not thousands
		}
		got, _ := simulate(chunks, limit, nil, nil)
		if fmt.Sprint(idsOf(got)) != fmt.Sprint(idsOf(all)) {
			t.Fatalf("iter %d (chunks=%d limit=%d): merged pages differ from the true merge (%d vs %d items)", iter, nChunks, limit, len(got), len(all))
		}
	}
}

// TestMerge_GapPagesNeverReachTheOldSince: with a lower bound every page stays strictly above it and the walk
// ends with exactly the posts above the bound.
func TestMerge_GapPagesNeverReachTheOldSince(t *testing.T) {
	t.Parallel()
	rng := rand.New(rand.NewSource(5))
	for iter := 0; iter < 60; iter++ {
		chunks := make([][]*posts.Post, 1+rng.Intn(5))
		var all []*posts.Post
		id := int64(1)
		for c := range chunks {
			for i, n := 0, rng.Intn(80); i < n; i++ {
				p := &posts.Post{ID: pid(id), CreatedAt: time.UnixMilli(1000 + rng.Int63n(200)).UTC()}
				id++
				chunks[c] = append(chunks[c], p)
				all = append(all, p)
			}
		}
		sortDesc(all)
		since := posts.Position{CreatedAt: time.UnixMilli(1000 + rng.Int63n(200)).UTC(), ID: pid(rng.Int63n(id + 1))}
		var want []*posts.Post
		for _, p := range all {
			if Compare(PositionOf(p), since) < 0 {
				want = append(want, p)
			}
		}
		got, _ := simulate(chunks, 1+rng.Intn(50), &since, nil)
		if fmt.Sprint(idsOf(got)) != fmt.Sprint(idsOf(want)) {
			t.Fatalf("iter %d: gap walk differs: got %d items, want %d", iter, len(got), len(want))
		}
		for _, p := range got {
			if Compare(PositionOf(p), since) >= 0 {
				t.Fatalf("iter %d: item %s at or below the old since", iter, p.ID)
			}
		}
	}
}

// TestMerge_FilteredWalkMatchesFilteredTrueMerge: filtering never loses or duplicates the kept items.
func TestMerge_FilteredWalkMatchesFilteredTrueMerge(t *testing.T) {
	t.Parallel()
	rng := rand.New(rand.NewSource(3))
	keep := func(p *posts.Post) bool { return p.ID[len(p.ID)-1]%3 != 0 }
	for iter := 0; iter < 100; iter++ {
		chunks := make([][]*posts.Post, 1+rng.Intn(4))
		var all []*posts.Post
		id := int64(1)
		for c := range chunks {
			for i, n := 0, rng.Intn(60); i < n; i++ {
				p := &posts.Post{ID: pid(id), CreatedAt: time.UnixMilli(1000 + rng.Int63n(100)).UTC()}
				id++
				chunks[c] = append(chunks[c], p)
				if keep(p) {
					all = append(all, p)
				}
			}
		}
		sortDesc(all)
		got, _ := simulate(chunks, 1+rng.Intn(30), nil, keep)
		if fmt.Sprint(idsOf(got)) != fmt.Sprint(idsOf(all)) {
			t.Fatalf("iter %d: filtered walk differs", iter)
		}
	}
}

func BenchmarkTimelineMerge(b *testing.B) {
	var srcs []Source
	id := int64(1)
	for c := 0; c < 167; c++ {
		var ps []*posts.Post
		for i := 0; i < 2; i++ {
			ps = append(ps, &posts.Post{ID: pid(id), CreatedAt: time.UnixMilli(1000 + id).UTC()})
			id++
		}
		sortDesc(ps)
		srcs = append(srcs, Source{Posts: ps, Filled: true})
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Merge(srcs, 50, nil)
	}
}

func TestIsPublic_FailsClosed(t *testing.T) {
	t.Parallel()
	for v, want := range map[posts.Visibility]bool{
		posts.VisibilityPublic:    true,
		posts.VisibilityFollowers: false,
		"":                        false,
	} {
		if got := isPublic(&posts.Post{Visibility: v}); got != want {
			t.Errorf("isPublic(%q) = %v, want %v", v, got, want)
		}
	}
	// ADR-0016: a post a moderator hid is dropped even though it is PUBLIC (takedown and suspension).
	for _, hidden := range []*posts.Post{
		{Visibility: posts.VisibilityPublic, Moderation: "TAKEN_DOWN"},
		{Visibility: posts.VisibilityPublic, Moderation: "SUSPENDED_AUTHOR"},
	} {
		if isPublic(hidden) {
			t.Errorf("isPublic kept a %s post", hidden.Moderation)
		}
	}
	p := mk(9, 90)
	p.Visibility = posts.VisibilityFollowers
	if page := Merge([]Source{{Posts: []*posts.Post{p, mkPublic(8, 80)}}}, 10, isPublic); len(page.Items) != 1 {
		t.Errorf("Merge kept %d posts, want only the public one", len(page.Items))
	}
}

func mkPublic(id int64, ts int64) *posts.Post {
	p := mk(id, ts)
	p.Visibility = posts.VisibilityPublic
	return p
}
