//go:build integration

package apiserver

// P5 over the real Build chain (Firestore, Auth, Pub/Sub emulators): like, repost, quote, viewer flags, the
// post_delete job and FEATURE_ENGAGEMENT off. The budget assertions here are the logged fs_reads / fs_writes of the
// request line, kept in sync with the table in docs/plans/engagement.md.

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func engagementOn(c *config.Config) {
	relaxLimits(c) // 10 concurrent likes from one user and loopback seeding would trip the abuse limits
	c.RateLimit.LikesPerUserPerMinute = 1_000_000
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.On} // quote creation has its own flag (default off)
}

// engagementOnQuotesOff is engagementOn with FEATURE_QUOTES left at its default (off).
func engagementOnQuotesOff(c *config.Config) {
	engagementOn(c)
	c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.Off}
}

const (
	rpcLike     = "/dzeroth.engagement.v1.EngagementService/LikePost"
	rpcUnlike   = "/dzeroth.engagement.v1.EngagementService/UnlikePost"
	rpcRepost   = "/dzeroth.engagement.v1.EngagementService/RepostPost"
	rpcUndoRepo = "/dzeroth.engagement.v1.EngagementService/UndoRepost"
)

// lastLine returns the logged fs_reads and fs_writes of the last request line for rpc.
func (e *lifecycleEnv) lastLine(t *testing.T, rpc string) (reads, writes float64) {
	t.Helper()
	lines := e.requestLinesFor(rpc)
	if len(lines) == 0 {
		t.Fatalf("no request line for %s", rpc)
	}
	l := lines[len(lines)-1]
	reads, _ = l["fs_reads"].(float64)
	writes, _ = l["fs_writes"].(float64)
	return reads, writes
}

func fsInt(t *testing.T, c *firestore.Client, path, field string) int64 {
	t.Helper()
	snap, err := c.Doc(path).Get(context.Background())
	if err != nil {
		t.Fatalf("get %s: %v", path, err)
	}
	v, _ := snap.DataAt(field)
	n, _ := v.(int64)
	return n
}

// countWhere counts documents of collection with field == value (the invariant checker's loader).
func countWhere(t *testing.T, c *firestore.Client, collection, field, value string) int64 {
	t.Helper()
	docs, err := c.Collection(collection).Where(field, "==", value).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatalf("count %s: %v", collection, err)
	}
	return int64(len(docs))
}

// requireEngagementInvariants: likeCount == |likes|, repostCount == |reposts| for the post, and every reposts doc
// has its REPOST post.
func requireEngagementInvariants(t *testing.T, c *firestore.Client, postID string) {
	t.Helper()
	snap, err := c.Collection("posts").Doc(postID).Get(context.Background())
	if err != nil {
		return // the post is gone; its dependants are the job's, asserted by the caller
	}
	d := snap.Data()
	likes, _ := d["likeCount"].(int64)
	reposts, _ := d["repostCount"].(int64)
	if n := countWhere(t, c, "likes", "postId", postID); n != likes {
		t.Errorf("E1: post %s likeCount = %d but %d like docs", postID, likes, n)
	}
	docs, err := c.Collection("reposts").Where("postId", "==", postID).Limit(500).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(docs)) != reposts {
		t.Errorf("E2: post %s repostCount = %d but %d reposts docs", postID, reposts, len(docs))
	}
	for _, r := range docs {
		rid, _ := r.DataAt("repostPostId")
		id, _ := rid.(string)
		if id == "" || !fsDocExists(t, c, "posts/"+id) {
			t.Errorf("E3: reposts/%s points at a missing REPOST post %q", r.Ref.ID, id)
		}
	}
}

