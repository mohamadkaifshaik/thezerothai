//go:build integration

package apiserver

// F1 post views over the real Build chain (Firestore and Auth emulators): the flag gate of RecordImpressions
// (FEATURE_DISABLED before any lookup), a counted view per (viewer, post, IST day) and none for the author, the rollup
// route folding the shards into viewCount (idempotent on redelivery), the hybrid read rule (the author's exact count,
// another viewer's only from the threshold on), and the kill switch.

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func viewsMode(mode flags.Mode, threshold int64) func(*config.Config) {
	return func(c *config.Config) {
		c.RateLimit.ImpressionsPerUserPerMinute = 1_000_000
		c.RateLimit.ImpressionsRecordedPerDay = 1_000_000
		c.FeaturePostViews = flags.Spec{Name: "post_views", Mode: mode}
		c.PostViewsPublicThreshold = threshold
	}
}

func (p *pollChain) record(u testUser, key string, ids ...string) error {
	_, err := p.eng.RecordImpressions(context.Background(), authed(u.token, &engagementv1.RecordImpressionsRequest{IdempotencyKey: key, PostIds: ids}))
	return err
}

func (p *pollChain) plainPost(t *testing.T, author testUser) string {
	t.Helper()
	p.seq++
	r, err := p.posts.CreatePost(context.Background(), authed(author.token, &postsv1.CreatePostRequest{
		IdempotencyKey: fmt.Sprintf("views-create-key-%07d", p.seq), Text: "seen?",
	}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	return r.Msg.GetPost().GetPost().GetPostId()
}

// closeViewWindows moves postID's rollup markers one window back, as if 5 minutes had passed (the rollup folds closed
// windows only).
func (p *pollChain) closeViewWindows(t *testing.T, postID string) {
	t.Helper()
	ctx := context.Background()
	docs, err := p.fs.Collection("viewDirty").Where("postId", "==", postID).Limit(10).Documents(ctx).GetAll()
	if err != nil || len(docs) == 0 {
		t.Fatalf("markers of %s: %d, %v", postID, len(docs), err)
	}
	for _, d := range docs {
		w, _ := d.DataAt("window")
		if _, err := d.Ref.Update(ctx, []firestore.Update{{Path: "window", Value: w.(int64) - 2}}); err != nil {
			t.Fatal(err)
		}
	}
}

func (p *pollChain) viewCountOf(t *testing.T, viewer testUser, postID string) *int64 {
	t.Helper()
	r, err := p.posts.GetPost(context.Background(), authed(viewer.token, &postsv1.GetPostRequest{PostId: postID}))
	if err != nil {
		t.Fatalf("GetPost: %v", err)
	}
	return r.Msg.GetPost().GetPost().ViewCount
}

func TestPostViewsChain_FlagOffIsFeatureDisabled(t *testing.T) {
	e := newPollChain(t, viewsMode(flags.Off, 1000))
	a, b := e.user(t), e.user(t)
	pid := e.plainPost(t, a)
	err := e.record(b, "views-key-off-000001", pid)
	wantReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED, "feature", "post_views")
	if docs, _ := e.fs.Collection("users").Doc(b.uid).Collection("impressions").Limit(1).Documents(context.Background()).GetAll(); len(docs) != 0 {
		t.Fatal("a refused call wrote an impression")
	}
	if got := e.viewCountOf(t, a, pid); got != nil {
		t.Fatalf("flag globally off: the author still got view_count %d", *got)
	}
}

func TestPostViewsChain_RecordRollupRead(t *testing.T) {
	e := newPollChain(t, viewsMode(flags.On, 2))
	a, b, c, d := e.user(t), e.user(t), e.user(t), e.user(t)
	pid := e.plainPost(t, a)

	// The author's own view and a repeat the same day count nothing; b and c count once each.
	for _, call := range []struct {
		u   testUser
		key string
	}{{a, "views-key-own-000001"}, {b, "views-key-b-00000001"}, {b, "views-key-b-00000002"}, {c, "views-key-c-00000001"}} {
		if err := e.record(call.u, call.key, pid, pid); err != nil {
			t.Fatalf("RecordImpressions: %v", err)
		}
	}
	// The author sees the exact live count before any rollup; d (not the author) sees nothing yet (viewCount 0 < 2).
	if got := e.viewCountOf(t, a, pid); got == nil || *got != 2 {
		t.Fatalf("author view_count = %v, want the live 2", got)
	}
	if got := e.viewCountOf(t, d, pid); got != nil {
		t.Fatalf("other viewer below the threshold got %d", *got)
	}

	e.closeViewWindows(t, pid)
	for range 2 { // the second call is the redelivery
		if got := postRoute(t, e.url+"/internal/cron/view-rollup", http.MethodPost); got != http.StatusNoContent {
			t.Fatalf("view-rollup = %d, want 204", got)
		}
	}
	snap, err := e.fs.Doc("posts/" + pid).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if v, _ := snap.DataAt("viewCount"); v != int64(2) {
		t.Fatalf("viewCount = %v, want 2 after the rollup and its redelivery", v)
	}
	// Through a cold chain: the first chain's 60 s instance post cache still holds the post as read before the rollup.
	cold := newPollChain(t, viewsMode(flags.On, 2))
	if got := cold.viewCountOf(t, d, pid); got == nil || *got != 2 {
		t.Fatalf("other viewer at the threshold = %v, want 2", got)
	}
	if left, _ := e.fs.Collection("viewDirty").Where("postId", "==", pid).Limit(5).Documents(context.Background()).GetAll(); len(left) != 0 {
		t.Fatalf("%d rollup markers left", len(left))
	}
}
