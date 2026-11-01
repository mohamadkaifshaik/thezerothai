package posts

import (
	"testing"
	"time"

	"connectrpc.com/connect"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W6-36 (ADR-0029 Amendment 1 A1.5, A2.7): viewer_poll_vote_blocked through the converter and the producers, Post.VoteChanged and the cache.

var blockedAuthor = map[string]bool{pvAuthor: true}

func TestToViewAt_PollVoteBlocked(t *testing.T) {
	t.Parallel()
	open, closed := pvOpens.Add(time.Hour), pvOpens.Add(25*time.Hour)
	voted := NewViewerSet(nil, nil).WithPollVotes([]string{pvPostID + ":1"})
	embedded := &Post{ID: pvOtherID, Kind: KindQuote, QuoteOfID: pvPostID, CreatedAt: pvOpens, AuthorID: pvAuthor,
		Embedded: &Embedded{PostID: pvPostID, Author: AuthorSnapshot{UserID: pvAuthor}, Text: "t", CreatedAt: pvOpens, Poll: &EmbeddedPoll{Options: []string{"Yes", "No"}, ClosesAt: pvOpens.Add(24 * time.Hour)}}}
	tests := []struct {
		name        string
		post        *Post
		vs          ViewerSet
		viewer      string
		now         time.Time
		wantBlocked bool
		wantVisible bool
	}{
		{"open poll by a blocked author, never voted: blocked, results stay hidden", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", open, true, false},
		{"voted before the block: blocked, results and check mark kept", pvPoll(7, 3), voted.WithBlockedAuthors(blockedAuthor), "viewer", open, true, true},
		{"closed: not blocked any more, the final results", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", closed, false, true},
		{"closes exactly now: closed", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", pvOpens.Add(24 * time.Hour), false, true},
		{"author not blocked", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(map[string]bool{"someone": true}), "viewer", open, false, false},
		{"no producer set (every older path): false", pvPoll(7, 3), ViewerSet{}, "viewer", open, false, false},
		{"nil blocked set: false", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(nil), "viewer", open, false, false},
		{"the viewer is the author: false", pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(blockedAuthor), pvAuthor, open, false, true},
		{"a post without a poll: false", &Post{ID: pvPostID, AuthorID: pvAuthor, Kind: KindPost, CreatedAt: pvOpens}, ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", open, false, false},
		{"a QUOTE of the poll (frozen embed): false", embedded, ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", open, false, false},
		{"polls globally off: shown results, still flagged", pvPoll(7, 3), ViewerSet{}.WithPollsGloballyOff().WithBlockedAuthors(blockedAuthor), "viewer", open, true, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			v := ToViewAt(tt.post, tt.vs, tt.viewer, tt.now)
			if got := v.GetViewerPollVoteBlocked(); got != tt.wantBlocked {
				t.Fatalf("viewer_poll_vote_blocked = %v, want %v", got, tt.wantBlocked)
			}
			if tt.post.Poll != nil {
				if got := v.GetPost().GetPoll().GetResultsVisible(); got != tt.wantVisible {
					t.Fatalf("results_visible = %v, want %v: the block must not change what a viewer may see of the results", got, tt.wantVisible)
				}
			}
		})
	}
}

// The blocker who never voted sees the same bytes as anyone who has not voted (the counts are zeroed whatever the real ones are).
func TestToViewAt_BlockedNeverVotedStaysHidden(t *testing.T) {
	t.Parallel()
	blocked := ToViewAt(pvPoll(7, 3), ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", pvOpens.Add(time.Hour))
	plain := ToViewAt(pvPoll(7, 3), ViewerSet{}, "viewer", pvOpens.Add(time.Hour))
	if got := pvVotes(blocked.GetPost().GetPoll()); got[0] != 0 || got[1] != 0 || blocked.GetPost().GetPoll().GetTotalVotes() != 10 {
		t.Fatalf("votes = %v total %d, want hidden counts and the real total", got, blocked.GetPost().GetPoll().GetTotalVotes())
	}
	if blocked.GetPost().GetPoll().GetResultsVisible() != plain.GetPost().GetPoll().GetResultsVisible() {
		t.Fatal("a block revealed or hid results")
	}
}

// WithBlockedAuthors returns a copy: the shared ViewerSet of the engagement cache is never changed.
func TestViewerSet_WithBlockedAuthorsIsACopy(t *testing.T) {
	t.Parallel()
	base := NewViewerSet(nil, nil)
	_ = base.WithBlockedAuthors(blockedAuthor)
	if base.PollVoteBlocked(pvPoll(1, 1), "viewer", pvOpens) {
		t.Fatal("the receiver was changed")
	}
}

// BookmarksOnly drops nothing it should keep: the producers set the blocked set after hydration, so it is not part of the hydrated set.
func TestApplyWithheld_ClearsPollVoteBlocked(t *testing.T) {
	t.Parallel()
	v := ToViewAt(pvPoll(2, 2), ViewerSet{}.WithBlockedAuthors(blockedAuthor), "viewer", pvOpens.Add(time.Hour))
	if !v.GetViewerPollVoteBlocked() {
		t.Fatal("setup")
	}
	ApplyWithheld(v)
	if v.GetViewerPollVoteBlocked() || !v.GetWithheld() {
		t.Fatalf("withheld view = %v", v)
	}
}

// D4 guard: every PostView producer that can show a post by an author the viewer blocks is handled, and no list-surface producer sets the
// field. A producer that renders through ToView without WithBlockedAuthors yields false (the safe default); this pins the contract.
func TestPollVoteBlocked_ProducerContract(t *testing.T) {
	t.Parallel()
	for _, surface := range []Surface{SurfaceList, SurfaceOwnList} {
		// Audience.Decide drops a blocked author's row on list surfaces (audience.go), so they never reach a PostView with the field.
		a := NewSnapshotAudience(nil)
		d, err := a.Decide(t.Context(), "viewer", graph.Snapshot{Blocked: blockedAuthor}, &Post{ID: pvPostID, AuthorID: pvAuthor, Kind: KindPost}, surface)
		if err != nil || d.Verdict == Show {
			t.Fatalf("surface %v: verdict %v err %v, want the row dropped", surface, d.Verdict, err)
		}
	}
	a := NewSnapshotAudience(nil)
	d, err := a.Decide(t.Context(), "viewer", graph.Snapshot{Blocked: blockedAuthor}, &Post{ID: pvPostID, AuthorID: pvAuthor, Kind: KindPost}, SurfaceDirect)
	if err != nil || d.Verdict != Show {
		t.Fatalf("direct surface: verdict %v err %v, want Show (ADR-0010 D6: a blocked author's post is visible by id)", d.Verdict, err)
	}
}

// GetPost and GetThread set the field from the snapshot the service already holds.
func TestServer_PollVoteBlocked_GetPostAndThread(t *testing.T) {
	t.Parallel()
	open := time.Now().Add(48 * time.Hour)
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: RepliesFlagName, Mode: flags.On},
		flags.Spec{Name: EngagementFlagName, Mode: flags.On}, flags.Spec{Name: PollsFlagName, Mode: flags.On})
	t.Run("GetPost", func(t *testing.T) {
		t.Parallel()
		for _, tt := range []struct {
			name    string
			blocked bool
			voted   bool
			closed  bool
			want    bool
			visible bool
		}{
			{"blocked, not voted", true, false, false, true, false},
			{"blocked, voted", true, true, false, true, true},
			{"not blocked", false, false, false, false, false},
			{"blocked, closed", true, false, true, false, true},
		} {
			t.Run(tt.name, func(t *testing.T) {
				e := newDeleteEnv()
				closes := open
				if tt.closed {
					closes = time.Now().Add(-time.Hour)
				}
				e.repo.docs[pidOther].Poll = &Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: closes, Counts: []int64{4, 5}, Total: 9}
				if tt.blocked {
					e.graph.snap = graph.Snapshot{Blocked: map[string]bool{otherUID: true}}
				}
				var votes []string
				if tt.voted {
					votes = []string{pidOther + ":1"}
				}
				srv := NewServer(e.svc, reg, WithViewerFlags(&countingViewer{set: NewViewerSet(nil, nil).WithPollVotes(votes)}))
				got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
				if err != nil {
					t.Fatal(err)
				}
				v := got.Msg.GetPost()
				if v.GetViewerPollVoteBlocked() != tt.want || v.GetPost().GetPoll().GetResultsVisible() != tt.visible {
					t.Fatalf("blocked=%v visible=%v, want %v/%v", v.GetViewerPollVoteBlocked(), v.GetPost().GetPoll().GetResultsVisible(), tt.want, tt.visible)
				}
			})
		}
	})
	t.Run("GetPost of the viewer's own poll reads no snapshot for the hint", func(t *testing.T) {
		t.Parallel()
		e := newDeleteEnv()
		e.repo.docs[pidMine].Poll = &Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: open, Counts: []int64{4, 5}, Total: 9}
		e.graph.snap = graph.Snapshot{Blocked: map[string]bool{testUID: true}}
		before := e.graph.calls
		srv := NewServer(e.svc, reg, WithViewerFlags(&countingViewer{set: ViewerSet{}}))
		got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidMine}))
		if err != nil || got.Msg.GetPost().GetViewerPollVoteBlocked() {
			t.Fatalf("err %v blocked %v, want false for the author", err, got.Msg.GetPost().GetViewerPollVoteBlocked())
		}
		if e.graph.calls != before {
			t.Errorf("graph snapshots = %d, want no extra call for the hint", e.graph.calls-before)
		}
	})
	t.Run("GetThread focal", func(t *testing.T) {
		t.Parallel()
		e := newThreadEnv()
		e.repo.docs[rRoot].Poll = &Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: open, Counts: []int64{9, 1}, Total: 10}
		e.graph.snap = graph.Snapshot{Blocked: map[string]bool{uZed: true, uBlocked: true}, Muted: map[string]bool{uMuted: true}}
		srv := NewServer(e.svc, reg, WithViewerFlags(&countingViewer{set: ViewerSet{}}))
		resp, err := srv.GetThread(callerCtx(testUID), connect.NewRequest(&postsv1.GetThreadRequest{PostId: rRoot}))
		if err != nil {
			t.Fatal(err)
		}
		f := resp.Msg.GetFocal()
		if !f.GetViewerPollVoteBlocked() || f.GetPost().GetPoll().GetResultsVisible() {
			t.Fatalf("blocked=%v visible=%v, want blocked and hidden results", f.GetViewerPollVoteBlocked(), f.GetPost().GetPoll().GetResultsVisible())
		}
	})
}

