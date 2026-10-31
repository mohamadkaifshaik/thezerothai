package posts

import (
	"bytes"
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W6-6 (ADR-0029 D3, D4): per-viewer redaction of a poll and the viewer's choice. The clock is passed to ToViewAt, so the
// tests do not depend on the real date.

const (
	pvPostID  = "1700000000000000001"
	pvOtherID = "1700000000000000002"
	pvAuthor  = "author"
)

var pvOpens = time.Date(2030, 1, 1, 12, 0, 0, 0, time.UTC) // createdAt; closes a day later

func pvPoll(counts ...int64) *Post {
	var total int64
	for _, c := range counts {
		total += c
	}
	return &Post{ID: pvPostID, AuthorID: pvAuthor, Kind: KindPost, Text: "Which?", CreatedAt: pvOpens,
		Poll: &Poll{Options: []string{"Yes", "No", "Maybe"}[:len(counts)], DurationMin: 1440, ClosesAt: pvOpens.Add(24 * time.Hour), Counts: counts, Total: total}}
}

func pvVotes(counts *postsv1.Poll) []int64 {
	var out []int64
	for _, c := range counts.GetChoices() {
		out = append(out, c.GetVotes())
	}
	return out
}

func TestToViewAt_PollViewerMatrix(t *testing.T) {
	t.Parallel()
	open := pvOpens.Add(time.Hour)
	closed := pvOpens.Add(25 * time.Hour)
	voted := NewViewerSet(nil, nil).WithPollVotes([]string{pvOtherID + ":0", pvPostID + ":1"})
	engOffEmpty := ViewerSet{} // what HydrateViewer returns for a viewer with engagement and bookmarks off
	tests := []struct {
		name       string
		vs         ViewerSet
		viewer     string
		now        time.Time
		wantVisble bool
		wantVotes  []int64
		wantChoice int32
	}{
		{"not voted, open: hidden", engOffEmpty, "viewer", open, false, []int64{0, 0}, 0},
		{"anonymous, open: hidden", ViewerSet{}, "", open, false, []int64{0, 0}, 0},
		{"author, open: real", ViewerSet{}, pvAuthor, open, true, []int64{7, 3}, 0},
		{"anyone, closed: real", ViewerSet{}, "viewer", closed, true, []int64{7, 3}, 0},
		{"closes exactly now: closed", ViewerSet{}, "viewer", pvOpens.Add(24 * time.Hour), true, []int64{7, 3}, 0},
		{"voted, open: real and choice", voted, "viewer", open, true, []int64{7, 3}, 2},
		{"voted on another poll only: hidden", NewViewerSet(nil, nil).WithPollVotes([]string{pvOtherID + ":1"}), "viewer", open, false, []int64{0, 0}, 0},
		{"polls globally off: real for all", ViewerSet{}.WithPollsGloballyOff(), "viewer", open, true, []int64{7, 3}, 0},
		{"bookmarks only drops the choice", voted.BookmarksOnly(), "viewer", open, false, []int64{0, 0}, 0},
		{"bookmarks only keeps polls off", voted.WithPollsGloballyOff().BookmarksOnly(), "viewer", open, true, []int64{7, 3}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			p := pvPoll(7, 3)
			v := ToViewAt(p, tt.vs, tt.viewer, tt.now)
			po := v.GetPost().GetPoll()
			if po.GetResultsVisible() != tt.wantVisble || po.GetTotalVotes() != 10 || po.GetClosed() != !tt.now.Before(p.Poll.ClosesAt) {
				t.Fatalf("poll = %v", po)
			}
			if got := pvVotes(po); len(got) != 2 || got[0] != tt.wantVotes[0] || got[1] != tt.wantVotes[1] {
				t.Fatalf("votes = %v, want %v", got, tt.wantVotes)
			}
			if v.GetViewerPollChoice() != tt.wantChoice {
				t.Fatalf("viewer_poll_choice = %d, want %d", v.GetViewerPollChoice(), tt.wantChoice)
			}
			if p.Poll.Counts[0] != 7 || p.Poll.Total != 10 {
				t.Fatalf("the cached poll was changed: %+v", p.Poll)
			}
		})
	}
}