func TestEngagementChain_LikeRepostQuoteAndDeleteJob(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, engagementOn)
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a, b, c := e.newUser(t), e.newUser(t), e.newUser(t)

	created, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "eng-create-key-000001", Text: "hello engagement"}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	pid := created.Msg.GetPost().GetPost().GetPostId()

	// Like: first like, then a replay (0 writes, same answer, no second counter).
	r, err := eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: "eng-like-key-0000001", PostId: pid}))
	if err != nil {
		t.Fatalf("LikePost: %v", err)
	}
	if got := r.Msg.GetEngagement(); got.GetLikeCount() != 1 || !got.GetLikedByViewer() || got.GetPostId() != pid {
		t.Fatalf("like result = %v", got)
	}
	reads, writes := e.lastLine(t, rpcLike)
	if reads > 5+1 || writes != 4 {
		t.Errorf("LikePost cold: reads=%v writes=%v, want reads <= 6 (5 + overflow), writes 4", reads, writes)
	}
	r, err = eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: "eng-like-key-0000001", PostId: pid}))
	if err != nil || r.Msg.GetEngagement().GetLikeCount() != 1 || !r.Msg.GetEngagement().GetLikedByViewer() {
		t.Fatalf("replay = %v, %v", r, err)
	}
	if _, writes := e.lastLine(t, rpcLike); writes != 0 {
		t.Errorf("LikePost replay writes = %v, want 0", writes)
	}

	// 10 concurrent likes by one user converge on one like doc.
	var wg sync.WaitGroup
	errs := make([]error, 10)
	for i := range errs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, errs[i] = eng.LikePost(ctx, authed(c.token, &engagementv1.LikePostRequest{IdempotencyKey: fmt.Sprintf("eng-conc-key-%07d", i), PostId: pid}))
		}()
	}
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Errorf("concurrent like %d: %v", i, err)
		}
	}
	if got := fsInt(t, e.fs, "posts/"+pid, "likeCount"); got != 2 {
		t.Errorf("likeCount after b + 10 concurrent likes of c = %d, want 2", got)
	}
	requireEngagementInvariants(t, e.fs, pid)

	// Viewer flags in GetPost and the profile timeline.
	gp, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: pid}))
	if err != nil || !gp.Msg.GetPost().GetLikedByViewer() || gp.Msg.GetPost().GetRepostedByViewer() {
		t.Fatalf("GetPost flags = %v, %v", gp, err)
	}
	ut, err := e.timeline.GetUserTimeline(ctx, authed(b.token, &timelinev1.GetUserTimelineRequest{UserId: a.uid, PageSize: 10}))
	if err != nil || len(ut.Msg.GetPosts()) != 1 || !ut.Msg.GetPosts()[0].GetLikedByViewer() {
		t.Fatalf("GetUserTimeline = %v, %v", ut, err)
	}

	// Repost, replay, then counters.
	rp, err := eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: "eng-repost-key-00001", PostId: pid}))
	if err != nil {
		t.Fatalf("RepostPost: %v", err)
	}
	repostID := rp.Msg.GetRepostPostId()
	if repostID == "" || rp.Msg.GetEngagement().GetRepostCount() != 1 || !rp.Msg.GetEngagement().GetRepostedByViewer() {
		t.Fatalf("repost result = %v", rp.Msg)
	}
	if reads, writes := e.lastLine(t, rpcRepost); reads > 6 || writes != 6 {
		t.Errorf("RepostPost cold: reads=%v writes=%v, want reads <= 6, writes 6", reads, writes)
	}
	rp2, err := eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: "eng-repost-key-00001", PostId: pid}))
	if err != nil || rp2.Msg.GetRepostPostId() != repostID {
		t.Fatalf("repost replay = %v, %v", rp2, err)
	}
	if _, writes := e.lastLine(t, rpcRepost); writes != 0 {
		t.Errorf("RepostPost replay writes = %v, want 0", writes)
	}
	if got := fsInt(t, e.fs, "users/"+b.uid, "postsCount"); got != 1 {
		t.Errorf("reposter postsCount = %d, want 1 (a REPOST is a post)", got)
	}
	requireEngagementInvariants(t, e.fs, pid)

	// A REPOST id acts on its original: liking the repost is a replay of b's like.
	r, err = eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: "eng-like-key-0000002", PostId: repostID}))
	if err != nil || r.Msg.GetEngagement().GetPostId() != pid || r.Msg.GetEngagement().GetLikeCount() != 2 {
		t.Fatalf("like via REPOST id = %v, %v", r, err)
	}

	// Undo repost removes the REPOST post and decrements both counters; a second undo is a no-op.
	if _, err := eng.UndoRepost(ctx, authed(b.token, &engagementv1.UndoRepostRequest{IdempotencyKey: "eng-undo-key-000001", PostId: pid})); err != nil {
		t.Fatalf("UndoRepost: %v", err)
	}
	if fsDocExists(t, e.fs, "posts/"+repostID) || fsDocExists(t, e.fs, "reposts/"+pid+"_"+b.uid) {
		t.Fatal("UndoRepost left the REPOST post or the reposts doc")
	}
	if got := fsInt(t, e.fs, "users/"+b.uid, "postsCount"); got != 0 {
		t.Errorf("postsCount after undo = %d, want 0", got)
	}
	if _, err := eng.UndoRepost(ctx, authed(b.token, &engagementv1.UndoRepostRequest{IdempotencyKey: "eng-undo-key-000001", PostId: pid})); err != nil {
		t.Fatalf("UndoRepost repeat: %v", err)
	}
	if _, writes := e.lastLine(t, rpcUndoRepo); writes != 0 {
		t.Errorf("UndoRepost no-op writes = %v, want 0", writes)
	}

	// Unlike, and a no-op unlike.
	ur, err := eng.UnlikePost(ctx, authed(c.token, &engagementv1.UnlikePostRequest{IdempotencyKey: "eng-unlike-key-00001", PostId: pid}))
	if err != nil || ur.Msg.GetEngagement().GetLikedByViewer() {
		t.Fatalf("UnlikePost = %v, %v", ur, err)
	}
	if reads, writes := e.lastLine(t, rpcUnlike); reads > 3 || writes != 2 {
		t.Errorf("UnlikePost: reads=%v writes=%v, want reads <= 3, writes 2", reads, writes)
	}
	if _, err = eng.UnlikePost(ctx, authed(c.token, &engagementv1.UnlikePostRequest{IdempotencyKey: "eng-unlike-key-00001", PostId: pid})); err != nil {
		t.Fatalf("UnlikePost repeat: %v", err)
	}
	if _, writes := e.lastLine(t, rpcUnlike); writes != 0 {
		t.Errorf("UnlikePost no-op writes = %v, want 0", writes)
	}
	requireEngagementInvariants(t, e.fs, pid)

	// Quote: counter and embedded snapshot; then a REPOST by b again for the job scenario.
	q, err := e.posts.CreatePost(ctx, authed(c.token, &postsv1.CreatePostRequest{IdempotencyKey: "eng-quote-key-000001", Text: "my take", QuoteOfPostId: pid}))
	if err != nil {
		t.Fatalf("quote CreatePost: %v", err)
	}
	quote := q.Msg.GetPost().GetPost()
	if quote.GetKind() != postsv1.PostKind_POST_KIND_QUOTE || quote.GetEmbedded().GetPostId() != pid || quote.GetEmbedded().GetUnavailable() {
		t.Fatalf("quote = %v", quote)
	}
	if got := fsInt(t, e.fs, "posts/"+pid, "quoteCount"); got != 1 {
		t.Errorf("quoteCount = %d, want 1", got)
	}
	if _, err := eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: "eng-repost-key-00002", PostId: pid})); err != nil {
		t.Fatalf("RepostPost again: %v", err)
	}

	// DeletePost publishes post_delete; the job removes likes and reposts and tombstones the quote.
	e.pull(t) // drain earlier messages
	if _, err := e.posts.DeletePost(ctx, authed(a.token, &postsv1.DeletePostRequest{IdempotencyKey: "eng-del-key-0000001", PostId: pid})); err != nil {
		t.Fatalf("DeletePost: %v", err)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "post_delete" || msgs[0]["postId"] != pid {
		t.Fatalf("job messages = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery = %d", code)
	}
	if n := countWhere(t, e.fs, "likes", "postId", pid); n != 0 {
		t.Errorf("%d like docs survived the job", n)
	}
	if n := countWhere(t, e.fs, "reposts", "postId", pid); n != 0 {
		t.Errorf("%d reposts docs survived the job", n)
	}
	if got := fsInt(t, e.fs, "users/"+b.uid, "postsCount"); got != 0 {
		t.Errorf("reposter postsCount after the job = %d, want 0", got)
	}
	// The stored quote carries a tombstone (read from Firestore: the instance cache may serve the old copy for 60 s).
	qs, err := e.fs.Doc("posts/" + quote.GetPostId()).Get(ctx)
	if err != nil {
		t.Fatalf("get quote: %v", err)
	}
	emb, _ := qs.Data()["embedded"].(map[string]any)
	if un, _ := emb["unavailable"].(bool); !un || emb["text"] != nil && emb["text"] != "" {
		t.Fatalf("quote embed after delete = %v, want a tombstone", emb)
	}
	// At-least-once: a redelivery is harmless.
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery = %d", code)
	}
	// Liking a deleted post is NOT_FOUND.
	_, err = eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: "eng-like-key-0000003", PostId: pid}))
	wireError(t, err, connect.CodeNotFound)
}

