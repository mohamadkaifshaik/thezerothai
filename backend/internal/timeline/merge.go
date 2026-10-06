package timeline

import (
	"sort"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// Source is one chunk query result, or a pseudo-chunk built from author-recent cache entries, fed to Merge.
// Posts are newest first by (createdAt, postId).
type Source struct {
	Posts []*posts.Post
	// Filled is true when the source may hold more posts below its last item: a chunk query that returned
	// exactly its limit k, or a truncated cache entry (ADR-0010 D15).
	Filled bool
}

// Page is the result of Merge.
type Page struct {
	// Items is the page after filtering and the limit cut, newest first.
	Items []*posts.Post
	// Newest is the newest examined post (before filtering), nil when nothing was examined. The settle
	// watermark (D13) uses it as "newest returned".
	Newest *posts.Position
	// Last is where the next page resumes (strictly below it). Valid when HasMore.
	Last posts.Position
	// HasMore is true when older posts may exist below Last inside the window: the exact-prefix bound B exists
	// (some source may have more), or the limit cut dropped kept items. On a refresh it means the result does not
	// reach the old `since`, so the caller issues a gap token.
	HasMore bool
	// Filtered counts examined posts dropped by keep.
	Filtered int
}

// Compare orders positions in the descending post order: negative when a is newer than b (sorts first),
// positive when a is older, 0 when equal. Post ids are fixed-width decimal Snowflakes (ADR-0010 D18), so the
// string comparison is the numeric one.
func Compare(a, b posts.Position) int {
	switch {
	case a.CreatedAt.After(b.CreatedAt):
		return -1
	case a.CreatedAt.Before(b.CreatedAt):
		return 1
	case a.ID > b.ID:
		return -1
	case a.ID < b.ID:
		return 1
	}
	return 0
}

// PositionOf is p's position.
func PositionOf(p *posts.Post) posts.Position {
	return posts.Position{CreatedAt: p.CreatedAt, ID: p.ID}
}

// Merge implements ADR-0004 decision 3, the exact-prefix merge. It merges all sources by (createdAt, postId)
// descending, drops duplicates, and keeps only items at or after B, the newest "last item" of any Filled
// source (those sources may hold more below their last item, so nothing below B is known to be complete). The
// prefix is then filtered by keep (nil keeps everything) and cut to limit. B's source contributes its whole
// result, so a Filled source guarantees a non-empty prefix.
//
// Merge is pure: successive calls with Window{Before: Last} are a strict descending prefix of the true merge,
// with no duplicates or gaps (property-tested).
func Merge(sources []Source, limit int, keep func(*posts.Post) bool) Page {
	if limit < 1 {
		limit = 1
	}
	var all []*posts.Post
	var bound *posts.Position
	for _, s := range sources {
		all = append(all, s.Posts...)
		if !s.Filled || len(s.Posts) == 0 {
			continue
		}
		last := PositionOf(s.Posts[0])
		for _, p := range s.Posts[1:] {
			if pos := PositionOf(p); Compare(pos, last) > 0 {
				last = pos
			}
		}
		if bound == nil || Compare(last, *bound) < 0 {
			b := last
			bound = &b
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return Compare(PositionOf(all[i]), PositionOf(all[j])) < 0 })

	var prefix []*posts.Post
	for _, p := range all {
		if len(prefix) > 0 && prefix[len(prefix)-1].ID == p.ID {
			continue
		}
		if bound != nil && Compare(PositionOf(p), *bound) > 0 {
			break
		}
		prefix = append(prefix, p)
	}
	if len(prefix) == 0 {
		return Page{}
	}
	newest := PositionOf(prefix[0])
	out := Page{Newest: &newest}
	kept := prefix
	if keep != nil {
		kept = make([]*posts.Post, 0, len(prefix))
		for _, p := range prefix {
			if keep(p) {
				kept = append(kept, p)
			}
		}
		out.Filtered = len(prefix) - len(kept)
	}
	if len(kept) > limit {
		out.Items = kept[:limit]
		out.Last = PositionOf(kept[limit-1])
		out.HasMore = true
		return out
	}
	out.Items = kept
	out.Last = PositionOf(prefix[len(prefix)-1])
	out.HasMore = bound != nil
	return out
}
