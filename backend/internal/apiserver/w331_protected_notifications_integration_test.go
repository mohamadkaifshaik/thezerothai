//go:build integration

package apiserver

// W3-31 (ADR-0025 D10, AQ5) through the real Build chain with the inline emitter and the real protected-set loader and
// toggle (FEATURE_PRIVATE_ACCOUNTS on): a protected actor P's mention, reply, quote and repost reach a follower of P
// and nobody else. A recipient who does not follow P gets no row, and because the push is sent only by the call that
// created the row, no push either. (The request and accept types are covered in the notifications package; graph does
// not emit them until W3-27 and W3-28a.)

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func w331On(c *config.Config) {
	relaxLimits(c)
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On}
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
	c.FeaturePrivateAccounts = flags.Spec{Name: "private_accounts", Mode: flags.On}
}

func TestW331_ProtectedActorSuppressionThroughTheChain(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, w331On)
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	p, stranger, follower := e.newUser(t), e.newUser(t), e.newUser(t)
	strangerHandle, _ := e.profileOf(t, stranger)
	followerHandle, _ := e.profileOf(t, follower)
	e.follow(t, follower, p)

	post := func(u testUser, key, text string, mut func(*postsv1.CreatePostRequest)) string {
		t.Helper()
		req := &postsv1.CreatePostRequest{IdempotencyKey: key, Text: text}
		if mut != nil {
			mut(req)
		}
		r, err := e.posts.CreatePost(ctx, authed(u.token, req))
		if err != nil {
			t.Fatalf("CreatePost(%s): %v", key, err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	// Targets for P's reply, quote and repost, written by the recipients while P is still public.
	sRoot := post(stranger, "w331-s-root-0000000001", "stranger root", nil)
	fRoot := post(follower, "w331-f-root-0000000001", "follower root", nil)

	prot := true
	if _, err := e.identity.UpdateProfile(ctx, authed(p.token, &identityv1.UpdateProfileRequest{IdempotencyKey: "w331-protect-00000001", IsPrivate: &prot})); err != nil {
		t.Fatalf("protect: %v", err)
	}

	// P acts toward both recipients. The mention post costs the same as without notifications.
	mention := post(p, "w331-mention-00000000001", "hello @"+strangerHandle+" and @"+followerHandle, nil)
	if reads, writes := e.lastLine(t, rpcCreatePost); reads > 14 || writes != 4 {
		t.Errorf("mention CreatePost: reads=%v writes=%v, want reads <= 14 and writes 4 (the fan-out adds none to the request line)", reads, writes)
	}
	replyF := post(p, "w331-reply-f-000000000001", "reply f", func(r *postsv1.CreatePostRequest) { r.ReplyToPostId = fRoot })
	post(p, "w331-reply-s-000000000001", "reply s", func(r *postsv1.CreatePostRequest) { r.ReplyToPostId = sRoot })
	quoteF := post(p, "w331-quote-f-000000000001", "quote f", func(r *postsv1.CreatePostRequest) { r.QuoteOfPostId = fRoot })
	post(p, "w331-quote-s-000000000001", "quote s", func(r *postsv1.CreatePostRequest) { r.QuoteOfPostId = sRoot })
	for _, id := range []string{sRoot, fRoot} {
		if _, err := eng.RepostPost(ctx, authed(p.token, &engagementv1.RepostPostRequest{IdempotencyKey: "w331-repost-" + id[len(id)-8:] + "-padpad", PostId: id})); err != nil {
			t.Fatalf("RepostPost: %v", err)
		}
	}

	// The follower's four rows are the sentinel: once they are all there, the stranger's deliveries have settled too.
	wantF := map[string]bool{"mention_" + mention: false, "reply_" + replyF: false, "quote_" + quoteF: false}
	deadline := time.Now().Add(15 * time.Second)
	for {
		got := map[string]bool{}
		repost := false
		for _, id := range notifIDs(t, e.fs, follower.uid) {
			got[id] = true
			repost = repost || strings.HasPrefix(id, "repost_") && strings.HasSuffix(id, "_"+p.uid)
		}
		done := repost
		for id := range wantF {
			done = done && got[id]
		}
		if done {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("follower rows = %v, want mention, reply, quote and repost rows from P", got)
		}
		time.Sleep(50 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	if ids := notifIDs(t, e.fs, stranger.uid); len(ids) != 0 {
		t.Errorf("a recipient who does not follow the protected actor got rows %v, want none", ids)
	}
}
