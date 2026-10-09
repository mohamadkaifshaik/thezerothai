//go:build integration

package apiserver

// Account lifecycle over the real Build chain (ADR-0011, P8): Firestore, Auth, Pub/Sub and Storage emulators with
// the real posts and graph Erasers behind the adapters. The Pub/Sub topic is real (the REST publisher talks to the
// emulator); messages are pulled from a pull subscription and delivered to /internal/pubsub/jobs by hand, which is
// what a push subscription does. The 120 s start gate is passed by moving deletionRequestedAt back in Firestore.
// A signed download URL cannot be minted against the emulators (no signing credentials), so the READY object is
// read straight from the bucket; the signing path is covered by unit tests and the dev smoke.

import (
	"bytes"
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

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1/graphv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// lifecycleEnv is one Build chain with the account lifecycle on, plus its emulator-side plumbing.
type lifecycleEnv struct {
	*chainEnv
	cfg    config.Config
	graph  graphv1connect.GraphServiceClient
	ps     *pubsub.Service
	sub    string
	bucket *storage.BucketHandle
}

func skipIfNoLifecycleEmulators(t *testing.T) {
	t.Helper()
	skipIfNoEmulators(t)
	if os.Getenv("PUBSUB_EMULATOR_HOST") == "" || os.Getenv("STORAGE_EMULATOR_HOST") == "" {
		t.Skip("PUBSUB_EMULATOR_HOST/STORAGE_EMULATOR_HOST not set; run via the emulator suite")
	}
}

func newLifecycleEnv(t *testing.T) *lifecycleEnv {
	t.Helper()
	return newLifecycleEnvWith(t, nil)
}

// newLifecycleEnvWith is newLifecycleEnv with an optional ID-token verifier override (nil = the real one).
func newLifecycleEnvWith(t *testing.T, verifier authn.IDTokenVerifier) *lifecycleEnv {
	t.Helper()
	skipIfNoLifecycleEmulators(t)
	ctx := context.Background()
	suffix := rand.Int63()
	topic := fmt.Sprintf("jobs-%d", suffix)
	bucketName := fmt.Sprintf("demo-exports-%d", suffix)

	env := newChainWith(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic = topic
		c.ExportBucket = bucketName
	}, verifier)
	cfg, _ := config.Load()

	ps, err := pubsub.NewService(ctx, option.WithEndpoint("http://"+os.Getenv("PUBSUB_EMULATOR_HOST")+"/"), option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	topicName := fmt.Sprintf("projects/%s/topics/%s", cfg.ProjectID, topic)
	subName := fmt.Sprintf("projects/%s/subscriptions/sub-%d", cfg.ProjectID, suffix)
	if _, err := ps.Projects.Topics.Create(topicName, &pubsub.Topic{}).Context(ctx).Do(); err != nil {
		t.Fatalf("create topic: %v", err)
	}
	if _, err := ps.Projects.Subscriptions.Create(subName, &pubsub.Subscription{Topic: topicName, AckDeadlineSeconds: 60}).Context(ctx).Do(); err != nil {
		t.Fatalf("create subscription: %v", err)
	}
	sc, err := storage.NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sc.Close() })
	// The Firebase Storage emulator creates a bucket on first use; it does not implement bucket creation.
	return &lifecycleEnv{
		chainEnv: env, cfg: cfg, graph: graphv1connect.NewGraphServiceClient(http.DefaultClient, env.url),
		ps: ps, sub: subName, bucket: sc.Bucket(bucketName),
	}
}

