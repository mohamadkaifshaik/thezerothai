//go:build integration

package e2e

// T21 (docs/plans/posts-and-timeline.md): posts + timeline E2E smoke. Same two modes as graph_smoke_test.go,
// reusing its setup (setupGraphSmoke), idemKey and eventually helpers:
//
//   - Emulator mode (default, `make test-int`): boots the real handler with FEATURE_POSTS and FEATURE_GRAPH set
//     to "on" explicitly (config.Load reads them from the environment) and creates two fresh users.
//   - Remote mode (prod `candidate` / dev URL): set E2E_POSTS_BASE_URL plus E2E_POSTS_ID_TOKEN_A and
//     E2E_POSTS_ID_TOKEN_B (two pre-provisioned smoke accounts with profiles, on the FEATURE_POSTS and
//     FEATURE_GRAPH allowlists).
//
// Budget: about 20 requests per run (well under the < 100-request prod smoke cap). The test always leaves
// no follow edge and no live post behind, so it is re-runnable.

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"testing"

	"connectrpc.com/connect"

	graphv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/graph/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
)

func TestE2E_PostsSmoke_FollowPostTimelinesDelete(t *testing.T) {
	// Map the posts remote-mode variables onto the graph ones so setupGraphSmoke is reused unchanged; in
	// emulator mode pin both flags on rather than relying on the local default.
	baseURL := os.Getenv("E2E_POSTS_BASE_URL")
	if baseURL != "" {
		t.Setenv("E2E_GRAPH_BASE_URL", baseURL)
		t.Setenv("E2E_GRAPH_ID_TOKEN_A", os.Getenv("E2E_POSTS_ID_TOKEN_A"))
		t.Setenv("E2E_GRAPH_ID_TOKEN_B", os.Getenv("E2E_POSTS_ID_TOKEN_B"))
	} else {
		t.Setenv("FEATURE_POSTS", "on")
		t.Setenv("FEATURE_GRAPH", "on")
	}
	env := setupGraphSmoke(t)
	ctx := context.Background()

	// setupGraphSmoke does not expose its server URL in emulator mode, so boot a second handler against the
	// same emulator project (same env flags, stateless apart from in-process caches).
	if baseURL == "" {
		_, baseURL = newTestServerCfg(t, nil)
	}
	posts := postsv1connect.NewPostServiceClient(http.DefaultClient, baseURL)
	timeline := timelinev1connect.NewTimelineServiceClient(http.DefaultClient, baseURL)

	var postID string
	deleted := false
	t.Cleanup(func() {
		if postID != "" && !deleted {
			if _, err := posts.DeletePost(ctx, authedRequest(env.tokenB, &postsv1.DeletePostRequest{IdempotencyKey: idemKey("cleanup-delete"), PostId: postID})); err != nil && connect.CodeOf(err) != connect.CodeNotFound {
				t.Errorf("cleanup DeletePost: %v", err)
			}
		}
		if _, err := env.graph.Unfollow(ctx, authedRequest(env.tokenA, &graphv1.UnfollowRequest{IdempotencyKey: idemKey("cleanup-unfollow"), UserId: env.uidB})); err != nil {
			t.Errorf("cleanup Unfollow(A->B): %v", err)
		}
	})

	// Pre-clean a leftover follow from an aborted earlier run (no-op on a clean state).
	if _, err := env.graph.Unfollow(ctx, authedRequest(env.tokenA, &graphv1.UnfollowRequest{IdempotencyKey: idemKey("pre-unfollow"), UserId: env.uidB})); err != nil {
		t.Fatalf("pre-clean Unfollow: %v", err)
	}

	// 1. A follows B.
	if _, err := env.graph.Follow(ctx, authedRequest(env.tokenA, &graphv1.FollowRequest{IdempotencyKey: idemKey("follow"), UserId: env.uidB})); err != nil {
		t.Fatalf("Follow(A->B): %v", err)
	}

	// 2. B posts.
	text := fmt.Sprintf("posts smoke %s", idemKey("text"))
	created, err := posts.CreatePost(ctx, authedRequest(env.tokenB, &postsv1.CreatePostRequest{IdempotencyKey: idemKey("create"), Text: text}))
	if err != nil {
		t.Fatalf("CreatePost(B): %v", err)
	}
	postID = created.Msg.GetPost().GetPost().GetPostId()
	if postID == "" {
		t.Fatal("CreatePost returned an empty post_id")
	}
	if got := created.Msg.GetPost().GetPost().GetText(); got != text {
		t.Fatalf("CreatePost text = %q, want %q", got, text)
	}

	// 3. A's home refresh contains it.
	env.eventually(t, "A's home timeline contains B's post", func() (bool, string) {
		resp, err := timeline.GetHomeTimeline(ctx, authedRequest(env.tokenA, &timelinev1.GetHomeTimelineRequest{PageSize: 20}))
		if err != nil {
			t.Fatalf("GetHomeTimeline(A): %v", err)
		}
		for _, p := range resp.Msg.GetPosts() {
			if p.GetPost().GetPostId() == postID {
				return true, ""
			}
		}
		return false, fmt.Sprintf("post %s not among %d home posts", postID, len(resp.Msg.GetPosts()))
	})

	// 4. B's profile timeline contains it (viewed by A).
	env.eventually(t, "B's profile timeline contains the post", func() (bool, string) {
		resp, err := timeline.GetUserTimeline(ctx, authedRequest(env.tokenA, &timelinev1.GetUserTimelineRequest{UserId: env.uidB, PageSize: 20}))
		if err != nil {
			t.Fatalf("GetUserTimeline(B) as A: %v", err)
		}
		for _, p := range resp.Msg.GetPosts() {
			if p.GetPost().GetPostId() == postID {
				return true, ""
			}
		}
		return false, fmt.Sprintf("post %s not among %d profile posts", postID, len(resp.Msg.GetPosts()))
	})

	// Sanity: before the delete, A can read the post.
	if _, err := posts.GetPost(ctx, authedRequest(env.tokenA, &postsv1.GetPostRequest{PostId: postID})); err != nil {
		t.Fatalf("GetPost as A before delete: %v", err)
	}

	// 5. B deletes it.
	if _, err := posts.DeletePost(ctx, authedRequest(env.tokenB, &postsv1.DeletePostRequest{IdempotencyKey: idemKey("delete"), PostId: postID})); err != nil {
		t.Fatalf("DeletePost(B): %v", err)
	}
	deleted = true

	// 6. A's GetPost is NOT_FOUND.
	env.eventually(t, "GetPost as A is NOT_FOUND after delete", func() (bool, string) {
		_, err := posts.GetPost(ctx, authedRequest(env.tokenA, &postsv1.GetPostRequest{PostId: postID}))
		if err == nil {
			return false, "GetPost still succeeds after delete"
		}
		if connect.CodeOf(err) != connect.CodeNotFound {
			t.Fatalf("GetPost as A after delete: code %v (%v), want NOT_FOUND", connect.CodeOf(err), err)
		}
		return true, ""
	})

	// 7. Clean-up runs in t.Cleanup (post already deleted; Unfollow A->B).
}
