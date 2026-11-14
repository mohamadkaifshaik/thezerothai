package engagement

import (
	"context"
	"testing"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// setLoader is a protected-set loader for the real posts.Audience: set, or err when the set is unknown.
type setLoader struct {
	set setOf
	err error
}

func (l setLoader) Current(context.Context) (identity.ProtectedSet, error) {
	if l.err != nil {
		return nil, l.err
	}
	return l.set, nil
}

// TestLists_ViewCountFailsClosedOnSetOutage: a bookmarked or liked post by a followed author is listed while the
// protected set is unknown (a followed author never needs the set), but the author's protected state is unknown, so
// no view_count over the threshold is shown; with the set known and the author public it is. Not parallel: the view
// rule is process-wide.
func TestLists_ViewCountFailsClosedOnSetOutage(t *testing.T) {
	posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1000})
	t.Cleanup(func() { posts.SetViewCountRule(posts.ViewCountRule{Threshold: 1, Off: func() bool { return true }}) })
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "bookmarks", Mode: flags.On},
		flags.Spec{Name: LikesListFlagName, Mode: flags.On})
	for _, tc := range []struct {
		name   string
		loader setLoader
		want   bool
	}{
		{"set unavailable", setLoader{err: identity.ErrProtectedSetUnavailable}, false},
		{"set known, author public", setLoader{set: setOf{}}, true},
	} {
		for _, list := range []string{"bookmarks", "likes"} {
			t.Run(list+"/"+tc.name, func(t *testing.T) {
				e := newListEnv(t, func(d *Deps) { d.Audience = posts.NewSnapshotAudience(tc.loader) })
				e.gr.snap = graph.Snapshot{Following: map[string]bool{"a": true}}
				id := pid(7)
				e.rd.docs[id] = &posts.Post{ID: id, AuthorID: "a", Kind: posts.KindPost, Visibility: posts.VisibilityPublic, ViewCount: 5000}
				srv := NewServer(&stubSvc{}, reg, WithBookmarks(e.m), WithLikesList(e.m))
				var rows []*postsv1.PostView
				if list == "bookmarks" {
					e.bm.rows = []ExportedBookmark{{PostID: id, BookmarkedAt: e.now}}
					resp, err := srv.ListBookmarks(uidCtx(caller), connect.NewRequest(&engagementv1.ListBookmarksRequest{}))
					if err != nil {
						t.Fatal(err)
					}
					for _, b := range resp.Msg.GetBookmarks() {
						rows = append(rows, b.GetPost())
					}
				} else {
					e.repo.loaded = UserLikes{Recent: []string{id}}
					resp, err := srv.ListLikedPosts(uidCtx(caller), connect.NewRequest(&engagementv1.ListLikedPostsRequest{}))
					if err != nil {
						t.Fatal(err)
					}
					rows = resp.Msg.GetPosts()
				}
				if len(rows) != 1 || rows[0].GetWithheld() {
					t.Fatalf("rows = %v, want the one full row", rows)
				}
				if vc := rows[0].GetPost().ViewCount; (vc != nil) != tc.want {
					t.Fatalf("view_count = %v, want shown=%v", vc, tc.want)
				}
			})
		}
	}
}
