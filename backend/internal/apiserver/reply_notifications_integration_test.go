//go:build integration

package apiserver

// Reply notifications (ADR-0017 T10) over the real Build chain with the inline emitter: a reply writes
// users/{parentAuthor}/notifications/reply_{replyId}; replying to yourself, a recipient that muted the replier and
// a repeated idempotent create write nothing extra; a reply that also @mentions the parent author yields ONE row
// (the reply row; the mention is folded into it). The budget assertion is the logged fs_reads/fs_writes of the
// reply's request line, which must not grow because notifications are on (the producer reads nothing: the parent
// author comes from the parent the reply validation already loaded).

import (
	"context"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/iterator"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

const rpcCreatePost = "/dzeroth.posts.v1.PostService/CreatePost"

func replyNotifsOn(c *config.Config) {
	relaxLimits(c)
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	c.FeatureNotifications = flags.Spec{Name: "notifications", Mode: flags.On}
}

// notifIDs lists the notification doc ids of uid (Limit 20: a test account never has more).
func notifIDs(t *testing.T, c *firestore.Client, uid string) []string {
	t.Helper()
	it := c.Collection("users/" + uid + "/notifications").Limit(20).Documents(context.Background())
	defer it.Stop()
	var out []string
	for {
		d, err := it.Next()
		if err == iterator.Done {
			return out
		}
		if err != nil {
			t.Fatalf("list notifications: %v", err)
		}
		out = append(out, d.Ref.ID)
	}
}

func waitForDoc(t *testing.T, c *firestore.Client, path string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !fsDocExists(t, c, path) {
		if time.Now().After(deadline) {
			t.Fatalf("%s never appeared", path)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestReplyNotifications(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, replyNotifsOn)
	a, b, c := e.newUser(t), e.newUser(t), e.newUser(t)
	aHandle, _ := e.profileOf(t, a)

	post := func(u testUser, key, text, replyTo string) string {
		t.Helper()
		r, err := e.posts.CreatePost(ctx, authed(u.token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: text, ReplyToPostId: replyTo}))
		if err != nil {
			t.Fatalf("CreatePost(%s): %v", key, err)
		}
		return r.Msg.GetPost().GetPost().GetPostId()
	}
	root := post(a, "rn-root-key-000000001", "root post", "")

	// 1. b replies to a: one reply row for a. Budget: the reply's own request line is unchanged by notifications
	// (5 writes: idempotency, post, postsCount, quotas, parent replyCount; reads within the plan ceiling of 15).
	r1 := post(b, "rn-reply-key-00000001", "first reply", root)
	waitForDoc(t, e.fs, "users/"+a.uid+"/notifications/reply_"+r1)
	if reads, writes := e.lastLine(t, rpcCreatePost); reads > 15 || writes != 5 {
		t.Errorf("reply CreatePost: reads=%v writes=%v, want reads <= 15 and writes 5 (notifications add none)", reads, writes)
	}
	snap, err := e.fs.Doc("users/" + a.uid + "/notifications/reply_" + r1).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if typ, _ := snap.DataAt("type"); typ != "reply" {
		t.Errorf("type = %v, want reply", typ)
	}

	// 2. Replaying the same create is a no-op: no second row, no new write on the request line.
	if again := post(b, "rn-reply-key-00000001", "first reply", root); again != r1 {
		t.Fatalf("replay returned %s, want %s", again, r1)
	}
	if _, writes := e.lastLine(t, rpcCreatePost); writes != 0 {
		t.Errorf("replay writes = %v, want 0", writes)
	}

	// 3. a replying to a's own post, and a reply when the recipient muted the replier: no rows.
	self := post(a, "rn-self-key-000000001", "talking to myself", root)
	if _, err := e.graph.Mute(ctx, authed(a.token, &graphv1.MuteRequest{IdempotencyKey: "rn-mute-key-0000000001", UserId: c.uid})); err != nil {
		t.Fatalf("Mute: %v", err)
	}
	muted := post(c, "rn-muted-key-00000001", "muted reply", root)

	// 4. A reply that also @mentions the parent author: ONE row, the reply row (reply beats mention).
	both := post(b, "rn-both-key-000000001", "@"+aHandle+" agreed", root)
	waitForDoc(t, e.fs, "users/"+a.uid+"/notifications/reply_"+both)

	// A later reply as a sentinel: once it is delivered the earlier, concurrent deliveries have settled too.
	last := post(b, "rn-last-key-000000001", "sentinel", root)
	waitForDoc(t, e.fs, "users/"+a.uid+"/notifications/reply_"+last)
	time.Sleep(200 * time.Millisecond)

	got := map[string]bool{}
	for _, id := range notifIDs(t, e.fs, a.uid) {
		got[id] = true
	}
	for _, want := range []string{"reply_" + r1, "reply_" + both, "reply_" + last} {
		if !got[want] {
			t.Errorf("missing %s; have %v", want, got)
		}
	}
	for _, bad := range []string{"reply_" + self, "reply_" + muted, "mention_" + both, "mention_" + self, "mention_" + muted} {
		if got[bad] {
			t.Errorf("unexpected %s", bad)
		}
	}
	if len(got) != 3 {
		t.Errorf("rows for the parent author = %v, want exactly the 3 reply rows", got)
	}
}
