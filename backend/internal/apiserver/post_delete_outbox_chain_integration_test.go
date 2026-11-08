//go:build integration

package apiserver

// The durable post_delete job over the real Build chain (Firestore, Auth, Pub/Sub emulators): DeletePost's inline
// publish is lost, the outbox item staged in the delete batch survives, the cron sweep republishes it, and delivering
// the job removes the post's media documents. A second sweep publishes nothing (idempotent), and a redelivery is a
// harmless duplicate.

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
)

// lostPublish is a PostDeleteJobs whose publish always fails (the inline attempt only).
type lostPublish struct{ calls atomic.Int32 }

func (l *lostPublish) PostDeleted(context.Context, string, string, []string) error {
	l.calls.Add(1)
	return errors.New("pubsub unavailable")
}

// atomicClock is a clock the test advances while the server reads it from other goroutines.
type atomicClock struct{ ns atomic.Int64 }

func (c *atomicClock) now() time.Time          { return time.Unix(0, c.ns.Load()).UTC() }
func (c *atomicClock) advance(d time.Duration) { c.ns.Add(int64(d)) }

func (e *lifecycleEnv) cron(t *testing.T, path string) int {
	t.Helper()
	resp, err := http.Post(e.url+path, "application/json", nil)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

func TestPostDeleteOutbox_LostPublishIsSweptAndDelivered(t *testing.T) {
	ctx := context.Background()
	clock := &atomicClock{}
	clock.ns.Store(time.Now().UnixNano())
	lost := &lostPublish{}
	e := newLifecycleEnvCfg(t, nil, mediaOn,
		func(o *buildOpts) { o.outboxNow = clock.now },
		func(o *buildOpts) {
			o.inlinePostDeleteJobs = func(posts.PostDeleteJobs) posts.PostDeleteJobs { return lost }
		})
	a := e.newUser(t)
	m1, m2 := e.seedMedia(t, a.uid, media.PurposePost), e.seedMedia(t, a.uid, media.PurposePost)

	resp, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{
		IdempotencyKey: "outbox-post-key-00001", Text: "two pictures", MediaIds: []string{m1, m2},
	}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	postID := resp.Msg.GetPost().GetPost().GetPostId()
	itemPath := outbox.Collection + "/" + posts.PostDeleteOutboxKind + ":" + postID

	e.pull(t) // drain
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "outbox-del-key-000001", PostId: postID})); err != nil {
		t.Fatalf("DeletePost: %v (a lost publish must never fail the delete)", err)
	}
	if lost.calls.Load() != 1 {
		t.Fatalf("inline publishes = %d, want 1", lost.calls.Load())
	}
	if msgs := e.pull(t); len(msgs) != 0 {
		t.Fatalf("job messages = %v, want none (the inline publish was lost)", msgs)
	}
	if !fsDocExists(t, e.fs, itemPath) {
		t.Fatal("no outbox item after a delete whose publish failed")
	}

	// Inside the initial delay the sweep leaves it alone (the inline attempt owns that window).
	if code := e.cron(t, "/internal/cron/outbox-sweep"); code != http.StatusNoContent {
		t.Fatalf("early sweep = %d", code)
	}
	if msgs := e.pull(t); len(msgs) != 0 || !fsDocExists(t, e.fs, itemPath) {
		t.Fatalf("early sweep published %v", msgs)
	}

	// Due: the publish-scheduled tick also runs the outbox step and republishes through the real publisher.
	clock.advance(outbox.DefaultInitialDelay)
	if code := e.cron(t, "/internal/cron/publish-scheduled"); code != http.StatusNoContent {
		t.Fatalf("publish-scheduled tick = %d", code)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" || msgs[0]["postId"] != postID || msgs[0]["uid"] != a.uid {
		t.Fatalf("swept job messages = %v", msgs)
	}
	if fsDocExists(t, e.fs, itemPath) {
		t.Fatal("a republished item was not removed")
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	if fsDocExists(t, e.fs, "media/"+m1) || fsDocExists(t, e.fs, "media/"+m2) {
		t.Fatal("the swept post_delete job did not remove the media documents")
	}

	// Idempotent: a second sweep publishes nothing, and a redelivery of the job is a harmless duplicate.
	clock.advance(time.Hour)
	if code := e.cron(t, "/internal/cron/outbox-sweep"); code != http.StatusNoContent {
		t.Fatalf("second sweep = %d", code)
	}
	if msgs := e.pull(t); len(msgs) != 0 {
		t.Fatalf("second sweep published %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery = %d", code)
	}
}

// With a working publisher the item is staged and removed in the same request: nothing is left for a sweep.
func TestPostDeleteOutbox_PublishedDeleteLeavesNoItem(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, mediaOn)
	a := e.newUser(t)
	resp, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "outbox-post-key-00002", Text: "hello"}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	postID := resp.Msg.GetPost().GetPost().GetPostId()
	e.pull(t)
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "outbox-del-key-000002", PostId: postID})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	if msgs := e.pull(t); len(msgs) != 1 {
		t.Fatalf("job messages = %v, want one", msgs)
	}
	if fsDocExists(t, e.fs, outbox.Collection+"/"+posts.PostDeleteOutboxKind+":"+postID) {
		t.Fatal("a published delete left its outbox item")
	}
}
