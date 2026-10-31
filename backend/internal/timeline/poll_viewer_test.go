package timeline

import (
	"context"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type voteViewer struct{ votes []string }

func (v voteViewer) Viewer(context.Context, string) posts.ViewerSet {
	return posts.ViewerSet{}.WithPollVotes(v.votes)
}

// W6-6: the home and user timelines render a poll through the real registry, HydrateViewer and posts.ToView.
func TestTimelines_PollViewerRule(t *testing.T) {
	t.Parallel()
	reg := func(eng, polls flags.Mode) *flags.Registry {
		return flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "engagement", Mode: eng}, flags.Spec{Name: "polls", Mode: polls})
	}
	future, past := time.Now().Add(48*time.Hour), time.Now().Add(-48*time.Hour)
	tests := []struct {
		name        string
		fc          *flags.Registry
		closes      time.Time
		own         bool // the viewer is the author
		voted       bool
		wantVisible bool
		wantChoice  int32
	}{
		{"not voted", reg(flags.On, flags.On), future, false, false, false, 0},
		{"voted", reg(flags.On, flags.On), future, false, true, true, 2},
		{"author", reg(flags.On, flags.On), future, true, false, true, 0},
		{"closed", reg(flags.On, flags.On), past, false, false, true, 0},
		{"engagement off, voted", reg(flags.Off, flags.On), future, false, true, false, 0},
		{"polls globally off, engagement off", reg(flags.Off, flags.Off), future, false, false, true, 0},
	}
	for _, tt := range tests {
		for _, surface := range []string{"home", "user"} {
			t.Run(surface+"/"+tt.name, func(t *testing.T) {
				t.Parallel()
				r := newRig(t)
				author := "f1"
				if surface == "home" {
					r.follow("me", 1)
				}
				var ps []*posts.Post
				if tt.own {
					author = "me"
					r.dir.profiles["me"] = identity.Profile{UserID: "me", Status: identity.AccountStatusActive}
				}
				if surface == "user" {
					ps = r.seedUser(author, 1)
				} else {
					ps = []*posts.Post{r.posts.add(author, r.ms(-3*time.Second))}
				}
				ps[0].Poll = &posts.Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: tt.closes, Counts: []int64{8, 2}, Total: 10}
				var votes []string
				if tt.voted {
					votes = []string{ps[0].ID + ":1"}
				}
				r.srv = NewServer(Deps{Flags: tt.fc, Viewer: voteViewer{votes}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
					CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now})
				var views []*postsv1.PostView
				if surface == "home" {
					views = r.mustHome("", "", 20).GetPosts()
				} else {
					views = r.mustUser("me", author, false, "", "", 20).GetPosts()
				}
				if len(views) != 1 {
					t.Fatalf("rows = %d", len(views))
				}
				po := views[0].GetPost().GetPoll()
				if po.GetResultsVisible() != tt.wantVisible || po.GetTotalVotes() != 10 || (po.GetChoices()[0].GetVotes() == 8) != tt.wantVisible || views[0].GetViewerPollChoice() != tt.wantChoice {
					t.Fatalf("visible=%v choices=%v choice=%d", po.GetResultsVisible(), po.GetChoices(), views[0].GetViewerPollChoice())
				}
			})
		}
	}
}
