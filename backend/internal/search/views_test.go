package search

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// TestViewCountFailsClosedOnSetOutage: a search row by a followed author is served while the protected set is unknown
// (a followed author never needs the set), but the author's protected state is unknown, so no view_count over the
// threshold is shown; with the set known and the author public it is. Not parallel: the view rule is process-wide.
func TestViewCountFailsClosedOnSetOutage(t *testing.T) {
	posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1000})
	t.Cleanup(func() { posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1, Off: func() bool { return true }}) })
	for _, tc := range []struct {
		name string
		f    fakeProtected
		want bool
	}{
		{"set unavailable", fakeProtected{err: identity.ErrProtectedSetUnavailable}, false},
		{"set known, author public", fakeProtected{set: protectedSet{}}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(map[string][]*posts.Post{"go": {mkPost(1, "x", func(p *posts.Post) { p.ViewCount = 5000 })}},
				withProtected(tc.f), withSnap(func(s *graph.Snapshot) { s.Following["x"] = true }))
			resp := doPosts(t, r, "u", "go", latest, 0, "")
			if len(resp.GetPosts()) != 1 {
				t.Fatalf("posts = %v", resp.GetPosts())
			}
			if vc := resp.GetPosts()[0].GetPost().ViewCount; (vc != nil) != tc.want {
				t.Fatalf("view_count = %v, want shown=%v", vc, tc.want)
			}
		})
	}
}
