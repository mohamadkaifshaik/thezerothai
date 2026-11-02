package engagement

import (
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W5-26b (ADR-0031 D5): the page the list services hand to the handlers carries the polls-style "communities globally off" mark from
// posts.HydrateViewer, so posts.ToView (the one converter) drops the label for the kill switch and for a hidden post, and shows it otherwise.
func TestLists_CommunityLabel(t *testing.T) {
	label := &posts.CommunityLabel{ID: "1000000000000000042", Name: "Go"}
	tests := []struct {
		name   string
		mode   flags.Mode
		hidden bool
		want   bool
	}{
		{"community post", flags.On, false, true},
		{"hidden", flags.On, true, false},
		{"communities globally off", flags.Off, false, false},
	}
	for _, tt := range tests {
		reg := func() *flags.Registry {
			return flags.NewRegistry(flags.Spec{Name: "engagement", Mode: flags.On}, flags.Spec{Name: "communities", Mode: tt.mode})
		}
		mark := func(docs map[string]*posts.Post) {
			for _, p := range docs {
				p.CommunityID, p.Community, p.CommunityHidden = label.ID, label, tt.hidden
			}
		}
		t.Run("ListBookmarks/"+tt.name, func(t *testing.T) {
			e := newListEnv(t, func(d *Deps) { d.Flags = reg() })
			e.seed(2)
			e.repo.loaded = UserLikes{Bookmarks: []string{pid(2), pid(1)}}
			mark(e.rd.docs)
			page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
			if err != nil || len(page.Rows) != 2 {
				t.Fatalf("rows %d, err %v", len(page.Rows), err)
			}
			for _, r := range page.Rows {
				if got := posts.ToView(r.Post, page.Viewer, caller).GetPost().GetCommunity() != nil; got != tt.want {
					t.Fatalf("label present = %v, want %v", got, tt.want)
				}
			}
		})
		t.Run("ListLikedPosts/"+tt.name, func(t *testing.T) {
			e := newListEnv(t, func(d *Deps) { d.Flags = reg() })
			e.seedLikes(2)
			mark(e.rd.docs)
			page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
			if err != nil || len(page.Posts) != 2 {
				t.Fatalf("rows %d, err %v", len(page.Posts), err)
			}
			for _, p := range page.Posts {
				if got := posts.ToView(p, page.Viewer, caller).GetPost().GetCommunity() != nil; got != tt.want {
					t.Fatalf("label present = %v, want %v", got, tt.want)
				}
			}
		})
	}
}