// Hidden counts are byte-identical whatever the real counts are (no result oracle), provided the total is the same.
func TestToView_HiddenPollBytesIgnoreCounts(t *testing.T) {
	t.Parallel()
	open := pvOpens.Add(time.Hour)
	a, b := pvPoll(0, 57), pvPoll(57, 0)
	ba, _ := proto.MarshalOptions{Deterministic: true}.Marshal(ToViewAt(a, ViewerSet{}, "viewer", open))
	bb, _ := proto.MarshalOptions{Deterministic: true}.Marshal(ToViewAt(b, ViewerSet{}, "viewer", open))
	if !bytes.Equal(ba, bb) {
		t.Fatal("hidden poll bytes differ with the real per-choice counts")
	}
	ra, _ := proto.MarshalOptions{Deterministic: true}.Marshal(ToViewAt(a, ViewerSet{}, pvAuthor, open))
	if bytes.Equal(ba, ra) {
		t.Fatal("the author's view equals the hidden one")
	}
}

// A REPOST row of a poll the viewer voted in carries the choice (original id); its embedded poll stays the frozen definition.
func TestToView_RepostRowViewerChoice(t *testing.T) {
	t.Parallel()
	rp := &Post{ID: pvOtherID, AuthorID: "reposter", Kind: KindRepost, RepostOfID: pvPostID, CreatedAt: pvOpens,
		Embedded: &Embedded{PostID: pvPostID, Author: AuthorSnapshot{UserID: pvAuthor}, Text: "Which?", CreatedAt: pvOpens,
			Poll: &EmbeddedPoll{Options: []string{"Yes", "No"}, ClosesAt: pvOpens.Add(24 * time.Hour)}}}
	vs := NewViewerSet(nil, nil).WithPollVotes([]string{pvPostID + ":0"})
	v := ToViewAt(rp, vs, "viewer", pvOpens.Add(time.Hour))
	if v.GetViewerPollChoice() != 1 {
		t.Fatalf("viewer_poll_choice = %d, want 1", v.GetViewerPollChoice())
	}
	if ep := v.GetPost().GetEmbedded().GetPoll(); ep == nil || ep.GetResultsVisible() || ep.GetTotalVotes() != 0 || len(ep.GetChoices()) != 2 {
		t.Fatalf("embedded poll = %v, want the frozen definition", ep)
	}
	// A QUOTE row is its own post: the vote on the quoted original is not its choice.
	q := &Post{ID: pvOtherID, Kind: KindQuote, QuoteOfID: pvPostID, CreatedAt: pvOpens, Embedded: rp.Embedded}
	if got := ToViewAt(q, vs, "viewer", pvOpens).GetViewerPollChoice(); got != 0 {
		t.Fatalf("quote row viewer_poll_choice = %d, want 0", got)
	}
}

func TestViewerSet_WithPollVotes(t *testing.T) {
	t.Parallel()
	base := NewViewerSet([]string{"a"}, nil)
	vs := base.WithPollVotes([]string{"x:3", "bad", ":1", "y:9", "z:-1", "w:q", "v:0"})
	for id, want := range map[string]struct {
		i  int
		ok bool
	}{"x": {3, true}, "v": {0, true}, "y": {0, false}, "z": {0, false}, "w": {0, false}, "bad": {0, false}} {
		if i, ok := vs.PollChoice(&Post{ID: id}); i != want.i || ok != want.ok {
			t.Errorf("%s = %d,%v want %d,%v", id, i, ok, want.i, want.ok)
		}
	}
	if _, ok := base.PollChoice(&Post{ID: "x"}); ok {
		t.Fatal("WithPollVotes changed its receiver")
	}
	if l, _ := vs.Flags(&Post{ID: "a"}); !l {
		t.Fatal("WithPollVotes dropped the liked set")
	}
}

type pvFlags struct {
	on  map[string]bool
	off map[string]bool // globally off
}

func (f pvFlags) Enabled(_, name string) bool  { return f.on[name] }
func (f pvFlags) GloballyOff(name string) bool { return f.off[name] }

type pvViewer struct{ calls int }

func (v *pvViewer) Viewer(context.Context, string) ViewerSet {
	v.calls++
	return NewViewerSetWithBookmarks([]string{"l"}, nil, []string{"b"}).WithPollVotes([]string{pvPostID + ":2"})
}

