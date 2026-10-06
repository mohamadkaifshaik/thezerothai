//go:build integration

package apiserver

// Integration tests over the real Build chain (Firestore + Auth emulators): the helpers here (chainEnv and friends)
// are shared with posts_contract_test.go. They mirror backend/e2e's token-minting helpers, which live in another
// package's _test files and so cannot be imported.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1/identityv1connect"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func skipIfNoEmulators(t *testing.T) {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" || os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST/FIREBASE_AUTH_EMULATOR_HOST not set; run via the emulator suite")
	}
}

// mintToken signs a new Auth-emulator user up (anonymous when email is empty, else email/password, which starts
// unverified like real Firebase) and returns its ID token and uid.
func mintToken(t *testing.T, email string) (idToken, uid string) {
	t.Helper()
	body := map[string]any{"returnSecureToken": true}
	if email != "" {
		body["email"], body["password"] = email, "correct horse battery staple"
	}
	raw, _ := json.Marshal(body)
	url := fmt.Sprintf("http://%s/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key", os.Getenv("FIREBASE_AUTH_EMULATOR_HOST"))
	resp, err := http.Post(url, "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("mint token: %v", err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	var parsed struct {
		IDToken string `json:"idToken"`
		LocalID string `json:"localId"`
	}
	if resp.StatusCode != http.StatusOK || json.Unmarshal(out, &parsed) != nil {
		t.Fatalf("mint token: status %d: %s", resp.StatusCode, out)
	}
	return parsed.IDToken, parsed.LocalID
}

func uniqueHandle(prefix string) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	suffix := make([]byte, 15-len(prefix))
	for i := range suffix {
		suffix[i] = alphabet[rand.Intn(len(alphabet))]
	}
	return prefix + string(suffix)
}

func authed[T any](idToken string, msg *T) *connect.Request[T] {
	req := connect.NewRequest(msg)
	req.Header().Set("Authorization", "Bearer "+idToken)
	return req
}

// logBuf captures the API's JSON request log lines.
type logBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *logBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// requestLines are mw.Logging's one line per request for rpc, in order.
func (b *logBuf) requestLines(rpc string) []map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, line := range strings.Split(b.buf.String(), "\n") {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) == nil && rec["msg"] == "request" && rec["rpc"] == rpc {
			out = append(out, rec)
		}
	}
	return out
}

// chainEnv is one apiserver.Build handler (the production chain) on an httptest server, plus its logs.
type chainEnv struct {
	url      string
	fs       *firestore.Client
	logs     *logBuf
	identity identityv1connect.IdentityServiceClient
	posts    postsv1connect.PostServiceClient
	timeline timelinev1connect.TimelineServiceClient
}

// newChain boots Build against the running emulators with FEATURE_POSTS on (mutate may change anything).
func newChain(t *testing.T, mutate func(*config.Config)) *chainEnv {
	t.Helper()
	skipIfNoEmulators(t)
	cfg, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	cfg.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.On}
	if mutate != nil {
		mutate(&cfg)
	}
	logs := &logBuf{}
	handler, fsClient, err := Build(context.Background(), cfg, slog.New(slog.NewJSONHandler(logs, &slog.HandlerOptions{Level: slog.LevelInfo})))
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	srv := httptest.NewServer(handler)
	t.Cleanup(func() { srv.Close(); _ = fsClient.Close() })
	return &chainEnv{
		url: srv.URL, fs: fsClient, logs: logs,
		identity: identityv1connect.NewIdentityServiceClient(srv.Client(), srv.URL),
		posts:    postsv1connect.NewPostServiceClient(srv.Client(), srv.URL),
		timeline: timelinev1connect.NewTimelineServiceClient(srv.Client(), srv.URL),
	}
}

// createProfile gives idToken's uid a profile through this chain.
func (e *chainEnv) createProfile(t *testing.T, idToken string) {
	t.Helper()
	if _, err := e.identity.CreateProfile(context.Background(), authed(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: fmt.Sprintf("apiserver-test-profile-%d", rand.Int63()),
		Handle:         uniqueHandle("ap"),
		DisplayName:    "Apiserver Test",
	})); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
}

