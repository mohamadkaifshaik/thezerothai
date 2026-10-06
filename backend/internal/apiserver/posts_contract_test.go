//go:build integration

package apiserver

// Wire-level contract tests for the documented CreatePost error reasons (audit item 13, ADR-0010 D1/D2), over the
// real Build chain: Connect code, dzeroth.common.v1.ErrorDetail.reason and metadata exactly as a client decodes
// them. Helpers come from posts_restricted_test.go.
//
// Goldens: the repo has no golden-file convention for RPC responses (the only "golden" is a cursor unit test), so
// no golden JSON is added for the happy responses.

import (
	"context"
	"fmt"
	"math/rand"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func contractKey(op string) string { return fmt.Sprintf("contract-%s-%d", op, rand.Int63()) }

func assertReason(t *testing.T, d *commonv1.ErrorDetail, want commonv1.ErrorReason) {
	t.Helper()
	if d.GetReason() != want {
		t.Fatalf("reason = %v, want %v", d.GetReason(), want)
	}
}

// TestPostsContract_NotVerifiedAndNoProfile: an unverified email/password caller never gets past the identity
// gate. On the profile-exempt CheckHandleAvailability that is EMAIL_NOT_VERIFIED; on CreatePost the gate answers
// PROFILE_REQUIRED (A2), so CreatePost's own EMAIL_NOT_VERIFIED is defence in depth that the production chain
// cannot reach (covered at service level). A verified-gate caller with no profile gets PROFILE_REQUIRED too. None
// of these carry metadata or a retry hint.
func TestPostsContract_NotVerifiedAndNoProfile(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, nil)
	unverified, _ := mintToken(t, fmt.Sprintf("contract-unverified-%d@example.com", rand.Int63()))
	noProfile, _ := mintToken(t, "")
	create := &postsv1.CreatePostRequest{IdempotencyKey: contractKey("noprof"), Text: "hello"}

	t.Run("EMAIL_NOT_VERIFIED on an exempt procedure", func(t *testing.T) {
		_, err := env.identity.CheckHandleAvailability(ctx, authed(unverified, &identityv1.CheckHandleAvailabilityRequest{Handle: uniqueHandle("ct")}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_EMAIL_NOT_VERIFIED)
		if len(d.GetMetadata()) != 0 {
			t.Errorf("metadata = %v, want none", d.GetMetadata())
		}
	})
	t.Run("unverified caller on CreatePost is PROFILE_REQUIRED from the gate", func(t *testing.T) {
		_, err := env.posts.CreatePost(ctx, authed(unverified, create))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
		if len(d.GetMetadata()) != 0 {
			t.Errorf("metadata = %v, want none", d.GetMetadata())
		}
	})
	t.Run("PROFILE_REQUIRED without a profile", func(t *testing.T) {
		_, err := env.posts.CreatePost(ctx, authed(noProfile, create))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED)
		if len(d.GetMetadata()) != 0 {
			t.Errorf("metadata = %v, want none", d.GetMetadata())
		}
	})
}

// TestPostsContract_QuotaExceeded: with a 1-post daily quota the second distinct CreatePost is
// RESOURCE_EXHAUSTED + QUOTA_EXCEEDED, metadata quota=posts, with a retry_after hint.
func TestPostsContract_QuotaExceeded(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, func(cfg *config.Config) {
		cfg.Quota.PostsPerDay = 1
		cfg.Quota.NewAccountPostsPerDay = 1
	})
	token, _ := mintToken(t, "")
	env.createProfile(t, token)

	if _, err := env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("q1"), Text: "first"})); err != nil {
		t.Fatalf("first CreatePost: %v", err)
	}
	_, err := env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("q2"), Text: "second"}))
	d := wireError(t, err, connect.CodeResourceExhausted)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_QUOTA_EXCEEDED)
	if d.GetMetadata()["quota"] != "posts" {
		t.Errorf("metadata = %v, want quota=posts", d.GetMetadata())
	}
	// Known production gap (proto common ErrorDetail: retry_after is "set for RATE_LIMITED / QUOTA_EXCEEDED"):
	// quota.CheckAndReserve (pkg/platform/quota/quota.go:141-145) sets no retry_after. This assertion fails until fixed.
	if d.GetRetryAfter().AsDuration() <= 0 {
		t.Errorf("retry_after = %v, want a positive time to the next quota day", d.GetRetryAfter().AsDuration())
	}
}

// TestPostsContract_IdempotencyKeyReused: the same key with a different body is INVALID_ARGUMENT +
// IDEMPOTENCY_KEY_REUSED; the same key with the same body replays the stored post (same id).
func TestPostsContract_IdempotencyKeyReused(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, nil)
	token, _ := mintToken(t, "")
	env.createProfile(t, token)

	key := contractKey("idem")
	first, err := env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: "original"}))
	if err != nil {
		t.Fatalf("CreatePost: %v", err)
	}
	replay, err := env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: "original"}))
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if replay.Msg.GetPost().GetPost().GetPostId() != first.Msg.GetPost().GetPost().GetPostId() || first.Msg.GetPost().GetPost().GetPostId() == "" {
		t.Errorf("replay id %q, want the first call's id %q", replay.Msg.GetPost().GetPost().GetPostId(), first.Msg.GetPost().GetPost().GetPostId())
	}

	_, err = env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: key, Text: "a different body"}))
	d := wireError(t, err, connect.CodeInvalidArgument)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED)
}

// TestPostsContract_FeatureDisabled: a sub-feature rejection carries metadata feature=replies|quotes|media; the
// service-level flag off is FEATURE_DISABLED without any feature metadata. Both are FAILED_PRECONDITION.
func TestPostsContract_FeatureDisabled(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, nil)
	token, _ := mintToken(t, "")
	env.createProfile(t, token)

	tests := []struct {
		name        string
		req         *postsv1.CreatePostRequest
		wantFeature string
	}{
		{"replies", &postsv1.CreatePostRequest{Text: "r", ReplyToPostId: "0000000000000000001"}, "replies"},
		{"quotes", &postsv1.CreatePostRequest{Text: "q", QuoteOfPostId: "0000000000000000001"}, "quotes"},
		{"media", &postsv1.CreatePostRequest{Text: "m", MediaIds: []string{"0000000000000000001"}}, "media"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.req.IdempotencyKey = contractKey("fd-" + tt.name)
			_, err := env.posts.CreatePost(ctx, authed(token, tt.req))
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if got := d.GetMetadata()["feature"]; got != tt.wantFeature {
				t.Errorf("metadata feature = %q, want %q (metadata %v)", got, tt.wantFeature, d.GetMetadata())
			}
		})
	}

	t.Run("whole service off", func(t *testing.T) {
		off := newChain(t, func(cfg *config.Config) { cfg.FeaturePosts = flags.Spec{Name: "posts", Mode: flags.Off} })
		_, err := off.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("fd-off"), Text: "hi"}))
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if _, has := d.GetMetadata()["feature"]; has {
			t.Errorf("metadata = %v, want no feature key for the whole service", d.GetMetadata())
		}
	})
}
