package timeline

import (
	"context"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
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

// W6-36 (ADR-0029 Amendment 1 A1.5): the author's profile timeline carries viewer_poll_vote_blocked for a viewer who blocks that author (the posts
// are shown by ADR-0010 D6), and Home never does (a blocked author's rows are dropped there). 0 extra reads: the snapshot checkVisible read.
func TestUserTimeline_PollVoteBlocked(t *testing.T) {
	t.Parallel()
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "engagement", Mode: flags.On}, flags.Spec{Name: "polls", Mode: flags.On})
	tests := []struct {
		name    string
		blocked bool
		voted   bool
		closed  bool
		want    bool
		visible bool
	}{
		{"blocked, never voted: blocked, results hidden", true, false, false, true, false},
		{"blocked after voting: blocked, results kept", true, true, false, true, true},
		{"not blocked", false, false, false, false, false},
		{"blocked, closed poll", true, false, true, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r := newRig(t)
			ps := r.seedUser("author", 1)
			closes := time.Now().Add(48 * time.Hour)
			if tt.closed {
				closes = time.Now().Add(-48 * time.Hour)
			}
			ps[0].Poll = &posts.Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: closes, Counts: []int64{8, 2}, Total: 10}
			if tt.blocked {
				r.graph.snaps["me"] = graph.Snapshot{Blocked: following("author")}
			}
			var votes []string
			if tt.voted {
				votes = []string{ps[0].ID + ":1"}
			}
			r.srv = NewServer(Deps{Flags: reg, Viewer: voteViewer{votes}, Posts: r.posts, Graph: r.graph, Directory: r.dir,
				CursorKey: testKey, TokenTTL: 720 * time.Hour, SettleWindow: 15 * time.Second, Now: r.clock.Now})
			views := r.mustUser("me", "author", false, "", "", 20).GetPosts()
			if len(views) != 1 {
				t.Fatalf("rows = %d, want the blocked author's post shown", len(views))
			}
			if views[0].GetViewerPollVoteBlocked() != tt.want || views[0].GetPost().GetPoll().GetResultsVisible() != tt.visible {
				t.Fatalf("blocked=%v visible=%v, want %v/%v", views[0].GetViewerPollVoteBlocked(), views[0].GetPost().GetPoll().GetResultsVisible(), tt.want, tt.visible)
			}
		})
	}
	t.Run("Home drops a blocked author's rows, so the field is never set there", func(t *testing.T) {
		t.Parallel()
		r := newRig(t)
		r.follow("me", 1)
		snap := r.graph.snaps["me"]
		snap.Blocked = following("f1")
		r.graph.snaps["me"] = snap
		r.posts.add("f1", r.ms(-3*time.Second)).Poll = &posts.Poll{Options: []string{"A", "B"}, ClosesAt: time.Now().Add(time.Hour), Counts: []int64{1, 1}, Total: 2}
		for _, v := range r.mustHome("", "", 20).GetPosts() {
			if v.GetViewerPollVoteBlocked() {
				t.Fatal("Home carried viewer_poll_vote_blocked")
			}
		}
	})
}
