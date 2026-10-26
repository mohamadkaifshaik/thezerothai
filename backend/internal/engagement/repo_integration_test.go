//go:build integration

package engagement

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

type countersStub struct{ client *firestore.Client }

func (c countersStub) AddPostsCount(b store.Batch, uid string, delta int64) {
	b.Update(c.client.Doc("users/"+uid), []firestore.Update{{Path: "postsCount", Value: firestore.Increment(delta)}})
}
func (countersStub) AddFollowingCount(store.Batch, string, int64) {}
func (countersStub) AddFollowersCount(store.Batch, string, int64) {}
func (countersStub) AddCounts(store.Batch, string, int64, int64)  {}

type repoEnv struct {
	client *firestore.Client
	repo   *FirestoreRepo
	posts  *posts.FirestoreRepo
}

func newRepoEnv(t *testing.T) *repoEnv {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	client, err := firestore.NewClient(context.Background(), fmt.Sprintf("demo-test-%d", rand.Int64()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	pr := posts.NewFirestoreRepo(client)
	repo := NewFirestoreRepo(client, WriteDeps{Quotas: quota.New(client), Writer: pr, Counters: countersStub{client}, IDs: node, Idempotency: idempotency.New(client)})
	return &repoEnv{client: client, repo: repo, posts: pr}
}

func (e *repoEnv) seedPost(t *testing.T, id, author string, likes, reposts int64) {
	t.Helper()
	_, err := e.client.Collection("posts").Doc(id).Set(context.Background(), map[string]any{
		"authorId": author, "kind": "POST", "text": "t", "likeCount": likes, "repostCount": reposts,
		"createdAt": time.UnixMilli(1_700_000_000_000).UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
}

func (e *repoEnv) exists(t *testing.T, path string) bool {
	t.Helper()
	_, err := e.client.Doc(path).Get(context.Background())
	return err == nil
}

func (e *repoEnv) intField(t *testing.T, path, field string) int64 {
	t.Helper()
	s, err := e.client.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, _ := s.DataAt(field)
	n, _ := v.(int64)
	return n
}

// release: the original exists (count -1 and ArrayRemove in one batch) and the original is gone (NotFound on the
// counter retried with the userLikes part alone).
func TestRelease_NotFoundFallback(t *testing.T) {
	e := newRepoEnv(t)
	ctx, c := budget.WithCounter(context.Background())
	const orig, gone, uid = "0000000000000000011", "0000000000000000012", "u1"
	e.seedPost(t, orig, "author", 0, 3)
	if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"recentReposts": []string{orig, gone}}); err != nil {
		t.Fatal(err)
	}

	if err := e.repo.release(ctx, orig, uid); err != nil {
		t.Fatalf("release: %v", err)
	}
	if got := e.intField(t, "posts/"+orig, "repostCount"); got != 2 {
		t.Errorf("repostCount = %d, want 2", got)
	}
	if err := e.repo.release(ctx, gone, uid); err != nil {
		t.Fatalf("release of a gone original must fall back to the userLikes part: %v", err)
	}
	s, _ := e.client.Doc("userLikes/" + uid).Get(ctx)
	if v, _ := s.DataAt("recentReposts"); fmt.Sprint(v) != "[]" {
		t.Errorf("recentReposts = %v, want both ids removed", v)
	}
	if c.Writes() < 3 {
		t.Errorf("writes = %d, want >= 3 (counter + userLikes, then userLikes alone)", c.Writes())
	}
	// An unconfigured repo reports the misconfiguration instead of panicking.
	if err := NewFirestoreRepo(e.client, WriteDeps{}).release(ctx, orig, uid); err == nil {
		t.Error("release on an unconfigured repo must fail")
	}
}

// The like/unlike/repost/undo cycle on the emulator, including the original being deleted in between.
func TestRepo_LikeRepostCycle(t *testing.T) {
	e := newRepoEnv(t)
	ctx := context.Background()
	const pid, uid = "0000000000000000021", "u2"
	e.seedPost(t, pid, "author", 0, 0)
	if _, err := e.client.Doc("users/"+uid).Set(ctx, map[string]any{"postsCount": int64(0)}); err != nil {
		t.Fatal(err)
	}

	if replay, err := e.repo.Like(ctx, LikeParams{UID: uid, PostID: pid, QuotaLimit: 10}); err != nil || replay {
		t.Fatalf("Like: replay=%v err=%v", replay, err)
	}
	if replay, err := e.repo.Like(ctx, LikeParams{UID: uid, PostID: pid, QuotaLimit: 10}); err != nil || !replay {
		t.Fatalf("Like again: replay=%v err=%v", replay, err)
	}
	if got := e.intField(t, "posts/"+pid, "likeCount"); got != 1 {
		t.Fatalf("likeCount = %d, want 1", got)
	}
	res, err := e.repo.Repost(ctx, RepostParams{UID: uid, Original: &posts.Post{ID: pid, AuthorID: "author"}, QuotaLimit: 10,
		Author: posts.AuthorSnapshot{UserID: uid, Handle: "h"}})
	if err != nil || res.Post == nil {
		t.Fatalf("Repost: %+v %v", res, err)
	}
	if got := e.intField(t, "users/"+uid, "postsCount"); got != 1 {
		t.Fatalf("postsCount = %d, want 1", got)
	}
	// The original is deleted: undo must still remove the REPOST and the reposts doc (counter dropped, NotFound).
	if _, err := e.client.Doc("posts/" + pid).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	u, err := e.repo.UndoRepost(ctx, uid, pid)
	if err != nil || !u.Removed || u.RepostPostID != res.Post.ID {
		t.Fatalf("UndoRepost with the original gone: %+v %v", u, err)
	}
	if e.exists(t, "posts/"+res.Post.ID) || e.exists(t, "reposts/"+pid+"_"+uid) {
		t.Error("undo left the REPOST or its reposts doc")
	}
	// A like of a post that vanished is ErrPostGone; unlike of a gone post is a no-op.
	if _, err := e.repo.Like(ctx, LikeParams{UID: "u3", PostID: pid, QuotaLimit: 10}); !errors.Is(err, ErrPostGone) {
		t.Errorf("Like of a deleted post = %v, want ErrPostGone", err)
	}
	if removed, err := e.repo.Unlike(ctx, "u3", pid); err != nil || removed {
		t.Errorf("Unlike of nothing: removed=%v err=%v", removed, err)
	}
}

// PurgeUser: likes of a deleted post fall back to one batch per doc; counters of live posts stay exact; the
// userLikes doc goes last. ExportUser then lists nothing for the user.
func TestPurgeUser_FallbackAndExport(t *testing.T) {
	e := newRepoEnv(t)
	ctx, _ := budget.WithCounter(context.Background())
	const live, dead, uid = "0000000000000000031", "0000000000000000032", "u4"
	e.seedPost(t, live, "author", 1, 0)
	e.seedPost(t, dead, "author", 1, 0)
	for _, p := range []string{live, dead} {
		if _, err := e.client.Doc("likes/"+p+"_"+uid).Set(ctx, map[string]any{"postId": p, "uid": uid, "createdAt": time.Now().UTC()}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.client.Doc("reposts/"+live+"_"+uid).Set(ctx, map[string]any{
		"postId": live, "uid": uid, "repostPostId": "x", "createdAt": time.Now().UTC(),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Doc("userLikes/"+uid).Set(ctx, map[string]any{"recent": []string{live, dead}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.client.Doc("posts/" + dead).Delete(ctx); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if err := e.repo.ExportUser(ctx, uid, &buf); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Likes   []map[string]any `json:"likes"`
		Reposts []map[string]any `json:"reposts"`
	}
	if err := json.Unmarshal(buf.Bytes(), &out); err != nil || len(out.Likes) != 2 || len(out.Reposts) != 1 {
		t.Fatalf("export = %s, err %v", buf.String(), err)
	}

	cp, done := Checkpoint{}, false
	for i := 0; !done; i++ {
		var err error
		if cp, done, err = e.repo.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
		if i > 6 {
			t.Fatal("purge did not finish")
		}
	}
	if cp.Deleted != 3 {
		t.Errorf("deleted = %d, want 3 (2 likes + 1 repost)", cp.Deleted)
	}
	if got := e.intField(t, "posts/"+live, "likeCount"); got != 0 {
		t.Errorf("live post likeCount = %d, want 0", got)
	}
	for _, p := range []string{"likes/" + live + "_" + uid, "likes/" + dead + "_" + uid, "reposts/" + live + "_" + uid, "userLikes/" + uid} {
		if e.exists(t, p) {
			t.Errorf("%s survived", p)
		}
	}
	// A cancelled context stops the per-doc fallback instead of committing on.
	cctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := e.repo.PurgeUser(cctx, uid, Checkpoint{}); err == nil {
		t.Error("PurgeUser with a cancelled context must fail, not report done")
	}
}

type stubGone struct{}

func (stubGone) PostGone(context.Context, string) (bool, error) { return true, nil }

type stubPub struct{ n int }

func (p *stubPub) Publish(context.Context, []byte) error { p.n++; return nil }

// noProgressCleanup reports a full page that removed nothing, for both clean-up kinds.
type noProgressCleanup struct{ removeCalls, quoteCalls int }

func (n *noProgressCleanup) RemoveReposts(context.Context, string, bool, int) (int, bool, error) {
	n.removeCalls++
	return 0, true, nil
}

func (n *noProgressCleanup) TombstoneQuotes(context.Context, string, int) (int, bool, error) {
	n.quoteCalls++
	return 0, true, nil
}

// A full page that makes no progress ends its step (logged at Error) instead of looping or re-publishing forever.
func TestJobs_NoProgressGuard(t *testing.T) {
	e := newRepoEnv(t)
	cl := &noProgressCleanup{}
	pub := &stubPub{}
	j := NewJobs(e.repo, cl, stubGone{}, pub)
	msg, _ := json.Marshal(map[string]any{"kind": JobKindPostDelete, "uid": "u5", "postId": "0000000000000000041"})
	outcome, err := j.Handle(context.Background(), msg)
	if err != nil || outcome != "done" {
		t.Fatalf("outcome=%q err=%v, want done", outcome, err)
	}
	if cl.removeCalls != 1 || cl.quoteCalls != 1 || pub.n != 0 {
		t.Errorf("remove=%d quote=%d republished=%d, want one call per step and no continuation", cl.removeCalls, cl.quoteCalls, pub.n)
	}
}

// ADR-0018 "Rule 4" (plan T13) on the emulator: a RepostPost replay while the repost exists writes nothing,
// reads the reposts doc once more and returns the same REPOST id; a Like replayed after an Unlike re-likes.
func TestRepo_Rule4Replays(t *testing.T) {
	e := newRepoEnv(t)
	const pid, uid = "0000000000000000031", "u4"
	e.seedPost(t, pid, "author", 0, 0)
	if _, err := e.client.Doc("users/"+uid).Set(context.Background(), map[string]any{"postsCount": int64(0)}); err != nil {
		t.Fatal(err)
	}
	params := RepostParams{UID: uid, Original: &posts.Post{ID: pid, AuthorID: "author"}, QuotaLimit: 10,
		Author: posts.AuthorSnapshot{UserID: uid, Handle: "h"}}

	firstCtx, first := budget.WithCounter(context.Background())
	res, err := e.repo.Repost(firstCtx, params)
	if err != nil || res.Post == nil {
		t.Fatalf("Repost: %+v %v", res, err)
	}
	replayCtx, replay := budget.WithCounter(context.Background())
	again, err := e.repo.Repost(replayCtx, params)
	if err != nil || again.Post != nil || again.ReplayPostID != res.Post.ID {
		t.Fatalf("replay: %+v err=%v, want ReplayPostID %s", again, err, res.Post.ID)
	}
	if replay.Writes() != 0 {
		t.Errorf("replay writes = %d, want 0", replay.Writes())
	}
	if replay.Reads() > first.Reads()+1 {
		t.Errorf("replay reads = %d, want <= first (%d) + 1", replay.Reads(), first.Reads())
	}
	if got := e.intField(t, "posts/"+pid, "repostCount"); got != 1 {
		t.Errorf("repostCount = %d, want 1", got)
	}

	if replayed, err := e.repo.Like(context.Background(), LikeParams{UID: uid, PostID: pid, QuotaLimit: 10}); err != nil || replayed {
		t.Fatalf("Like: replayed=%v err=%v", replayed, err)
	}
	if removed, err := e.repo.Unlike(context.Background(), uid, pid); err != nil || !removed {
		t.Fatalf("Unlike: removed=%v err=%v", removed, err)
	}
	if replayed, err := e.repo.Like(context.Background(), LikeParams{UID: uid, PostID: pid, QuotaLimit: 10}); err != nil || replayed {
		t.Fatalf("Like after Unlike: replayed=%v err=%v, want a fresh like", replayed, err)
	}
	if got := e.intField(t, "posts/"+pid, "likeCount"); got != 1 {
		t.Errorf("likeCount = %d, want 1", got)
	}
}
