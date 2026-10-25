//go:build integration

package apiserver

// The publish sweep route over the real Build chain (ADR-0021 D1 and "Sweep", CMP-D4): /internal/cron/publish-scheduled
// is POST only, answers 204, runs the sweep with the feature flags and DEGRADED_MODE the process was started with, and
// writes one scheduled_sweep line. Helpers come from posts_restricted_test.go and posts_contract_test.go.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/protobuf/types/known/timestamppb"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// messageLines are the parsed log lines whose msg is msg, in order.
func (b *logBuf) messageLines(msg string) []map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(b.buf.String(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil && rec["msg"] == msg {
			out = append(out, rec)
		}
	}
	return out
}

func postRoute(t *testing.T, url, method string) int {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(""))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

// scheduleThenMakeDue schedules a post through the real RPC and backdates its publishAt, the only way to make an item due
// without waiting out the 2 minute minimum lead. It returns the scheduled id.
func scheduleThenMakeDue(t *testing.T, env *chainEnv, idToken, uid, text string) string {
	t.Helper()
	ctx := context.Background()
	resp, err := env.posts.SchedulePost(ctx, authed(idToken, &postsv1.SchedulePostRequest{
		IdempotencyKey: contractKey("route-sched"), Text: text, PublishAt: timestamppb.New(time.Now().Add(10 * time.Minute)),
	}))
	if err != nil {
		t.Fatalf("SchedulePost: %v", err)
	}
	id := resp.Msg.GetScheduledPost().GetScheduledId()
	ref := env.fs.Collection("users").Doc(uid).Collection("scheduled").Doc(id)
	if _, err := ref.Update(ctx, []firestore.Update{{Path: "publishAt", Value: time.Now().Add(-10 * time.Minute).UTC()}}); err != nil {
		t.Fatalf("backdate publishAt: %v", err)
	}
	return id
}

func TestPublishScheduledRoute_PublishesADueItemEndToEnd(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, func(cfg *config.Config) {
		cfg.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
	})
	token, uid := mintToken(t, "")
	env.createProfile(t, token)
	id := scheduleThenMakeDue(t, env, token, uid, "published by the sweep")

	if got := postRoute(t, env.url+"/internal/cron/publish-scheduled", http.MethodGet); got != http.StatusMethodNotAllowed {
		t.Errorf("GET = %d, want 405 (POST only)", got)
	}
	if got := postRoute(t, env.url+"/api/internal/cron/publish-scheduled", http.MethodPost); got != http.StatusNoContent {
		t.Fatalf("POST = %d, want 204", got)
	}

	snap, err := env.fs.Collection("users").Doc(uid).Collection("scheduled").Doc(id).Get(ctx)
	if err != nil {
		t.Fatal(err)
	}
	doc := snap.Data()
	postID, _ := doc["postId"].(string)
	if doc["status"] != "PUBLISHED" || postID == "" || doc["draft"] != nil {
		t.Fatalf("scheduled doc = %v, want PUBLISHED with a postId and no draft", doc)
	}
	got, err := env.posts.GetPost(ctx, authed(token, &postsv1.GetPostRequest{PostId: postID}))
	if err != nil || got.Msg.GetPost().GetPost().GetText() != "published by the sweep" {
		t.Fatalf("GetPost(%s) = %v, %v", postID, got, err)
	}

	lines := env.logs.messageLines("scheduled_sweep")
	if len(lines) != 1 {
		t.Fatalf("scheduled_sweep lines = %d, want 1", len(lines))
	}
	l := lines[0]
	if l["outcome"] != "ok" || l["due"] != float64(1) || l["published"] != float64(1) || l["fs_reads"] == float64(0) || l["fs_writes"] == float64(0) {
		t.Errorf("line = %v", l)
	}
	if strings.Contains(env.logs.String(), "published by the sweep") {
		t.Error("the post text reached the logs")
	}

	// A second run finds nothing due: one read, no writes, still 204.
	if got := postRoute(t, env.url+"/internal/cron/publish-scheduled", http.MethodPost); got != http.StatusNoContent {
		t.Fatalf("second POST = %d, want 204", got)
	}
	second := env.logs.messageLines("scheduled_sweep")
	if len(second) != 2 || second[1]["due"] != float64(0) || second[1]["fs_reads"] != float64(1) || second[1]["fs_writes"] != float64(0) {
		t.Errorf("second line = %v, want nothing due for 1 read", second)
	}
}

func (b *logBuf) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func TestPublishScheduledRoute_NoOpWhenTheFeatureIsOffOrDegraded(t *testing.T) {
	for _, tc := range []struct {
		name    string
		mutate  func(*config.Config)
		outcome string
	}{
		{"FEATURE_SCHEDULED_POSTS off (the default)", nil, "flag_off"},
		{"DEGRADED_MODE=readonly", func(c *config.Config) {
			c.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
			c.Degraded = config.DegradedReadonly
		}, "degraded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := newChain(t, tc.mutate)
			if got := postRoute(t, env.url+"/internal/cron/publish-scheduled", http.MethodPost); got != http.StatusNoContent {
				t.Fatalf("POST = %d, want 204", got)
			}
			lines := env.logs.messageLines("scheduled_sweep")
			if len(lines) != 1 || lines[0]["outcome"] != tc.outcome || lines[0]["fs_reads"] != float64(0) || lines[0]["fs_writes"] != float64(0) {
				t.Errorf("lines = %v, want one %s line with 0 reads and 0 writes", lines, tc.outcome)
			}
		})
	}
}
