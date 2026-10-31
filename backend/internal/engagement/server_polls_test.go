package engagement

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestVotePoll_FlagMatrix (ADR-0029 D6 step 2, W6-4): FEATURE_POSTS, then FEATURE_ENGAGEMENT on for the caller, then
// FEATURE_POLLS NOT globally off. Every refusal is FEATURE_DISABLED naming the flag, before any Firestore access (the
// stub service has no repo); a caller the gate lets through reaches the skeleton's Unimplemented.
func TestVotePoll_FlagMatrix(t *testing.T) {
	on := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.On} }
	off := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.Off} }
	allow := func(n, uids string) flags.Spec {
		return flags.Spec{Name: n, Mode: flags.Allowlist, Allowlist: map[string]struct{}{uids: {}}}
	}
	pct0 := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.Percent, Percent: 0} }

	tests := []struct {
		name        string
		specs       []flags.Spec
		uid         string
		wantFeature string // "" = passes the gate (Unimplemented)
	}{
		{"all on", []flags.Spec{on("posts"), on("engagement"), on("polls")}, "u", ""},
		{"posts off", []flags.Spec{off("posts"), on("engagement"), on("polls")}, "u", "posts"},
		{"engagement off", []flags.Spec{on("posts"), off("engagement"), on("polls")}, "u", "engagement"},
		{"engagement allowlist, caller outside", []flags.Spec{on("posts"), allow("engagement", "other"), on("polls")}, "u", "engagement"},
		{"polls unset (off)", []flags.Spec{on("posts"), on("engagement")}, "u", "polls"},
		{"polls off", []flags.Spec{on("posts"), on("engagement"), off("polls")}, "u", "polls"},
		{"polls allowlist, caller outside: may vote", []flags.Spec{on("posts"), on("engagement"), allow("polls", "other")}, "u", ""},
		{"polls percent 0: a rollout, not the kill switch", []flags.Spec{on("posts"), on("engagement"), pct0("polls")}, "u", ""},
		{"polls allowlist, caller inside", []flags.Spec{on("posts"), on("engagement"), allow("polls", "u")}, "u", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := NewServer(&stubSvc{}, flags.NewRegistry(tt.specs...))
			_, err := srv.VotePoll(uidCtx(tt.uid), connect.NewRequest(&engagementv1.VotePollRequest{}))
			if tt.wantFeature == "" {
				if connect.CodeOf(err) != connect.CodeUnimplemented || featureDisabledErr(err) != nil {
					t.Fatalf("err = %v, want Unimplemented after the gate", err)
				}
				return
			}
			ae := featureDisabledErr(err)
			if ae == nil {
				t.Fatalf("err = %v, want FEATURE_DISABLED", err)
			}
			// posts off is the whole-service answer without a feature name (posts.GuardFeature).
			if tt.wantFeature != "posts" && ae.Metadata["feature"] != tt.wantFeature {
				t.Errorf("metadata feature = %q, want %q", ae.Metadata["feature"], tt.wantFeature)
			}
		})
	}
}

// stubPolls answers VotePoll with a canned PollVote and records the call.
type stubPolls struct {
	res  PollVote
	err  error
	call string
}

func (s *stubPolls) VotePoll(_ context.Context, uid, key, postID string, choice, expected int32) (PollVote, error) {
	s.call = fmt.Sprintf("%s:%s:%s:%d:%d", uid, key, postID, choice, expected)
	return s.res, s.err
}

// TestVotePoll_Handler: once the gate passes, the handler passes the request to the Polls seam and renders the post through
// posts.ToView with the voter's set (results visible, viewer_poll_choice from the vote), then applies the render hint.
func TestVotePoll_Handler(t *testing.T) {
	reg := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "engagement", Mode: flags.On}, flags.Spec{Name: "polls", Mode: flags.On})
	post := &posts.Post{
		ID: pidA, AuthorID: "author", Kind: posts.KindPost,
		Poll: &posts.Poll{Options: []string{"a", "b"}, ClosesAt: time.Now().Add(time.Hour), Counts: []int64{4, 6}, Total: 10},
	}
	vs := posts.NewViewerSet([]string{pidA}, nil).WithPollVotes([]string{pidA + ":1"})
	t.Run("renders the voter's view", func(t *testing.T) {
		sp := &stubPolls{res: PollVote{Post: post, Viewer: vs}}
		srv := NewServer(&stubSvc{}, reg, WithPolls(sp))
		resp, err := srv.VotePoll(uidCtx("u"), connect.NewRequest(&engagementv1.VotePollRequest{IdempotencyKey: keyOK, PostId: pidA, ChoiceIndex: 1, ExpectedChoice: 2}))
		if err != nil {
			t.Fatal(err)
		}
		if sp.call != "u:"+keyOK+":"+pidA+":1:2" { // expected_choice reaches the seam
			t.Errorf("call = %q", sp.call)
		}
		v := resp.Msg.GetPost()
		po := v.GetPost().GetPoll()
		if !po.GetResultsVisible() || po.GetChoices()[1].GetVotes() != 6 || v.GetViewerPollChoice() != 2 || !v.GetLikedByViewer() {
			t.Fatalf("view = %v", v)
		}
	})
	t.Run("a protected author's view carries the wire visibility hint", func(t *testing.T) {
		sp := &stubPolls{res: PollVote{Post: post, Viewer: vs, Hint: RowHint{Protected: true}}}
		srv := NewServer(&stubSvc{}, reg, WithPolls(sp))
		resp, err := srv.VotePoll(uidCtx("u"), connect.NewRequest(&engagementv1.VotePollRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		if got := resp.Msg.GetPost().GetPost().GetVisibility(); got != postsv1.Visibility_VISIBILITY_FOLLOWERS {
			t.Errorf("visibility = %v, want FOLLOWERS", got)
		}
	})
	t.Run("a service error passes through unchanged", func(t *testing.T) {
		want := connect.NewError(connect.CodeFailedPrecondition, errors.New("x"))
		srv := NewServer(&stubSvc{}, reg, WithPolls(&stubPolls{err: want}))
		if _, err := srv.VotePoll(uidCtx("u"), connect.NewRequest(&engagementv1.VotePollRequest{})); !errors.Is(err, want) {
			t.Fatalf("err = %v, want %v", err, want)
		}
	})
	t.Run("a Service that implements Polls is used without an option", func(t *testing.T) {
		sp := &stubPolls{res: PollVote{Post: post, Viewer: vs}}
		srv := NewServer(struct {
			Service
			Polls
		}{&stubSvc{}, sp}, reg)
		if _, err := srv.VotePoll(uidCtx("u"), connect.NewRequest(&engagementv1.VotePollRequest{})); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("the gate still comes first", func(t *testing.T) {
		off := flags.NewRegistry(flags.Spec{Name: "posts", Mode: flags.On}, flags.Spec{Name: "engagement", Mode: flags.Off}, flags.Spec{Name: "polls", Mode: flags.On})
		sp := &stubPolls{}
		srv := NewServer(&stubSvc{}, off, WithPolls(sp))
		if _, err := srv.VotePoll(uidCtx("u"), connect.NewRequest(&engagementv1.VotePollRequest{})); featureDisabledErr(err) == nil || sp.call != "" {
			t.Fatalf("err = %v call = %q, want FEATURE_DISABLED before the service", err, sp.call)
		}
	})
}
