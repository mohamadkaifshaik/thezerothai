//go:build integration

package apiserver

// F2 creator stats over the real Build chain (Firestore, Auth, Pub/Sub and Storage emulators): a follow, a like, a reply
// and a counted view (folded by the rollup route) land on the author's users/{uid}/dailyStats; the author's own like and
// own reply do not; an unlike subtracts; the export carries the daily_stats section; the account erasure deletes the
// docs (the daily_stats step).

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func creatorStatsOn(c *config.Config) {
	relaxLimits(c)
	c.RateLimit.ImpressionsPerUserPerMinute = 1_000_000
	c.RateLimit.ImpressionsRecordedPerDay = 1_000_000
	c.RateLimit.CreatorInsightsPerUserPerMinute = 1_000_000
	c.FeatureEngagement = flags.Spec{Name: "engagement", Mode: flags.On}
	c.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	c.FeaturePostViews = flags.Spec{Name: "post_views", Mode: flags.On}
	c.FeatureCreatorInsights = flags.Spec{Name: "creator_insights", Mode: flags.On}
}

// statsSum is the sum of uid's dailyStats docs (today's doc, and yesterday's if the test crossed IST midnight).
type statsSum struct{ docs, impressions, engagements, gained, lost int64 }

func readStatsSum(t *testing.T, fs *firestore.Client, uid string) statsSum {
	t.Helper()
	docs, err := fs.Collection("users").Doc(uid).Collection("dailyStats").Limit(10).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatalf("read dailyStats: %v", err)
	}
	var s statsSum
	for _, d := range docs {
		s.docs++
		for field, dst := range map[string]*int64{"impressions": &s.impressions, "engagements": &s.engagements, "followersGained": &s.gained, "followersLost": &s.lost} {
			if v, err := d.DataAt(field); err == nil {
				*dst += v.(int64)
			}
		}
		if exp, err := d.DataAt("expireAt"); err != nil || exp.(time.Time).Before(time.Now().Add(399*24*time.Hour)) {
			t.Errorf("dailyStats %s expireAt = %v, want about 400 days out", d.Ref.ID, exp)
		}
	}
	return s
}

func TestCreatorStatsChain_WritersExportErase(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnvCfg(t, nil, creatorStatsOn)
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, e.url)
	a, b := e.newUser(t), e.newUser(t)
	must := func(what string, err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}

	e.follow(t, b, a)
	cr, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("cs-post"), Text: "insights?"}))
	must("CreatePost", err)
	pid := cr.Msg.GetPost().GetPost().GetPostId()
	_, err = eng.LikePost(ctx, authed(b.token, &engagementv1.LikePostRequest{IdempotencyKey: contractKey("cs-like"), PostId: pid}))
	must("b likes", err)
	_, err = eng.LikePost(ctx, authed(a.token, &engagementv1.LikePostRequest{IdempotencyKey: contractKey("cs-own-like"), PostId: pid}))
	must("a likes own post", err)
	_, err = e.posts.CreatePost(ctx, authed(b.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("cs-reply"), Text: "a reply", ReplyToPostId: pid}))
	must("b replies", err)
	_, err = e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("cs-self-reply"), Text: "my own thread", ReplyToPostId: pid}))
	must("a replies to self", err)
	_, err = eng.RecordImpressions(ctx, authed(b.token, &engagementv1.RecordImpressionsRequest{IdempotencyKey: contractKey("cs-view"), PostIds: []string{pid}}))
	must("b views", err)

	if got := readStatsSum(t, e.fs, a.uid); got.impressions != 0 || got.engagements != 2 || got.gained != 1 || got.lost != 0 {
		t.Fatalf("before the rollup: %+v, want engagements 2 (like + reply), followersGained 1, no impressions yet", got)
	}

	// The rollup folds closed windows only: move the post's view marker back, then run the route twice (redelivery).
	markers, err := e.fs.Collection("viewDirty").Where("postId", "==", pid).Limit(10).Documents(ctx).GetAll()
	if err != nil || len(markers) == 0 {
		t.Fatalf("view markers: %d, %v", len(markers), err)
	}
	for _, m := range markers {
		if w, err := m.DataAt("window"); err == nil {
			_, err = m.Ref.Update(ctx, []firestore.Update{{Path: "window", Value: w.(int64) - 2}})
			must("close the view window", err)
		}
	}
	for range 2 {
		if got := postRoute(t, e.url+"/internal/cron/view-rollup", http.MethodPost); got != http.StatusNoContent {
			t.Fatalf("view-rollup = %d, want 204", got)
		}
	}
	if got := readStatsSum(t, e.fs, a.uid); got.impressions != 1 || got.engagements != 2 || got.gained != 1 {
		t.Fatalf("after the rollup and its redelivery: %+v, want impressions 1", got)
	}
	if got := readStatsSum(t, e.fs, b.uid); got.docs != 0 {
		t.Fatalf("b (who only acted) got stats: %+v", got)
	}

	// Undo paths subtract on the day of the undo.
	_, err = eng.UnlikePost(ctx, authed(b.token, &engagementv1.UnlikePostRequest{IdempotencyKey: contractKey("cs-unlike"), PostId: pid}))
	must("b unlikes", err)
	_, err = e.graph.Unfollow(ctx, authed(b.token, &graphv1.UnfollowRequest{IdempotencyKey: contractKey("cs-unfollow"), UserId: a.uid}))
	must("b unfollows", err)
	want := statsSum{impressions: 1, engagements: 1, gained: 1, lost: 1}
	got := readStatsSum(t, e.fs, a.uid)
	got.docs = 0
	if got != want {
		t.Fatalf("after the undos: %+v, want %+v", got, want)
	}

	// The export carries the section.
	_, raw := e.exportOf(t, a, contractKey("cs-export"))
	var doc struct {
		DailyStats []struct {
			Date            string `json:"date"`
			Impressions     int64  `json:"impressions"`
			Engagements     int64  `json:"engagements"`
			FollowersGained int64  `json:"followersGained"`
			FollowersLost   int64  `json:"followersLost"`
		} `json:"daily_stats"`
	}
	must("decode export", json.Unmarshal(raw, &doc))
	var ex statsSum
	for _, d := range doc.DailyStats {
		if len(d.Date) != 8 {
			t.Errorf("export date %q", d.Date)
		}
		ex.impressions += d.Impressions
		ex.engagements += d.Engagements
		ex.gained += d.FollowersGained
		ex.lost += d.FollowersLost
	}
	if len(doc.DailyStats) == 0 || ex != want {
		t.Fatalf("export daily_stats = %+v (sum %+v), want %+v", doc.DailyStats, ex, want)
	}

	// The erasure deletes the docs.
	_, err = e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: contractKey("cs-delete")}))
	must("DeleteAccount", err)
	if _, err := e.fs.Doc("users/"+a.uid).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	for _, m := range e.pull(t) {
		if m["kind"] == "account_delete" && m["uid"] == a.uid {
			if code := e.deliver(t, m); code != http.StatusNoContent {
				t.Fatalf("delete delivery = %d", code)
			}
		}
	}
	if fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Fatal("the deletion job did not finish")
	}
	if left := readStatsSum(t, e.fs, a.uid); left.docs != 0 {
		t.Fatalf("%d dailyStats docs survived the erasure", left.docs)
	}
}
