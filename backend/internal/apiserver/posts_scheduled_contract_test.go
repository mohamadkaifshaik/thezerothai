//go:build integration

package apiserver

// Wire contract of scheduled posts (ADR-0021 D4, CMP-D2/D3) over the real Build chain: the flag is advertised in
// GetMe.enabled_features only when on for the caller; with it off the three RPCs answer FAILED_PRECONDITION +
// FEATURE_DISABLED (metadata feature=scheduled_posts); with it on a caller can schedule, list and cancel, a replay
// returns the same item, and another user's id is NOT_FOUND. Helpers come from posts_contract_test.go.

import (
	"context"
	"slices"
	"testing"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestPostsContract_ScheduledPostsFlagOff(t *testing.T) {
	ctx := context.Background()
	token, _ := mintToken(t, "")
	env := newChain(t, nil)
	env.createProfile(t, token)

	me, err := env.identity.GetMe(ctx, authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if slices.Contains(me.Msg.GetEnabledFeatures(), "scheduled_posts") {
		t.Errorf("enabled_features = %v lists scheduled_posts with the flag off", me.Msg.GetEnabledFeatures())
	}

	at := timestamppb.New(time.Now().Add(time.Hour))
	calls := map[string]error{}
	_, calls["SchedulePost"] = env.posts.SchedulePost(ctx, authed(token, &postsv1.SchedulePostRequest{IdempotencyKey: contractKey("sched"), Text: "later", PublishAt: at}))
	_, calls["ListScheduledPosts"] = env.posts.ListScheduledPosts(ctx, authed(token, &postsv1.ListScheduledPostsRequest{}))
	_, calls["CancelScheduledPost"] = env.posts.CancelScheduledPost(ctx, authed(token, &postsv1.CancelScheduledPostRequest{IdempotencyKey: contractKey("cancel"), ScheduledId: "0123456789abcdef0123456789abcdef"}))
	for name, err := range calls {
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if d.GetMetadata()["feature"] != "scheduled_posts" {
			t.Errorf("%s: metadata = %v, want feature=scheduled_posts", name, d.GetMetadata())
		}
	}
}

func TestPostsContract_ScheduledPostsHappyPath(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, func(cfg *config.Config) {
		cfg.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
	})
	token, _ := mintToken(t, "")
	env.createProfile(t, token)
	other, _ := mintToken(t, "")
	env.createProfile(t, other)

	me, err := env.identity.GetMe(ctx, authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if !slices.Contains(me.Msg.GetEnabledFeatures(), "scheduled_posts") {
		t.Errorf("enabled_features = %v, want scheduled_posts listed with the flag on", me.Msg.GetEnabledFeatures())
	}

	req := &postsv1.SchedulePostRequest{
		IdempotencyKey: contractKey("sched"), Text: "later",
		PublishAt: timestamppb.New(time.Now().Add(3 * time.Hour).Add(17 * time.Second)),
	}
	first, err := env.posts.SchedulePost(ctx, authed(token, req))
	if err != nil {
		t.Fatalf("SchedulePost: %v", err)
	}
	item := first.Msg.GetScheduledPost()
	if len(item.GetScheduledId()) != 32 || item.GetStatus() != postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_PENDING || item.GetText() != "later" {
		t.Fatalf("scheduled post = %v", item)
	}
	if got := item.GetPublishAt().AsTime(); got.Second() != 0 || got.Nanosecond() != 0 {
		t.Errorf("publish_at = %v, want truncated to the minute", got)
	}

	replay, err := env.posts.SchedulePost(ctx, authed(token, req))
	if err != nil || replay.Msg.GetScheduledPost().GetScheduledId() != item.GetScheduledId() {
		t.Fatalf("replay = %v, %v; want the same item", replay, err)
	}
	_, err = env.posts.SchedulePost(ctx, authed(token, &postsv1.SchedulePostRequest{IdempotencyKey: req.GetIdempotencyKey(), Text: "other", PublishAt: req.GetPublishAt()}))
	assertReason(t, wireError(t, err, connect.CodeInvalidArgument), commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)

	// Too soon is a validation error that names publish_at.
	_, err = env.posts.SchedulePost(ctx, authed(token, &postsv1.SchedulePostRequest{IdempotencyKey: contractKey("soon"), Text: "now", PublishAt: timestamppb.New(time.Now().Add(30 * time.Second))}))
	d := wireError(t, err, connect.CodeInvalidArgument)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)
	if d.GetMetadata()["field"] != "publish_at" {
		t.Errorf("metadata = %v, want field=publish_at", d.GetMetadata())
	}

	list, err := env.posts.ListScheduledPosts(ctx, authed(token, &postsv1.ListScheduledPostsRequest{}))
	if err != nil || len(list.Msg.GetScheduledPosts()) != 1 || list.Msg.GetScheduledPosts()[0].GetScheduledId() != item.GetScheduledId() {
		t.Fatalf("list = %v, %v", list, err)
	}
	if theirs, err := env.posts.ListScheduledPosts(ctx, authed(other, &postsv1.ListScheduledPostsRequest{})); err != nil || len(theirs.Msg.GetScheduledPosts()) != 0 {
		t.Fatalf("another user's list = %v, %v", theirs, err)
	}

	// Another user's id and a malformed id.
	_, err = env.posts.CancelScheduledPost(ctx, authed(other, &postsv1.CancelScheduledPostRequest{IdempotencyKey: contractKey("c0"), ScheduledId: item.GetScheduledId()}))
	wireError(t, err, connect.CodeNotFound)
	_, err = env.posts.CancelScheduledPost(ctx, authed(token, &postsv1.CancelScheduledPostRequest{IdempotencyKey: contractKey("c1"), ScheduledId: "NOT-A-HEX-ID"}))
	d = wireError(t, err, connect.CodeInvalidArgument)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_VALIDATION)

	cancelled, err := env.posts.CancelScheduledPost(ctx, authed(token, &postsv1.CancelScheduledPostRequest{IdempotencyKey: contractKey("c2"), ScheduledId: item.GetScheduledId()}))
	if err != nil || cancelled.Msg.GetScheduledPost().GetStatus() != postsv1.ScheduledPostStatus_SCHEDULED_POST_STATUS_CANCELLED {
		t.Fatalf("cancel = %v, %v", cancelled, err)
	}
	list, err = env.posts.ListScheduledPosts(ctx, authed(token, &postsv1.ListScheduledPostsRequest{}))
	if err != nil || len(list.Msg.GetScheduledPosts()) != 0 {
		t.Fatalf("list after cancel = %v, %v; want empty (CANCELLED is not listed)", list, err)
	}
}