func TestHydrateViewer_Polls(t *testing.T) {
	t.Parallel()
	p := &Post{ID: pvPostID}
	tests := []struct {
		name       string
		fl         FlagChecker
		wantCalls  int
		wantChoice bool
		wantOff    bool
		wantLiked  bool
	}{
		{"engagement on: choice, no extra call", pvFlags{on: map[string]bool{"engagement": true, "polls": true}}, 1, true, false, true},
		{"engagement off: no read, no choice", pvFlags{on: map[string]bool{"polls": true}}, 0, false, false, false},
		{"bookmarks only: no choice, no like", pvFlags{on: map[string]bool{"bookmarks": true}}, 1, false, false, false},
		{"polls globally off, engagement off: still shows results", pvFlags{off: map[string]bool{"polls": true}}, 0, false, true, false},
		{"polls globally off, bookmarks only", pvFlags{on: map[string]bool{"bookmarks": true}, off: map[string]bool{"polls": true}}, 1, false, true, false},
		{"polls globally off, engagement on", pvFlags{on: map[string]bool{"engagement": true}, off: map[string]bool{"polls": true}}, 1, true, true, true},
		{"polls on for nobody but not off (rollout)", pvFlags{on: map[string]bool{"engagement": true}}, 1, true, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			vf := &pvViewer{}
			vs := HydrateViewer(t.Context(), tt.fl, vf, "u")
			if vf.calls != tt.wantCalls {
				t.Fatalf("Viewer calls = %d, want %d", vf.calls, tt.wantCalls)
			}
			if _, ok := vs.PollChoice(p); ok != tt.wantChoice {
				t.Fatalf("voted = %v, want %v", ok, tt.wantChoice)
			}
			if vs.pollsOff != tt.wantOff {
				t.Fatalf("pollsOff = %v, want %v", vs.pollsOff, tt.wantOff)
			}
			if l, _ := vs.Flags(p); l != false {
				t.Fatal("unexpected liked flag")
			}
			if l, _ := vs.Flags(&Post{ID: "l"}); l != tt.wantLiked {
				t.Fatalf("liked = %v, want %v", l, tt.wantLiked)
			}
		})
	}
	if vs := HydrateViewer(t.Context(), pvFlags{off: map[string]bool{"polls": true}}, nil, "u"); !vs.pollsOff {
		t.Fatal("nil viewer source lost the polls-off mark")
	}
	if vs := HydrateViewer(t.Context(), nil, &pvViewer{}, "u"); vs.pollsOff {
		t.Fatal("nil flags must give the zero set")
	}
}

// ApplyWithheld clears the viewer's poll choice with the rest of the placeholder; a PROTECTED embed loses its poll.
func TestApplyWithheld_ClearsPollChoice(t *testing.T) {
	t.Parallel()
	vs := NewViewerSet(nil, nil).WithPollVotes([]string{pvPostID + ":1"})
	v := ToViewAt(pvPoll(2, 2), vs, "viewer", pvOpens.Add(time.Hour))
	if v.GetViewerPollChoice() != 2 || v.GetPost().GetPoll() == nil {
		t.Fatalf("setup: %v", v)
	}
	ApplyWithheld(v)
	if v.GetViewerPollChoice() != 0 || v.GetPost().GetPoll() != nil || !v.GetWithheld() {
		t.Fatalf("withheld view = %v", v)
	}
}

func TestApplyEmbedState_ProtectedEmbedHasNoPoll(t *testing.T) {
	t.Parallel()
	q := &Post{ID: pvOtherID, Kind: KindQuote, QuoteOfID: pvPostID, CreatedAt: pvOpens,
		Embedded: &Embedded{PostID: pvPostID, Author: AuthorSnapshot{UserID: pvAuthor}, Text: "t", CreatedAt: pvOpens,
			Poll: &EmbeddedPoll{Options: []string{"Yes", "No"}, ClosesAt: pvOpens.Add(time.Hour)}}}
	v := ToViewAt(q, ViewerSet{}, "viewer", pvOpens)
	if v.GetPost().GetEmbedded().GetPoll() == nil {
		t.Fatal("setup: the embed should carry its poll")
	}
	ApplyEmbedState(v, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED)
	if v.GetPost().GetEmbedded().GetPoll() != nil {
		t.Fatal("a PROTECTED embed kept its poll")
	}
}