func TestPost_VoteChanged(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		from, to int
		counts   []int64
		want     []int64
		same     bool
	}{
		{"moves one vote, total fixed", 0, 2, []int64{5, 2, 0}, []int64{4, 2, 1}, false},
		{"clamps a count at 0", 2, 1, []int64{5, 2, 0}, []int64{5, 3, 0}, false},
		{"same choice is the post itself", 1, 1, []int64{5, 2, 0}, nil, true},
		{"from out of range", 3, 1, []int64{5, 2, 0}, nil, true},
		{"to out of range", 0, 3, []int64{5, 2, 0}, nil, true},
		{"negative", -1, 1, []int64{5, 2, 0}, nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			p := &Post{ID: pvPostID, Kind: KindPost, Poll: &Poll{Options: []string{"a", "b", "c"}, Counts: tt.counts, Total: 7}}
			got := p.VoteChanged(tt.from, tt.to)
			if tt.same {
				if got != p {
					t.Fatal("want the post itself")
				}
				return
			}
			if got == p || got.Poll == p.Poll || got.Poll.Total != 7 {
				t.Fatalf("want a copy with total 7, got %+v", got.Poll)
			}
			for i, w := range tt.want {
				if got.Poll.Counts[i] != w {
					t.Errorf("counts = %v, want %v", got.Poll.Counts, tt.want)
					break
				}
			}
			if p.Poll.Counts[0] != tt.counts[0] {
				t.Error("the cached poll was changed in place")
			}
		})
	}
	var nilPost *Post
	if nilPost.VoteChanged(0, 1) != nil || (&Post{}).VoteChanged(0, 1) == nil {
		t.Error("nil and poll-less posts are returned as they are")
	}
}

func TestCache_AdjustPollChange(t *testing.T) {
	t.Parallel()
	c := NewCache(time.Minute, 10, 10)
	p := &Post{ID: pvPostID, Kind: KindPost, Poll: &Poll{Options: []string{"a", "b"}, Counts: []int64{3, 1}, Total: 4}}
	if c.AdjustPollChange(pvPostID, 0, 1) != nil {
		t.Fatal("a post that is not cached returns nil")
	}
	c.SetPost(p)
	got := c.AdjustPollChange(pvPostID, 0, 1)
	if got == nil || got.Poll.Counts[0] != 2 || got.Poll.Counts[1] != 2 || got.Poll.Total != 4 {
		t.Fatalf("after change = %+v", got)
	}
	// Composes with a vote on the same instance.
	got = c.AdjustPoll(pvPostID, 0)
	if got.Poll.Counts[0] != 3 || got.Poll.Total != 5 {
		t.Fatalf("vote after change = %+v", got.Poll)
	}
	if p.Poll.Counts[0] != 3 || p.Poll.Counts[1] != 1 {
		t.Fatal("the stored post was changed in place")
	}
}