// pull returns every job message currently on the subscription (acked), decoded.
func (e *lifecycleEnv) pull(t *testing.T) []map[string]any {
	t.Helper()
	var out []map[string]any
	for {
		resp, err := e.ps.Projects.Subscriptions.Pull(e.sub, &pubsub.PullRequest{MaxMessages: 50, ReturnImmediately: true}).Context(context.Background()).Do()
		if err != nil {
			t.Fatalf("pull: %v", err)
		}
		if len(resp.ReceivedMessages) == 0 {
			return out
		}
		var acks []string
		for _, m := range resp.ReceivedMessages {
			raw, _ := base64.StdEncoding.DecodeString(m.Message.Data)
			var msg map[string]any
			if err := json.Unmarshal(raw, &msg); err != nil {
				t.Fatalf("job message %q: %v", raw, err)
			}
			msg["_data"] = m.Message.Data
			out = append(out, msg)
			acks = append(acks, m.AckId)
		}
		if _, err := e.ps.Projects.Subscriptions.Acknowledge(e.sub, &pubsub.AcknowledgeRequest{AckIds: acks}).Context(context.Background()).Do(); err != nil {
			t.Fatalf("ack: %v", err)
		}
	}
}

// deliver posts one pulled message to the jobs endpoint like a push subscription and returns the HTTP status.
func (e *lifecycleEnv) deliver(t *testing.T, msg map[string]any) int {
	t.Helper()
	return e.deliverData(t, msg["_data"].(string))
}

func (e *lifecycleEnv) deliverJSON(t *testing.T, msg any) int {
	t.Helper()
	raw, _ := json.Marshal(msg)
	return e.deliverData(t, base64.StdEncoding.EncodeToString(raw))
}

func (e *lifecycleEnv) deliverData(t *testing.T, b64 string) int {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": b64, "messageId": "1"}, "subscription": "s", "deliveryAttempt": 1})
	resp, err := http.Post(e.url+"/internal/pubsub/jobs", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("deliver: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

// jobLines are the one-line-per-delivery `account_job` records.
func (e *lifecycleEnv) jobLines() []map[string]any {
	e.logs.mu.Lock()
	defer e.logs.mu.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(e.logs.buf.String(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil && rec["msg"] == "account_job" {
			out = append(out, rec)
		}
	}
	return out
}

func (e *lifecycleEnv) logContains(s string) bool {
	e.logs.mu.Lock()
	defer e.logs.mu.Unlock()
	return strings.Contains(e.logs.buf.String(), s)
}

// authUser reads one user from the Auth emulator's admin API (Bearer owner): present, disabled.
func (e *lifecycleEnv) authUser(t *testing.T, uid string) (present, disabled bool) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"localId": []string{uid}})
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/projects/%s/accounts:lookup", os.Getenv("FIREBASE_AUTH_EMULATOR_HOST"), e.cfg.ProjectID)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer owner")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("auth lookup: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out struct {
		Users []struct {
			Disabled bool `json:"disabled"`
		} `json:"users"`
	}
	if resp.StatusCode != http.StatusOK || json.Unmarshal(raw, &out) != nil {
		t.Fatalf("auth lookup: status %d: %s", resp.StatusCode, raw)
	}
	if len(out.Users) == 0 {
		return false, false
	}
	return true, out.Users[0].Disabled
}

type testUser struct {
	token, uid string
}

func (e *lifecycleEnv) newUser(t *testing.T) testUser {
	t.Helper()
	tok, uid := mintToken(t, "")
	e.createProfile(t, tok)
	return testUser{tok, uid}
}

func (e *lifecycleEnv) follow(t *testing.T, who, target testUser) {
	t.Helper()
	if _, err := e.graph.Follow(context.Background(), authed(who.token, &graphv1.FollowRequest{IdempotencyKey: fmt.Sprintf("follow-key-%d", rand.Int63()), UserId: target.uid})); err != nil {
		t.Fatalf("Follow: %v", err)
	}
}

func fsDocExists(t *testing.T, c *firestore.Client, path string) bool {
	t.Helper()
	snap, err := c.Doc(path).Get(context.Background())
	if err != nil {
		return false
	}
	return snap.Exists()
}

