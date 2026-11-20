//go:build integration

package apiserver

// CheckPostShare against SendMessage with shared_post_id over the real Build chain on the emulators (plan 2026-11-20 §4):
// for each (caller, post) row the check and a send to a recipient who passes every recipient check (mutual follows, every
// flag on) give the same answer: the same wire bytes (code, message, ErrorDetail) on a refusal, the same resolved post id
// on a success. Fresh users per row, and every answer comes from a COLD chain (a new Build) built after the row's graph or
// moderation change, so no 60 s instance cache makes the rows order-dependent. The protected-set-unreadable case has no
// seam here; the unit table covers it (TestCheckPostShare_ParityWithSendOverPostShareCheck).

import (
	"context"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// newCheckChain is newShareChain with FEATURE_DM_SHARE_CHECK in the given mode and the check's limits relaxed.
func newCheckChain(t *testing.T, dmShare, check flags.Mode) *shareChain {
	t.Helper()
	d := newDMChain(t, func(c *config.Config) {
		sharesOn(dmShare)(c)
		c.FeatureDMShareCheck = flags.Spec{Name: "dm_share_check", Mode: check}
		c.RateLimit.MessagesShareCheckPerUserPerMinute = 1_000_000
		c.RateLimit.MessagesShareChecksPerDay = 1_000_000
	})
	return &shareChain{dmChain: d, eng: engagementv1connect.NewEngagementServiceClient(http.DefaultClient, d.url)}
}

func (e *shareChain) checkShare(u dmUser, postID string) (*messagingv1.CheckPostShareResponse, error) {
	r, err := e.msg.CheckPostShare(context.Background(), authed(u.token, &messagingv1.CheckPostShareRequest{PostId: postID}))
	if err != nil {
		return nil, err
	}
	return r.Msg, nil
}

// approve makes follower an approved follower of the protected account owner.
func (e *shareChain) approve(t *testing.T, owner, follower dmUser) {
	t.Helper()
	e.follow(t, follower, owner)
	if _, err := e.graph.RespondToFollowRequest(context.Background(), authed(owner.token, &graphv1.RespondToFollowRequestRequest{
		IdempotencyKey: contractKey("scp-accept"), RequesterUserId: follower.uid, Accept: true,
	})); err != nil {
		t.Fatalf("approve: %v", err)
	}
}

func (e *shareChain) quote(t *testing.T, u dmUser, of string) string {
	t.Helper()
	q, err := e.posts.CreatePost(context.Background(), authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("scp-q"), Text: "quote", QuoteOfPostId: of}))
	if err != nil {
		t.Fatalf("quote: %v", err)
	}
	return q.Msg.GetPost().GetPost().GetPostId()
}

func (e *shareChain) repost(t *testing.T, u dmUser, of string) string {
	t.Helper()
	r, err := e.eng.RepostPost(context.Background(), authed(u.token, &engagementv1.RepostPostRequest{IdempotencyKey: contractKey("scp-rp"), PostId: of}))
	if err != nil {
		t.Fatalf("repost: %v", err)
	}
	return r.Msg.GetRepostPostId()
}

