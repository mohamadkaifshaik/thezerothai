//go:build integration

package e2e

// T18 (docs/plans/account-deletion-export.md): account lifecycle E2E smoke.
//
//	create profile -> follow -> post -> request export -> READY -> download -> delete -> poll until the account is gone
//	-> residue check.
//
// Two modes, one body:
//
//   - Emulator mode (default, `make test-int`): apiserver.Build with account_lifecycle on, over the Firestore, Auth,
//     Pub/Sub and Storage emulators. The push subscription is played by hand (messages pulled from a pull
//     subscription are POSTed to /internal/pubsub/jobs) and the 120 s start gate is passed by moving
//     deletionRequestedAt back. A signed download URL cannot be minted against the emulators, so the export object is
//     read from the Storage emulator.
//   - Remote mode (prod `candidate` / dev URL): E2E_ACCOUNT_BASE_URL plus E2E_ACCOUNT_ID_TOKEN_A and
//     E2E_ACCOUNT_ID_TOKEN_B, fresh ID tokens (signed in within the re-auth window, 5 minutes by default) of two
//     throwaway accounts with profiles. Real Pub/Sub delivers the jobs, the download URL is fetched over HTTP, and
//     "the account is gone" is observed through the API (A's profile stops resolving; B's counters return to 0).
//     REMOTE MODE HAS NOT BEEN RUN: it needs credentials and a deployed candidate revision this environment does not
//     have. It is written so that A is deleted and B only ever follows A, so a re-run needs a fresh pair of accounts.
//
// Budget: about 30 requests, ~30 reads, ~15 writes, ~15 deletes per run (under the < 100-request prod smoke cap).

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"connectrpc.com/connect"
	"google.golang.org/api/option"
	pubsub "google.golang.org/api/pubsub/v1"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

type accountSmokeEnv struct {
	identity       identityv1connect.IdentityServiceClient
	graph          graphv1connect.GraphServiceClient
	posts          postsv1connect.PostServiceClient
	baseURL        string
	tokenA, tokenB string
	uidA, uidB     string
	remote         bool

	// emulator mode only
	cfg    config.Config
	fs     *firestore.Client
	ps     *pubsub.Service
	sub    string
	bucket *storage.BucketHandle
}

func setupAccountSmoke(t *testing.T) *accountSmokeEnv {
	t.Helper()
	ctx := context.Background()
	if base := os.Getenv("E2E_ACCOUNT_BASE_URL"); base != "" {
		tokA, tokB := os.Getenv("E2E_ACCOUNT_ID_TOKEN_A"), os.Getenv("E2E_ACCOUNT_ID_TOKEN_B")
		if tokA == "" || tokB == "" {
			t.Fatal("E2E_ACCOUNT_BASE_URL is set but E2E_ACCOUNT_ID_TOKEN_A / E2E_ACCOUNT_ID_TOKEN_B are not")
		}
		env := &accountSmokeEnv{
			identity: identityv1connect.NewIdentityServiceClient(http.DefaultClient, base),
			graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, base),
			posts:    postsv1connect.NewPostServiceClient(http.DefaultClient, base),
			baseURL:  base, tokenA: tokA, tokenB: tokB, remote: true,
		}
		meA, err := env.identity.GetMe(ctx, authedRequest(tokA, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(A): %v", err)
		}
		meB, err := env.identity.GetMe(ctx, authedRequest(tokB, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe(B): %v", err)
		}
		env.uidA, env.uidB = meA.Msg.GetProfile().GetUserId(), meB.Msg.GetProfile().GetUserId()
		return env
	}

	skipIfNoEmulators(t)
	if os.Getenv("PUBSUB_EMULATOR_HOST") == "" || os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("PUBSUB_EMULATOR_HOST/STORAGE_EMULATOR_HOST not set; run via the emulator suite")
	}
	suffix := rand.Int63()
	topic, bucketName := fmt.Sprintf("jobs-e2e-%d", suffix), fmt.Sprintf("demo-e2e-exports-%d", suffix)
	identityClient, baseURL := newTestServerCfg(t, func(c *config.Config) {
		c.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.On}
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic, c.ExportBucket = topic, bucketName
	})
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	env := &accountSmokeEnv{
		identity: identityClient,
		graph:    graphv1connect.NewGraphServiceClient(http.DefaultClient, baseURL),
		posts:    postsv1connect.NewPostServiceClient(http.DefaultClient, baseURL),
		baseURL:  baseURL, cfg: cfg,
	}
	env.fs, err = firestore.NewClient(ctx, cfg.ProjectID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = env.fs.Close() })
	env.ps, err = pubsub.NewService(ctx, option.WithEndpoint("http://"+os.Getenv("PUBSUB_EMULATOR_HOST")+"/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	topicName := fmt.Sprintf("projects/%s/topics/%s", cfg.ProjectID, topic)
	env.sub = fmt.Sprintf("projects/%s/subscriptions/sub-%d", cfg.ProjectID, suffix)
	if _, err := env.ps.Projects.Topics.Create(topicName, &pubsub.Topic{}).Context(ctx).Do(); err != nil {
		t.Fatalf("create topic: %v", err)
	}
	if _, err := env.ps.Projects.Subscriptions.Create(env.sub, &pubsub.Subscription{Topic: topicName, AckDeadlineSeconds: 60}).Context(ctx).Do(); err != nil {
		t.Fatalf("create subscription: %v", err)
	}
	sc, err := storage.NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sc.Close() })
	env.bucket = sc.Bucket(bucketName)

	create := func(label string) (string, string) {
		token, uid := newAnonymousIDToken(t)
		if _, err := env.identity.CreateProfile(ctx, authedRequest(token, &identityv1.CreateProfileRequest{
			IdempotencyKey: fmt.Sprintf("e2e-account-create-%s-%d", label, rand.Int63()),
			Handle:         uniqueHandle("a18" + label),
			DisplayName:    "Account Smoke " + label,
		})); err != nil {
			t.Fatalf("CreateProfile(%s): %v", label, err)
		}
		return token, uid
	}
	env.tokenA, env.uidA = create("a")
	env.tokenB, env.uidB = create("b")
	return env
}

