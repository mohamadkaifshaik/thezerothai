package timeline

import (
	"errors"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
)

// withPublicViews installs a view rule (threshold 1000) for one test; the cleanup leaves the rule off. Not parallel:
// the rule is process-wide.
func withPublicViews(t *testing.T) {
	t.Helper()
	posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1000})
	t.Cleanup(func() { posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1, Off: func() bool { return true }}) })
}

// TestViewCountFailsClosedOnSetOutage: a follower's page of an author's posts is served while the protected set is
// unknown (a followed author never needs the set), but the author's protected state is unknown, so no view_count over
// the threshold is shown; with the set known and the author public it is. The author still sees their own.
func TestViewCountFailsClosedOnSetOutage(t *testing.T) {
	withPublicViews(t)
	for _, tc := range []struct {
		name   string
		setErr error
		want   bool
	}{
		{"set unavailable", errors.New("set unavailable"), false},
		{"set known, author public", nil, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, fp := protectedRig(t)
			pPost(r, 5).ViewCount = 5000
			fp.err = tc.setErr
			r.graph.snaps["fan"] = graph.Snapshot{Following: following("P")}
			resp, err := r.user("fan", "P", false, "", "", 20)
			if err != nil || len(resp.GetPosts()) != 1 {
				t.Fatalf("follower page: %v %v", resp, err)
			}
			if vc := resp.GetPosts()[0].GetPost().ViewCount; (vc != nil) != tc.want {
				t.Fatalf("view_count = %v, want shown=%v", vc, tc.want)
			}
			own, err := r.user("P", "P", false, "", "", 20)
			if err != nil || len(own.GetPosts()) != 1 || own.GetPosts()[0].GetPost().GetViewCount() != 5000 {
				t.Fatalf("author's own page: %v %v", own, err)
			}
		})
	}
}