func TestShareCheckParity_MatchesSendMessage(t *testing.T) {
	ctx := context.Background()
	w := newCheckChain(t, flags.On, flags.On)
	// x is the caller, r the recipient (mutual with x), c an author.
	type world struct{ x, r, c dmUser }
	const (
		okWant        = "ok"        // both succeed with the same id
		notFound      = "not_found" // both NOT_FOUND "post not found"
		protected     = "protected" // both PROTECTED_ACCOUNT
		parityOnly    = ""          // the answer itself is the posts rules'; only parity is asserted
		disabledShare = "dm_post_share"
	)
	tests := []struct {
		name string
		// setup returns who checks and sends (default x) and the post id.
		setup   func(t *testing.T, z world) (dmUser, string)
		dmShare flags.Mode
		want    string
	}{
		{name: "public", want: okWant, setup: func(t *testing.T, z world) (dmUser, string) { return z.x, w.post(t, z.c, "public") }},
		{name: "a REPOST answers its original", want: okWant, setup: func(t *testing.T, z world) (dmUser, string) {
			return z.x, w.repost(t, z.c, w.post(t, z.c, "reposted"))
		}},
		{name: "followers-only author, caller is an approved follower", want: protected, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "protected, followed")
			w.protect(t, z.c)
			w.approve(t, z.c, z.x)
			return z.x, id
		}},
		{name: "followers-only author, caller does not follow", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "protected, not followed")
			w.protect(t, z.c)
			return z.x, id
		}},
		{name: "own protected post", want: okWant, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.x, "my protected post")
			w.protect(t, z.x)
			return z.x, id
		}},
		{name: "repost of a protected original", want: parityOnly, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "protected original")
			rp := w.repost(t, z.c, id)
			w.protect(t, z.c)
			w.approve(t, z.c, z.x)
			return z.x, rp
		}},
		{name: "repost of a repost", want: parityOnly, setup: func(t *testing.T, z world) (dmUser, string) {
			e := w.user(t)
			first := w.repost(t, e, w.post(t, z.c, "original"))
			return z.x, w.repost(t, z.c, first)
		}},
		{name: "quote of a protected post", want: parityOnly, setup: func(t *testing.T, z world) (dmUser, string) {
			p := w.user(t)
			q := w.quote(t, z.c, w.post(t, p, "soon protected"))
			w.protect(t, p)
			return z.x, q
		}},
		{name: "deleted post", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "deleted")
			if _, err := w.posts.DeletePost(ctx, authed(z.c.token, &postsv1.DeletePostRequest{IdempotencyKey: contractKey("scp-del"), PostId: id})); err != nil {
				t.Fatal(err)
			}
			return z.x, id
		}},
		{name: "taken-down post", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "taken down")
			w.update(t, "posts/"+id, "moderation", "TAKEN_DOWN")
			return z.x, id
		}},
		{name: "suspended author", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "suspended author")
			w.update(t, "users/"+z.c.uid, "status", "SUSPENDED")
			return z.x, id
		}},
		{name: "caller blocks the author", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "blocked by the caller")
			w.graphOp(t, "block", z.x, z.c)
			return z.x, id
		}},
		{name: "author blocks the caller", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			id := w.post(t, z.c, "the author blocks the caller")
			w.graphOp(t, "block", z.c, z.x)
			return z.x, id
		}},
		{name: "caller blocks a QUOTE's embedded author", want: notFound, setup: func(t *testing.T, z world) (dmUser, string) {
			e := w.user(t)
			q := w.quote(t, z.c, w.post(t, e, "quoted"))
			w.graphOp(t, "block", z.x, e)
			return z.x, q
		}},
		{name: "dm_post_share off", dmShare: flags.Off, want: disabledShare, setup: func(t *testing.T, z world) (dmUser, string) {
			return z.x, w.post(t, z.c, "flag off")
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			z := world{x: w.user(t), r: w.user(t), c: w.user(t)}
			w.mutual(t, z.x, z.r)
			caller, id := tt.setup(t, z)
			mode := tt.dmShare
			if mode == "" {
				mode = flags.On
			}
			cold := newCheckChain(t, mode, flags.On)
			resp, cerr := cold.checkShare(caller, id)
			sent, serr := cold.sendPost(caller, z.r, contractKey("scp-send"), "https://dzeroth.app/post/"+id, id)
			if (cerr == nil) != (serr == nil) {
				t.Fatalf("check = %v, send = %v; want the same outcome", cerr, serr)
			}
			if cerr == nil {
				if got, stored := resp.GetSharedPostId(), sent.GetMessage().GetSharedPost().GetPostId(); got == "" || got != stored {
					t.Fatalf("check answered %q, send stored %q; want the same id", got, stored)
				}
				if tt.want != okWant && tt.want != parityOnly {
					t.Fatalf("both passed, want %s", tt.want)
				}
				return
			}
			if got, want := wireBytes(t, cerr), wireBytes(t, serr); got != want {
				t.Fatalf("check bytes %q != send bytes %q", got, want)
			}
			switch tt.want {
			case okWant:
				t.Fatalf("both refused (%v), want both to pass", cerr)
			case notFound:
				wantReason(t, cerr, connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "", "")
			case protected:
				wantReason(t, cerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT, "", "")
			case disabledShare:
				wantReason(t, cerr, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", disabledShare)
			}
		})
	}

	t.Run("dm_share_check off refuses the check only", func(t *testing.T) {
		x, r, c := w.user(t), w.user(t), w.user(t)
		w.mutual(t, x, r)
		id := w.post(t, c, "check flag off")
		off := newCheckChain(t, flags.On, flags.Off)
		_, err := off.checkShare(x, id)
		wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "dm_share_check")
		if _, err := off.sendPost(x, r, contractKey("scp-off"), "x", id); err != nil {
			t.Fatalf("the send does not need dm_share_check: %v", err)
		}
	})
}