func TestEngagementChain_FlagOff(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, nil) // FEATURE_ENGAGEMENT defaults to off
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a := e.newUser(t)
	created, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "eng-off-create-00001", Text: "x"}))
	if err != nil {
		t.Fatal(err)
	}
	pid := created.Msg.GetPost().GetPost().GetPostId()
	calls := map[string]func() error{
		"like": func() error {
			_, err := eng.LikePost(ctx, authed(a.token, &engagementv1.LikePostRequest{IdempotencyKey: "eng-off-key-0000001", PostId: pid}))
			return err
		},
		"unlike": func() error {
			_, err := eng.UnlikePost(ctx, authed(a.token, &engagementv1.UnlikePostRequest{IdempotencyKey: "eng-off-key-0000002", PostId: pid}))
			return err
		},
		"repost": func() error {
			_, err := eng.RepostPost(ctx, authed(a.token, &engagementv1.RepostPostRequest{IdempotencyKey: "eng-off-key-0000003", PostId: pid}))
			return err
		},
		"undo": func() error {
			_, err := eng.UndoRepost(ctx, authed(a.token, &engagementv1.UndoRepostRequest{IdempotencyKey: "eng-off-key-0000004", PostId: pid}))
			return err
		},
	}
	for name, call := range calls {
		d := wireError(t, call(), connect.CodeFailedPrecondition)
		if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Errorf("%s: reason = %v, want FEATURE_DISABLED", name, d.GetReason())
		}
	}
	// A quote is refused the same way.
	_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "eng-off-quote-000001", Text: "q", QuoteOfPostId: pid}))
	wireError(t, err, connect.CodeFailedPrecondition)
	if n := countWhere(t, e.fs, "likes", "postId", pid); n != 0 {
		t.Errorf("flag off wrote %d likes", n)
	}
}