// GetPost end to end (the handler path GetThread shares via viewerSet and ToView): the same rule through the real
// HydrateViewer, one case per flag mode. The poll closes far in the future, so the real clock reads it as open.
func TestServer_GetPost_PollViewer(t *testing.T) {
	t.Parallel()
	open := time.Now().Add(48 * time.Hour)
	tests := []struct {
		name        string
		flags       pvFlags
		wantCalls   int
		wantVisible bool
		wantChoice  int32
	}{
		{"engagement on, voted", pvFlags{on: map[string]bool{FlagName: true, EngagementFlagName: true}}, 1, true, 2},
		{"engagement off: hidden, no read, no choice", pvFlags{on: map[string]bool{FlagName: true}}, 0, false, 0},
		{"bookmarks only: hidden, no choice", pvFlags{on: map[string]bool{FlagName: true, BookmarksFlagName: true}}, 1, false, 0},
		{"polls globally off, engagement off: results shown", pvFlags{on: map[string]bool{FlagName: true}, off: map[string]bool{PollsFlagName: true}}, 0, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newDeleteEnv()
			e.repo.docs[pidOther].Poll = &Poll{Options: []string{"A", "B", "C"}, DurationMin: 60, ClosesAt: open, Counts: []int64{4, 5, 6}, Total: 15}
			cv := &countingViewer{set: NewViewerSet(nil, nil).WithPollVotes([]string{pidOther + ":1"})}
			srv := NewServer(e.svc, tt.flags, WithViewerFlags(cv))
			got, err := srv.GetPost(callerCtx(testUID), connect.NewRequest(&postsv1.GetPostRequest{PostId: pidOther}))
			if err != nil {
				t.Fatal(err)
			}
			v := got.Msg.GetPost()
			po := v.GetPost().GetPoll()
			if po.GetResultsVisible() != tt.wantVisible || po.GetTotalVotes() != 15 || cv.calls != tt.wantCalls {
				t.Fatalf("visible=%v total=%d calls=%d, want %v/15/%d", po.GetResultsVisible(), po.GetTotalVotes(), cv.calls, tt.wantVisible, tt.wantCalls)
			}
			if wantVotes := po.GetChoices()[1].GetVotes() == 5; wantVotes != tt.wantVisible {
				t.Fatalf("votes = %v, visible = %v", pvVotes(po), tt.wantVisible)
			}
			if v.GetViewerPollChoice() != tt.wantChoice {
				t.Fatalf("viewer_poll_choice = %d, want %d", v.GetViewerPollChoice(), tt.wantChoice)
			}
		})
	}
}

// GetThread uses the same viewer set and converter: a poll on the root as the focal row (real flag registry, so the
// GloballyOff path is the production one).
func TestServer_GetThread_PollViewer(t *testing.T) {
	t.Parallel()
	reg := func(engagement, polls flags.Mode) *flags.Registry {
		return flags.NewRegistry(
			flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: RepliesFlagName, Mode: flags.On},
			flags.Spec{Name: EngagementFlagName, Mode: engagement}, flags.Spec{Name: PollsFlagName, Mode: polls})
	}
	tests := []struct {
		name        string
		fc          *flags.Registry
		votes       []string
		wantVisible bool
		wantChoice  int32
	}{
		{"not voted: hidden", reg(flags.On, flags.On), nil, false, 0},
		{"voted: results and choice", reg(flags.On, flags.On), []string{rRoot + ":0"}, true, 1},
		{"engagement off, polls on (allowlist rollout): hidden", reg(flags.Off, flags.Allowlist), []string{rRoot + ":0"}, false, 0},
		{"engagement off, polls off for everyone: results", reg(flags.Off, flags.Off), nil, true, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			e := newThreadEnv()
			e.repo.docs[rRoot].Poll = &Poll{Options: []string{"A", "B"}, DurationMin: 60, ClosesAt: time.Now().Add(48 * time.Hour), Counts: []int64{9, 1}, Total: 10}
			cv := &countingViewer{set: NewViewerSet(nil, nil).WithPollVotes(tt.votes)}
			srv := NewServer(e.svc, tt.fc, WithViewerFlags(cv))
			resp, err := srv.GetThread(callerCtx(testUID), connect.NewRequest(&postsv1.GetThreadRequest{PostId: rRoot}))
			if err != nil {
				t.Fatal(err)
			}
			f := resp.Msg.GetFocal()
			po := f.GetPost().GetPoll()
			if po == nil || po.GetResultsVisible() != tt.wantVisible || po.GetTotalVotes() != 10 || (po.GetChoices()[0].GetVotes() == 9) != tt.wantVisible {
				t.Fatalf("poll = %v, want visible=%v total 10", po, tt.wantVisible)
			}
			if f.GetViewerPollChoice() != tt.wantChoice {
				t.Fatalf("viewer_poll_choice = %d, want %d", f.GetViewerPollChoice(), tt.wantChoice)
			}
		})
	}
}