// wireError asserts err is a Connect error with code, and returns its decoded ErrorDetail (never nil).
func wireError(t *testing.T, err error, code connect.Code) *commonv1.ErrorDetail {
	t.Helper()
	if err == nil {
		t.Fatalf("got no error, want %v", code)
	}
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		t.Fatalf("error is %T, want *connect.Error", err)
	}
	if cerr.Code() != code {
		t.Fatalf("code = %v (%v), want %v", cerr.Code(), err, code)
	}
	for _, d := range cerr.Details() {
		if msg, derr := d.Value(); derr == nil {
			if detail, ok := msg.(*commonv1.ErrorDetail); ok {
				return detail
			}
		}
	}
	t.Fatalf("error %v carries no dzeroth.common.v1.ErrorDetail", err)
	return nil
}

// TestPosts_SuspendedAndDeletingCallers_AreRestrictedOnEveryRPC (audit item 5, ADR-0010 D6 last row): through the
// real chain, a SUSPENDED or DELETING caller gets PERMISSION_DENIED + ACCOUNT_RESTRICTED from CreatePost,
// DeletePost, GetPost and both timelines. The account-status interceptor answers before any handler, so each call
// costs at most that interceptor's single users/{uid} read and creates nothing.
func TestPosts_SuspendedAndDeletingCallers_AreRestrictedOnEveryRPC(t *testing.T) {
	ctx := context.Background()
	setup := newChain(t, nil)

	for _, status := range []string{"SUSPENDED", "DELETING"} {
		t.Run(status, func(t *testing.T) {
			idToken, uid := mintToken(t, "")
			setup.createProfile(t, idToken)
			if _, err := setup.fs.Collection("users").Doc(uid).Update(ctx, []firestore.Update{{Path: "status", Value: status}}); err != nil {
				t.Fatalf("set status: %v", err)
			}
			env := newChain(t, nil) // a fresh instance: no cached ACTIVE profile for this uid

			calls := []struct {
				rpc  string
				call func() error
			}{
				{postsv1connect.PostServiceCreatePostProcedure, func() error {
					_, err := env.posts.CreatePost(ctx, authed(idToken, &postsv1.CreatePostRequest{IdempotencyKey: "restricted-create-key-0001", Text: "hello"}))
					return err
				}},
				{postsv1connect.PostServiceDeletePostProcedure, func() error {
					_, err := env.posts.DeletePost(ctx, authed(idToken, &postsv1.DeletePostRequest{IdempotencyKey: "restricted-delete-key-0001", PostId: "0000000000000000001"}))
					return err
				}},
				{postsv1connect.PostServiceGetPostProcedure, func() error {
					_, err := env.posts.GetPost(ctx, authed(idToken, &postsv1.GetPostRequest{PostId: "0000000000000000001"}))
					return err
				}},
				{timelinev1connect.TimelineServiceGetHomeTimelineProcedure, func() error {
					_, err := env.timeline.GetHomeTimeline(ctx, authed(idToken, &timelinev1.GetHomeTimelineRequest{}))
					return err
				}},
				{timelinev1connect.TimelineServiceGetUserTimelineProcedure, func() error {
					_, err := env.timeline.GetUserTimeline(ctx, authed(idToken, &timelinev1.GetUserTimelineRequest{UserId: uid}))
					return err
				}},
			}
			for _, c := range calls {
				d := wireError(t, c.call(), connect.CodePermissionDenied)
				if d.GetReason() != commonv1.ErrorReason_ERROR_REASON_ACCOUNT_RESTRICTED {
					t.Errorf("%s: reason = %v, want ACCOUNT_RESTRICTED", c.rpc, d.GetReason())
				}
				lines := env.logs.requestLines(c.rpc)
				if len(lines) != 1 {
					t.Fatalf("%s: %d request lines, want 1", c.rpc, len(lines))
				}
				// Past the interceptor nothing runs, so the only read a call may log is the status lookup itself.
				if reads, _ := lines[0]["fs_reads"].(float64); reads > 1 {
					t.Errorf("%s: fs_reads = %v, want <= 1 (the interceptor's users read only)", c.rpc, reads)
				}
				if writes, _ := lines[0]["fs_writes"].(float64); writes != 0 {
					t.Errorf("%s: fs_writes = %v, want 0", c.rpc, writes)
				}
			}

			// Rejected CreatePost must not have created anything.
			n, err := setup.fs.Collection("posts").Where("authorId", "==", uid).Limit(1).Documents(ctx).GetAll()
			if err != nil {
				t.Fatalf("count posts: %v", err)
			}
			if len(n) != 0 {
				t.Errorf("a %s caller's CreatePost stored %d post(s), want 0", status, len(n))
			}
		})
	}
}
