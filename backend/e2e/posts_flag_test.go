//go:build integration

package e2e

import (
	"context"
	"net/http"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1/postsv1connect"
	timelinev1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/timeline/v1/timelinev1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// TestE2E_PostsFlag_BuildLevel (T5): through apiserver.Build, the real interceptor chain and the real flag
// registry, a caller with a profile gets FEATURE_DISABLED from PostService and TimelineService while
// FEATURE_POSTS is off, and the real handlers (an unknown post is NOT_FOUND) once it is on. It proves both services
// are registered in Build and behind the flag.
func TestE2E_PostsFlag_BuildLevel(t *testing.T) {
	skipIfNoEmulators(t)
	idToken, _ := newAnonymousIDToken(t)

	offIdentity, offURL := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.Off}
	})
	if _, err := offIdentity.CreateProfile(context.Background(), authedRequest(idToken, &identityv1.CreateProfileRequest{
		IdempotencyKey: "e2e-posts-flag-create-profile",
		Handle:         uniqueHandle("pf"),
		DisplayName:    "Flag Test",
	})); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	posts := postsv1connect.NewPostServiceClient(http.DefaultClient, offURL)
	timeline := timelinev1connect.NewTimelineServiceClient(http.DefaultClient, offURL)
	ctx := context.Background()

	_, err := posts.GetPost(ctx, authedRequest(idToken, &postsv1.GetPostRequest{PostId: "0000000000000000001"}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
	_, err = timeline.GetHomeTimeline(ctx, authedRequest(idToken, &timelinev1.GetHomeTimelineRequest{}))
	assertErrorReason(t, err, connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)

	// Flag on, same Firestore project (same caller, same profile): the call reaches the handler.
	_, onURL := newTestServerCfg(t, func(cfg *config.Config) {
		cfg.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.On}
	})
	onPosts := postsv1connect.NewPostServiceClient(http.DefaultClient, onURL)
	_, err = onPosts.GetPost(ctx, authedRequest(idToken, &postsv1.GetPostRequest{PostId: "0000000000000000001"}))
	assertCode(t, err, connect.CodeNotFound) // the real handler ran: no such post
}