// pull returns every message currently on the subscription (acked) as raw JSON plus its base64 data.
func (e *accountSmokeEnv) pull(t *testing.T) (msgs []map[string]any, datas []string) {
	t.Helper()
	for {
		resp, err := e.ps.Projects.Subscriptions.Pull(e.sub, &pubsub.PullRequest{MaxMessages: 50, ReturnImmediately: true}).Context(context.Background()).Do()
		if err != nil {
			t.Fatalf("pull: %v", err)
		}
		if len(resp.ReceivedMessages) == 0 {
			return msgs, datas
		}
		var acks []string
		for _, m := range resp.ReceivedMessages {
			raw, _ := base64.StdEncoding.DecodeString(m.Message.Data)
			var msg map[string]any
			if err := json.Unmarshal(raw, &msg); err != nil {
				t.Fatalf("job message %q: %v", raw, err)
			}
			msgs, datas = append(msgs, msg), append(datas, m.Message.Data)
			acks = append(acks, m.AckId)
		}
		if _, err := e.ps.Projects.Subscriptions.Acknowledge(e.sub, &pubsub.AcknowledgeRequest{AckIds: acks}).Context(context.Background()).Do(); err != nil {
			t.Fatalf("ack: %v", err)
		}
	}
}

// deliver POSTs one base64 message to the jobs endpoint like a push subscription.
func (e *accountSmokeEnv) deliver(t *testing.T, b64 string) int {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": b64, "messageId": "1"}, "subscription": "s", "deliveryAttempt": 1})
	resp, err := http.Post(e.baseURL+"/internal/pubsub/jobs", "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("deliver: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// runJobs plays Pub/Sub in emulator mode until the topic is quiet: a message stays in flight until it is acked (204).
func (e *accountSmokeEnv) runJobs(t *testing.T) {
	t.Helper()
	for round := 0; round < 40; round++ {
		_, datas := e.pull(t)
		if len(datas) == 0 {
			return
		}
		for _, d := range datas {
			for tries := 0; e.deliver(t, d) != http.StatusNoContent; tries++ {
				if tries >= 5 {
					t.Fatal("a job message was never acked")
				}
			}
		}
	}
	t.Fatal("the job chain did not finish")
}

func (e *accountSmokeEnv) eventually(t *testing.T, what string, timeout time.Duration, cond func() (bool, string)) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last string
	for {
		ok, msg := cond()
		if ok {
			return
		}
		last = msg
		if time.Now().After(deadline) {
			t.Fatalf("%s: not true within %v (last: %s)", what, timeout, last)
		}
		time.Sleep(2 * time.Second)
	}
}

func TestE2E_AccountLifecycleSmoke(t *testing.T) {
	e := setupAccountSmoke(t)
	ctx := context.Background()
	key := func(op string) string { return fmt.Sprintf("e2e-account-%s-%d", op, rand.Int63()) }
	text := fmt.Sprintf("account smoke post %d", rand.Int63())

	// follow (both ways, so A has a followee and a follower to clean up) and post
	if _, err := e.graph.Follow(ctx, authedRequest(e.tokenB, &graphv1.FollowRequest{IdempotencyKey: key("follow-b-a"), UserId: e.uidA})); err != nil {
		t.Fatalf("B follows A: %v", err)
	}
	if _, err := e.graph.Follow(ctx, authedRequest(e.tokenA, &graphv1.FollowRequest{IdempotencyKey: key("follow-a-b"), UserId: e.uidB})); err != nil {
		t.Fatalf("A follows B: %v", err)
	}
	post, err := e.posts.CreatePost(ctx, authedRequest(e.tokenA, &postsv1.CreatePostRequest{IdempotencyKey: key("post"), Text: text}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	postID := post.Msg.GetPost().GetPost().GetPostId()

	// export: request, READY, download
	exp, err := e.identity.RequestAccountExport(ctx, authedRequest(e.tokenA, &identityv1.RequestAccountExportRequest{IdempotencyKey: key("export")}))
	if err != nil {
		t.Fatalf("RequestAccountExport: %v", err)
	}
	var exported []byte
	if e.remote {
		var url string
		e.eventually(t, "export READY", 5*time.Minute, func() (bool, string) {
			got, err := e.identity.GetAccountExport(ctx, authedRequest(e.tokenA, &identityv1.GetAccountExportRequest{ExportId: exp.Msg.GetExportId()}))
			if err != nil {
				return false, err.Error()
			}
			url = got.Msg.GetDownloadUrl()
			return got.Msg.GetStatus() == identityv1.ExportStatus_EXPORT_STATUS_READY && url != "", got.Msg.GetStatus().String()
		})
		resp, err := http.Get(url)
		if err != nil {
			t.Fatalf("download: %v", err) // never print the URL
		}
		defer resp.Body.Close()
		exported, _ = io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("download: HTTP %d", resp.StatusCode)
		}
	} else {
		e.runJobs(t)
		rd, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").NewReader(ctx)
		if err != nil {
			t.Fatalf("export object: %v", err)
		}
		exported, _ = io.ReadAll(rd)
		_ = rd.Close()
	}
	var doc struct {
		ExportVersion int `json:"exportVersion"`
		Posts         struct {
			Posts []struct {
				Text string `json:"text"`
			} `json:"posts"`
		} `json:"posts"`
		Graph struct {
			Following []map[string]any `json:"following"`
			Followers []map[string]any `json:"followers"`
		} `json:"graph"`
	}
	if err := json.Unmarshal(exported, &doc); err != nil {
		t.Fatalf("the export is not JSON: %v", err)
	}
	if doc.ExportVersion != 1 || len(doc.Posts.Posts) != 1 || doc.Posts.Posts[0].Text != text || len(doc.Graph.Following) != 1 || len(doc.Graph.Followers) != 1 {
		t.Errorf("export content wrong: %d posts, %d following, %d followers", len(doc.Posts.Posts), len(doc.Graph.Following), len(doc.Graph.Followers))
	}

	// delete
	if _, err := e.identity.DeleteAccount(ctx, authedRequest(e.tokenA, &identityv1.DeleteAccountRequest{IdempotencyKey: key("delete")})); err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	if e.remote {
		e.eventually(t, "A's profile gone", 15*time.Minute, func() (bool, string) {
			_, err := e.identity.GetMe(ctx, authedRequest(e.tokenA, &identityv1.GetMeRequest{}))
			return connect.CodeOf(err) == connect.CodeNotFound, fmt.Sprint(connect.CodeOf(err))
		})
	} else {
		if _, err := e.fs.Doc("users/"+e.uidA).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
			t.Fatal(err)
		}
		e.runJobs(t)
		if snap, err := e.fs.Doc("users/" + e.uidA).Get(ctx); err == nil && snap.Exists() {
			t.Fatal("users/{uid} survived the deletion")
		}
	}

	// residue, through the API (both modes): the post is gone and B's counters are back to zero
	if _, err := e.posts.GetPost(ctx, authedRequest(e.tokenB, &postsv1.GetPostRequest{PostId: postID})); connect.CodeOf(err) != connect.CodeNotFound {
		t.Errorf("A's post after the deletion: %v, want NOT_FOUND", err)
	}
	meB, err := e.identity.GetMe(ctx, authedRequest(e.tokenB, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe(B): %v", err)
	}
	if meB.Msg.GetProfile().GetFollowersCount() != 0 || meB.Msg.GetProfile().GetFollowingCount() != 0 {
		t.Errorf("B's counters after A's deletion: followers %d following %d, want 0 and 0", meB.Msg.GetProfile().GetFollowersCount(), meB.Msg.GetProfile().GetFollowingCount())
	}

	// residue, directly (emulator mode): nothing keyed by A's uid is left
	if !e.remote {
		for _, path := range []string{"users/" + e.uidA, "graph/" + e.uidA, "quotas/" + e.uidA, "exports/" + exp.Msg.GetExportId()} {
			if snap, err := e.fs.Doc(path).Get(ctx); err == nil && snap.Exists() {
				t.Errorf("%s survived", path)
			}
		}
		for _, q := range []struct{ col, field string }{{"posts", "authorId"}, {"follows", "followerId"}, {"follows", "followeeId"}, {"handles", "uid"}, {"exports", "uid"}} {
			docs, err := e.fs.Collection(q.col).Where(q.field, "==", e.uidA).Limit(3).Documents(ctx).GetAll()
			if err != nil || len(docs) != 0 {
				t.Errorf("%s.%s == deleted uid: %d docs, err %v", q.col, q.field, len(docs), err)
			}
		}
		if _, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").Attrs(ctx); err == nil {
			t.Error("the export object survived")
		}
		// The Auth user is gone: its (still cryptographically valid) token no longer passes the emulator's verifier.
		_, err := e.identity.GetMe(ctx, authedRequest(e.tokenA, &identityv1.GetMeRequest{}))
		if err == nil {
			t.Error("GetMe(A) still succeeds after the deletion")
		}
	}
}