// TestAccountLifecycle_Chain is the reference path: a user with a post, a follower, a followee and an export
// requests deletion; the chain of job deliveries erases everything in ADR-0011 Q1 order and leaves no residue
// outside the Q10 allowlist.
func TestAccountLifecycle_Chain(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	a, b, c := e.newUser(t), e.newUser(t), e.newUser(t)
	e.follow(t, c, a) // C follows A: A's purge removes A from C's following[]
	e.follow(t, a, b) // A follows B: B's followersCount drops
	if _, err := e.posts.CreatePost(ctx, authed(a.token, &postsv1.CreatePostRequest{IdempotencyKey: "chain-post-key-00001", Text: "to be erased"})); err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	e.pull(t) // nothing so far

	// --- export: request, deliver, READY, object content ---
	exp, err := e.identity.RequestAccountExport(ctx, authed(a.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "chain-export-key-0001"}))
	if err != nil {
		t.Fatalf("RequestAccountExport: %v", err)
	}
	if exp.Msg.GetStatus() != identityv1.ExportStatus_EXPORT_STATUS_PENDING {
		t.Fatalf("status = %v", exp.Msg.GetStatus())
	}
	lines := e.requestLinesFor("/dzeroth.identity.v1.IdentityService/RequestAccountExport")
	if len(lines) != 1 || lines[0]["fs_reads"].(float64) > 3 || lines[0]["fs_writes"].(float64) != 2 {
		t.Errorf("RequestAccountExport request line = %v, want reads <= 3 (interceptor + quotas), writes 2", lines)
	}
	msgs := e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "account_export" || msgs[0]["exportId"] != exp.Msg.GetExportId() {
		t.Fatalf("export message = %v", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("export delivery = %d", code)
	}
	if !fsDocExists(t, e.fs, "exports/"+exp.Msg.GetExportId()) {
		t.Fatal("exports doc missing")
	}
	snap, _ := e.fs.Doc("exports/" + exp.Msg.GetExportId()).Get(ctx)
	if st, _ := snap.DataAt("status"); st != "READY" {
		t.Fatalf("export status = %v, want READY", st)
	}
	rd, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").NewReader(ctx)
	if err != nil {
		t.Fatalf("export object: %v", err)
	}
	raw, _ := io.ReadAll(rd)
	_ = rd.Close()
	var env struct {
		ExportVersion int            `json:"exportVersion"`
		Profile       map[string]any `json:"profile"`
		Graph         struct {
			Following []map[string]any `json:"following"`
			Followers []map[string]any `json:"followers"`
		} `json:"graph"`
		Posts struct {
			Posts []map[string]any `json:"posts"`
		} `json:"posts"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		t.Fatalf("export is not valid JSON: %v\n%s", err, raw)
	}
	if env.ExportVersion != 1 || len(env.Graph.Following) != 1 || len(env.Graph.Followers) != 1 || len(env.Posts.Posts) != 1 || env.Posts.Posts[0]["text"] != "to be erased" {
		t.Errorf("export content = %s", raw)
	}
	for _, internal := range []string{"status", "snapshotVersion", "deletionJob", "blockedBy"} {
		if strings.Contains(string(raw), `"`+internal+`"`) {
			t.Errorf("export leaks %q", internal)
		}
	}
	// Another user's id for the same export is NOT_FOUND.
	_, err = e.identity.GetAccountExport(ctx, authed(b.token, &identityv1.GetAccountExportRequest{ExportId: exp.Msg.GetExportId()}))
	wireError(t, err, connect.CodeNotFound)

	// --- DeleteAccount: sync part ---
	del, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "chain-delete-key-0001"}))
	if err != nil {
		t.Fatalf("DeleteAccount: %v", err)
	}
	requestedAt := del.Msg.GetDeletionRequestedAt().AsTime()
	lines = e.requestLinesFor("/dzeroth.identity.v1.IdentityService/DeleteAccount")
	if len(lines) != 1 || lines[0]["fs_reads"].(float64) > 2 || lines[0]["fs_writes"].(float64) != 1 {
		t.Errorf("DeleteAccount request line = %v, want reads <= 2, writes 1", lines)
	}
	// Replay (a lost response): same timestamp, 0 writes, no ACCOUNT_RESTRICTED even though the user is DELETING now.
	again, err := e.identity.DeleteAccount(ctx, authed(a.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "chain-delete-key-0002"}))
	if err != nil || !again.Msg.GetDeletionRequestedAt().AsTime().Equal(requestedAt) {
		t.Fatalf("replay = %v, %v", again, err)
	}
	if lines = e.requestLinesFor("/dzeroth.identity.v1.IdentityService/DeleteAccount"); len(lines) != 2 || lines[1]["fs_writes"].(float64) != 0 {
		t.Errorf("replay request line = %v, want 0 writes", lines)
	}
	// Every other RPC is restricted for the DELETING caller.
	_, err = e.identity.GetMe(ctx, authed(a.token, &identityv1.GetMeRequest{}))
	if d := wireError(t, err, connect.CodePermissionDenied); d.GetReason() != commonv1.ErrorReason_ERROR_REASON_ACCOUNT_RESTRICTED {
		t.Errorf("GetMe reason = %v", d.GetReason())
	}

	// --- jobs: gated first, erased after the gate ---
	msgs = e.pull(t)
	if len(msgs) != 1 || msgs[0]["kind"] != "account_delete" || msgs[0]["uid"] != a.uid || msgs[0]["seq"] != float64(0) {
		t.Fatalf("delete messages = %v, want one seq-0 message (the replay inside 2 minutes does not publish, M2)", msgs)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusTooManyRequests {
		t.Fatalf("delivery inside the start gate = %d, want 429", code)
	}
	if present, disabled := e.authUser(t, a.uid); !present || !disabled {
		t.Errorf("after the gated delivery the Auth user is present=%v disabled=%v, want present and disabled", present, disabled)
	}
	if !fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Fatal("the gated delivery deleted data")
	}
	if _, err := e.fs.Doc("users/"+a.uid).Update(ctx, []firestore.Update{{Path: "deletionRequestedAt", Value: time.Now().Add(-5 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("delivery after the gate = %d, want 204", code)
	}
	if code := e.deliver(t, msgs[0]); code != http.StatusNoContent {
		t.Fatalf("redelivery of the finished job's message = %d, want 204", code)
	}
	if rest := e.pull(t); len(rest) != 0 {
		t.Errorf("a finished job published a continuation: %v", rest)
	}

	// --- result ---
	if fsDocExists(t, e.fs, "users/"+a.uid) {
		t.Error("users doc survived")
	}
	if present, _ := e.authUser(t, a.uid); present {
		t.Error("the Firebase Auth user survived")
	}
	for _, path := range []string{"graph/" + a.uid, "quotas/" + a.uid, "exports/" + exp.Msg.GetExportId()} {
		if fsDocExists(t, e.fs, path) {
			t.Errorf("%s survived", path)
		}
	}
	if _, err := e.bucket.Object(exp.Msg.GetExportId() + ".json").Attrs(ctx); err == nil {
		t.Error("the export object survived")
	}
	for _, q := range []struct{ col, field string }{
		{"posts", "authorId"}, {"follows", "followerId"}, {"follows", "followeeId"}, {"exports", "uid"}, {"handles", "uid"},
	} {
		docs, err := e.fs.Collection(q.col).Where(q.field, "==", a.uid).Limit(5).Documents(ctx).GetAll()
		if err != nil || len(docs) != 0 {
			t.Errorf("%s.%s == deleted uid: %d docs, err %v (residue)", q.col, q.field, len(docs), err)
		}
	}
	gc, _ := e.fs.Doc("graph/" + c.uid).Get(ctx)
	following, _ := gc.DataAt("following")
	for _, u := range following.([]any) {
		if u == a.uid {
			t.Error("the deleted user is still in C's following[]")
		}
	}
	for _, check := range []struct {
		uid, field string
		want       int64
	}{{c.uid, "followingCount", 0}, {b.uid, "followersCount", 0}} {
		s, _ := e.fs.Doc("users/" + check.uid).Get(ctx)
		if got, _ := s.DataAt(check.field); got != check.want {
			t.Errorf("%s.%s = %v, want %d after the purge", check.uid, check.field, got, check.want)
		}
	}

	// Budgets of the work delivery (reference account: 1 post, 1 following, 1 follower, 1 export).
	var work map[string]any
	for _, l := range e.jobLines() {
		if l["outcome"] == "done" {
			work = l
		}
	}
	if work == nil {
		t.Fatalf("no `done` job line: %v", e.jobLines())
	}
	t.Logf("BUDGET account_delete work delivery (1 post, 1 following, 1 follower, 1 export) reads=%v writes=%v deletes=%v", work["fs_reads"], work["fs_writes"], work["fs_deletes"])
	// ADR-0011 budget table, P=1 O=1 I=1 E=1 W=1: reads P+O+I+2*ceil((max(B,Bb)+1)/500)+2+3+2+max(E,1)+D = 14,
	// writes O+2I+B+Bb+(W-1) = 3, deletes P+O+I+1+3+E = 8 (D = 1 here: the gated delivery's read is a separate line).
	if work["fs_reads"].(float64) > 14 || work["fs_writes"].(float64) > 3 || work["fs_deletes"].(float64) > 8 {
		t.Errorf("work delivery cost = %v, over the ADR-0011 reference-account budget (reads 14, writes 3, deletes 8)", work)
	}
	for _, l := range e.jobLines() {
		if l["uid_hash"] == a.uid || strings.Contains(fmt.Sprint(l), a.uid) {
			t.Errorf("a job line carries the raw uid: %v", l)
		}
	}
	if audit := e.logsWithMsg("auth_admin_op"); audit == "" || strings.Contains(audit, a.uid) {
		t.Errorf("audit lines missing or carrying the raw uid: %q", audit)
	}
}

// requestLinesFor returns mw.Logging's lines for an rpc procedure.
func (e *lifecycleEnv) requestLinesFor(rpc string) []map[string]any { return e.logs.requestLines(rpc) }

func (e *lifecycleEnv) logsWithMsg(msg string) string {
	e.logs.mu.Lock()
	defer e.logs.mu.Unlock()
	var out []string
	for _, line := range strings.Split(e.logs.buf.String(), "\n") {
		if strings.Contains(line, `"msg":"`+msg+`"`) {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

// TestAccountLifecycle_Suspended: a SUSPENDED user may delete their own account (Q3), every other RPC stays restricted.
func TestAccountLifecycle_Suspended(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	u := e.newUser(t)
	if _, err := e.fs.Doc("users/"+u.uid).Update(ctx, []firestore.Update{{Path: "status", Value: "SUSPENDED"}}); err != nil {
		t.Fatal(err)
	}
	e2 := &lifecycleEnv{chainEnv: newChainSharing(t, e), cfg: e.cfg, graph: e.graph, ps: e.ps, sub: e.sub, bucket: e.bucket} // a fresh instance: no cached ACTIVE profile
	_, err := e2.identity.GetMe(ctx, authed(u.token, &identityv1.GetMeRequest{}))
	wireError(t, err, connect.CodePermissionDenied)
	if _, err := e2.identity.DeleteAccount(ctx, authed(u.token, &identityv1.DeleteAccountRequest{IdempotencyKey: "suspended-delete-key-1"})); err != nil {
		t.Fatalf("a SUSPENDED user could not delete: %v", err)
	}
	snap, _ := e.fs.Doc("users/" + u.uid).Get(ctx)
	if st, _ := snap.DataAt("status"); st != "DELETING" {
		t.Errorf("status = %v, want DELETING", st)
	}
}

// newChainSharing boots a second Build against the same emulators and the same lifecycle settings as e.
func newChainSharing(t *testing.T, e *lifecycleEnv) *chainEnv {
	t.Helper()
	return newChain(t, func(c *config.Config) {
		c.FeatureAccountLifecycle = flags.Spec{Name: "account_lifecycle", Mode: flags.On}
		c.JobsTopic = e.cfg.JobsTopic
		c.ExportBucket = e.cfg.ExportBucket
	})
}

// TestAccountLifecycle_JobMessageNeverDeletesALiveUser is IAM control C1 end to end: a forged or stale job message
// naming an ACTIVE user touches nothing, not even the user's Auth record.
func TestAccountLifecycle_JobMessageNeverDeletesALiveUser(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	victim := e.newUser(t)

	for _, msg := range []map[string]any{
		{"kind": "account_delete", "uid": victim.uid, "seq": 0},
		{"kind": "account_delete", "uid": victim.uid, "seq": 7},
	} {
		if code := e.deliverJSON(t, msg); code != http.StatusNoContent {
			t.Errorf("forged message %v = %d, want 204 (ack, no retry)", msg, code)
		}
	}
	if !fsDocExists(t, e.fs, "users/"+victim.uid) {
		t.Fatal("a job message deleted a live user's document")
	}
	if present, disabled := e.authUser(t, victim.uid); !present || disabled {
		t.Errorf("a job message changed a live user's Auth record: present=%v disabled=%v", present, disabled)
	}
	if !e.logContains("auth_admin_refused") {
		t.Error("no ERROR auth_admin_refused line")
	}
	// The victim still works.
	if _, err := e.identity.GetMe(ctx, authed(victim.token, &identityv1.GetMeRequest{})); err != nil {
		t.Errorf("victim's GetMe: %v", err)
	}
}

// TestAccountLifecycle_JobEndpointNeedsAMessage: an unreadable or non-job body is acked without touching anything.
func TestAccountLifecycle_JobEndpointNeedsAMessage(t *testing.T) {
	e := newLifecycleEnv(t)
	resp, err := http.Post(e.url+"/internal/pubsub/jobs", "application/json", strings.NewReader("not json"))
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("status = %d, want 204", resp.StatusCode)
	}
	// The same route also answers under Hosting's /api prefix, and the cron route exists.
	resp, err = http.Post(e.url+"/api/internal/cron/daily-maintenance", "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("daily-maintenance status = %d, want 204", resp.StatusCode)
	}
}

// TestAccountLifecycle_ExportQuota: one export a day; a second key is RESOURCE_EXHAUSTED with metadata quota=exports,
// the same key is a replay.
func TestAccountLifecycle_ExportQuota(t *testing.T) {
	ctx := context.Background()
	e := newLifecycleEnv(t)
	u := e.newUser(t)
	first, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "quota-export-key-0001"}))
	if err != nil {
		t.Fatal(err)
	}
	replay, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "quota-export-key-0001"}))
	if err != nil || replay.Msg.GetExportId() != first.Msg.GetExportId() {
		t.Fatalf("replay = %v, %v", replay, err)
	}
	_, err = e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "quota-export-key-0002"}))
	d := wireError(t, err, connect.CodeResourceExhausted)
	if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED || d.GetMetadata()["quota"] != "exports" {
		t.Errorf("detail = %v", d)
	}
	// L-4: only the first call published. The replay came within 2 minutes of the request, so it did not re-publish
	// (no replay storm); the rejected call did not publish either.
	if msgs := e.pull(t); len(msgs) != 1 {
		t.Errorf("published %d messages, want 1", len(msgs))
	}
	// The server uses the real clock, so age the export instead of sleeping: once createdAt is 3 minutes old a replay
	// of the still-PENDING export publishes again (it recovers a lost first publish).
	if _, err := e.fs.Doc("exports/"+first.Msg.GetExportId()).Update(ctx, []firestore.Update{{Path: "createdAt", Value: time.Now().Add(-3 * time.Minute)}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.identity.RequestAccountExport(ctx, authed(u.token, &identityv1.RequestAccountExportRequest{IdempotencyKey: "quota-export-key-0001"})); err != nil {
		t.Fatal(err)
	}
	if msgs := e.pull(t); len(msgs) != 1 {
		t.Errorf("replay after 2 minutes published %d messages, want 1", len(msgs))
	}
}
