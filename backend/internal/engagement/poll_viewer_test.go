package engagement

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// W6-6 (ADR-0029 D3): the userLikes read also returns pollVotes, the cached state keeps them across the like and bookmark
// updates (copy on write), and the ViewerSet resolves a REPOST row to the original's choice.
func TestViewer_PollVotesFromTheSameRead(t *testing.T) {
	e := newEnv(t)
	e.repo.loaded = UserLikes{Recent: []string{pidB}, PollVotes: []string{pidA + ":2", "junk"}}
	vs := e.m.Viewer(e.ctx, "viewer")
	if i, ok := vs.PollChoice(&posts.Post{ID: pidA}); !ok || i != 2 {
		t.Fatalf("choice = %d,%v, want 2,true", i, ok)
	}
	if i, ok := vs.PollChoice(&posts.Post{ID: pidRep, Kind: posts.KindRepost, Embedded: &posts.Embedded{PostID: pidA}}); !ok || i != 2 {
		t.Fatalf("repost row choice = %d,%v, want the original's", i, ok)
	}
	if _, ok := vs.PollChoice(&posts.Post{ID: pidB}); ok {
		t.Fatal("a post with no vote reads as voted")
	}
	_ = e.m.Viewer(e.ctx, "viewer")
	if e.repo.loads != 1 {
		t.Fatalf("loads = %d, want 1: polls add no read", e.repo.loads)
	}
}

func TestUserCache_UpdatesKeepPollVotes(t *testing.T) {
	c := newUserCache(1<<40, 10)
	c.set("u", UserLikes{Recent: []string{"a"}, Bookmarks: []string{"b"}, PollVotes: []string{pidA + ":1"}})
	c.update("u", func(r, p []string) ([]string, []string) { return append(r, "c"), p })
	c.updateBookmarks("u", func(b []string) []string { return append(b, "d") })
	st, _ := c.get("u")
	if i, ok := st.set.PollChoice(&posts.Post{ID: pidA}); !ok || i != 1 || len(st.pollVotes) != 1 {
		t.Fatalf("poll votes lost by a cache update: %+v", st.pollVotes)
	}
}