// TestEngagementChain_QuotesFlagOff: FEATURE_ENGAGEMENT on for everyone, FEATURE_QUOTES allowlisted to one user.
// A non-allowlisted caller cannot create a quote through the real handler (FEATURE_DISABLED feature=quotes, no
// write) while like and repost still work; the allowlisted caller can, and the non-allowlisted viewer still sees
// the existing quote with its embedded snapshot.
func TestEngagementChain_QuotesFlagOff(t *testing.T) {
	ctx := context.Background()
	quoterTok, quoterUID := mintToken(t, "")
	e := newLifecycleEnvCfg(t, nil, func(c *config.Config) {
		engagementOnQuotesOff(c)
		c.FeatureQuotes = flags.Spec{Name: "quotes", Mode: flags.Allowlist, Allowlist: map[string]struct{}{quoterUID: {}}}
	})
	e.createProfile(t, quoterTok)
	quoter := testUser{quoterTok, quoterUID}
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a, b := e.newUser(t), e.newUser(t)

	created, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "qf-create-key-000001", Text: "original"}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	pid := created.Msg.GetPost().GetPost().GetPostId()

	// Engagement on, quotes off for b: the quote is refused with no write.
	_, err = e.posts.CreatePost(ctx, authed(b.token, &postsv1.CreatePostRequest{IdempotencyKey: "qf-quote-off-000001", Text: "take", QuoteOfPostId: pid}))
	d := wireError(t, err, connect.CodeFailedPrecondition)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || d.GetMetadata()["feature"] != "quotes" {
		t.Fatalf("quote refusal = %v, want FEATURE_DISABLED feature=quotes", d)
	}
	if got := fsInt(t, e.fs, "posts/"+pid, "quoteCount"); got != 0 {
		t.Errorf("quoteCount = %d after a refused quote, want 0", got)
	}
	if n := countWhere(t, e.fs, "posts", "authorId", b.uid); n != 0 {
		t.Errorf("a refused quote wrote %d posts", n)
	}

	// Like and repost are unaffected.
	if _, err := eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: "qf-like-key-0000001", PostId: pid})); err != nil {
		t.Fatalf("LikePost with quotes off: %v", err)
	}
	if _, err := eng.RepostPost(ctx, authed(b.token, &engagementv1.RepostPostRequest{IdempotencyKey: "qf-repost-key-000001", PostId: pid})); err != nil {
		t.Fatalf("RepostPost with quotes off: %v", err)
	}

	// The allowlisted quoter can create a quote; the non-allowlisted viewer still sees it, embed intact.
	q, err := e.posts.CreatePost(ctx, authed(quoter.token, &postsv1.CreatePostRequest{IdempotencyKey: "qf-quote-on-0000001", Text: "my take", QuoteOfPostId: pid}))
	if err != nil {
		t.Fatalf("allowlisted quote: %v", err)
	}
	qid := q.Msg.GetPost().GetPost().GetPostId()
	got, err := e.posts.GetPost(ctx, authed(b.token, &postsv1.GetPostRequest{PostId: qid}))
	if err != nil {
		t.Fatalf("GetPost of a quote with quotes off for the viewer: %v", err)
	}
	if p := got.Msg.GetPost().GetPost(); p.GetKind() != postsv1.PostKind_POST_KIND_QUOTE || p.GetEmbedded().GetPostId() != pid || p.GetEmbedded().GetUnavailable() {
		t.Fatalf("quote did not display: %v", p)
	}
}
