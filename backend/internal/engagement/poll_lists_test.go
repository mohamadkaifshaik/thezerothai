package engagement

import (
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W6-6: ListBookmarks and ListLikedPosts hydrate the viewer through the real registry and render through posts.ToView, so the
// poll rule (voted / author / closed / polls globally off / engagement off) is the converter's on both lists.
func TestLists_PollViewerRule(t *testing.T) {
	reg := func(eng, polls flags.Mode) posts.FlagChecker {
		return flags.NewRegistry(flags.Spec{Name: "engagement", Mode: eng}, flags.Spec{Name: "bookmarks", Mode: flags.On}, flags.Spec{Name: "polls", Mode: polls})
	}
	future, past := time.Now().Add(48*time.Hour), time.Now().Add(-48*time.Hour)
	tests := []struct {
		name        string
		fc          posts.FlagChecker
		closes      time.Time
		author      string
		votes       []string
		wantVisible bool
		wantChoice  int32
	}{
		{"not voted", reg(flags.On, flags.On), future, "author", nil, false, 0},
		{"voted", reg(flags.On, flags.On), future, "author", []string{pid(1) + ":1"}, true, 2},
		{"author", reg(flags.On, flags.On), future, caller, nil, true, 0},
		{"closed", reg(flags.On, flags.On), past, "author", nil, true, 0},
		{"engagement off, voted: hidden, no choice", reg(flags.Off, flags.On), future, "author", []string{pid(1) + ":1"}, false, 0},
		{"polls globally off, engagement off", reg(flags.Off, flags.Off), future, "author", nil, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setup := func(e *listEnv) {
				e.rd.docs[pid(1)].AuthorID = tt.author
				e.rd.docs[pid(1)].Poll = &posts.Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: tt.closes, Counts: []int64{8, 2}, Total: 10}
			}
			check := func(t *testing.T, p *posts.Post, vs posts.ViewerSet) {
				v := posts.ToView(p, vs, caller)
				po := v.GetPost().GetPoll()
				if po.GetResultsVisible() != tt.wantVisible || po.GetTotalVotes() != 10 || (po.GetChoices()[0].GetVotes() == 8) != tt.wantVisible || v.GetViewerPollChoice() != tt.wantChoice {
					t.Fatalf("visible=%v votes=%v choice=%d, want visible=%v choice=%d", po.GetResultsVisible(), po.GetChoices(), v.GetViewerPollChoice(), tt.wantVisible, tt.wantChoice)
				}
			}
			t.Run("bookmarks", func(t *testing.T) {
				e := newListEnv(t, func(d *Deps) { d.Flags = tt.fc })
				e.seed(1)
				setup(e)
				e.repo.loaded = UserLikes{Bookmarks: []string{pid(1)}, PollVotes: tt.votes}
				page, err := e.m.ListBookmarks(e.ctx, caller, 0, "")
				if err != nil || len(page.Rows) != 1 {
					t.Fatalf("rows %d, %v", len(page.Rows), err)
				}
				check(t, page.Rows[0].Post, page.Viewer)
			})
			t.Run("liked", func(t *testing.T) {
				e := newListEnv(t, func(d *Deps) { d.Flags = tt.fc })
				e.seedLikes(1)
				setup(e)
				e.repo.loaded.PollVotes = tt.votes
				page, err := e.m.ListLikedPosts(e.ctx, caller, 0, "")
				if err != nil || len(page.Posts) != 1 {
					t.Fatalf("rows %d, %v", len(page.Posts), err)
				}
				check(t, page.Posts[0], page.Viewer)
			})
		})
	}
}
