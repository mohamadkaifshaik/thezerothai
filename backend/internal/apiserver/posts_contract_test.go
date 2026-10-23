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
		{"content_disclosure paid", &postsv1.CreatePostRequest{Text: "d", PaidPartnership: true}, "content_disclosure"},
		{"content_disclosure ai", &postsv1.CreatePostRequest{Text: "d", MadeWithAi: true}, "content_disclosure"},
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

	// FEATURE_QUOTES matrix through the real handler: quote creation needs quotes AND engagement for the caller.
	t.Run("quotes matrix", func(t *testing.T) {
		on := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.On} }
		off := func(n string) flags.Spec { return flags.Spec{Name: n, Mode: flags.Off} }
		cases := []struct {
			name              string
			engagement, quote func(string) flags.Spec
		}{
			{"engagement on, quotes off", on, off},
			{"engagement off, quotes on", off, on},
			{"both off", off, off},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				e := newChain(t, func(cfg *config.Config) {
					cfg.FeatureEngagement, cfg.FeatureQuotes = c.engagement("engagement"), c.quote("quotes")
				})
				tok, _ := mintToken(t, "")
				e.createProfile(t, tok)
				_, err := e.posts.CreatePost(ctx, authed(tok, &postsv1.CreatePostRequest{
					IdempotencyKey: contractKey("fd-q-" + c.name), Text: "q", QuoteOfPostId: "0000000000000000001"}))
				d := wireError(t, err, connect.CodeFailedPrecondition)
				assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
				if got := d.GetMetadata()["feature"]; got != "quotes" {
					t.Errorf("metadata feature = %q, want quotes (%v)", got, d.GetMetadata())
				}
			})
		}
		// Both on: the flag gate passes and the request reaches the quote-target check (a missing target is
		// NOT_FOUND, never FEATURE_DISABLED).
		e := newChain(t, func(cfg *config.Config) {
			cfg.FeatureEngagement, cfg.FeatureQuotes = on("engagement"), on("quotes")
		})
		tok, _ := mintToken(t, "")
		e.createProfile(t, tok)
		_, err := e.posts.CreatePost(ctx, authed(tok, &postsv1.CreatePostRequest{
			IdempotencyKey: contractKey("fd-q-both-on"), Text: "q", QuoteOfPostId: "0000000000000000001"}))
		d := wireError(t, err, connect.CodeNotFound)
		if d.GetReason() == commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED {
			t.Errorf("both flags on still answered FEATURE_DISABLED: %v", d)
		}
	})

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

// TestPostsContract_FeatureDisabledReplyAudience: the reply_audience rows of the FEATURE_DISABLED contract (ADR-0021
// D2). Any reply_policy other than UNSPECIFIED is refused while the flag is off, after media and before disclosure.
// A separate caller from TestPostsContract_FeatureDisabled keeps both tables under the per-user rate limit.
func TestPostsContract_FeatureDisabledReplyAudience(t *testing.T) {
	ctx := context.Background()
	env := newChain(t, nil)
	token, _ := mintToken(t, "")
	env.createProfile(t, token)

	tests := []struct {
		name        string
		req         *postsv1.CreatePostRequest
		wantFeature string
	}{
		{"reply_audience following", &postsv1.CreatePostRequest{Text: "a", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING}, "reply_audience"},
		{"reply_audience mentioned only", &postsv1.CreatePostRequest{Text: "a", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY}, "reply_audience"},
		{"reply_audience everyone is still a set", &postsv1.CreatePostRequest{Text: "a", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_EVERYONE}, "reply_audience"},
		{"reply_audience unavailable value", &postsv1.CreatePostRequest{Text: "a", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_VERIFIED}, "reply_audience"},
		{"media beats reply_audience", &postsv1.CreatePostRequest{Text: "a", MediaIds: []string{"0000000000000000001"}, ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING}, "media"},
		{"reply_audience beats content_disclosure", &postsv1.CreatePostRequest{Text: "a", PaidPartnership: true, ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING}, "reply_audience"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.req.IdempotencyKey = contractKey("fd-ra-" + tt.name)
			_, err := env.posts.CreatePost(ctx, authed(token, tt.req))
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if got := d.GetMetadata()["feature"]; got != tt.wantFeature {
				t.Errorf("metadata feature = %q, want %q (metadata %v)", got, tt.wantFeature, d.GetMetadata())
			}
		})
	}
}

// TestPostsContract_ReplyAudience: over the real chain, FEATURE_REPLY_AUDIENCE lists `reply_audience` in
// enabled_features only when on, a MENTIONED_ONLY root refuses a stranger's reply with PERMISSION_DENIED +
// REPLY_NOT_ALLOWED + metadata policy=mentioned_only, the root's author may reply, and switching the flag off
// does not reopen the conversation (enforcement is not flag-gated).
func TestPostsContract_ReplyAudience(t *testing.T) {
	ctx := context.Background()
	on := func(cfg *config.Config) {
		cfg.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
		cfg.FeatureReplyAudience = flags.Spec{Name: "reply_audience", Mode: flags.On}
	}
	env := newChain(t, on)
	author, _ := mintToken(t, "")
	stranger, _ := mintToken(t, "")
	env.createProfile(t, author)
	env.createProfile(t, stranger)

	me, err := env.identity.GetMe(ctx, authed(author, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if got := me.Msg.GetEnabledFeatures(); !containsString(got, "reply_audience") {
		t.Errorf("enabled_features with the flag on = %v, want reply_audience", got)
	}

	root, err := env.posts.CreatePost(ctx, authed(author, &postsv1.CreatePostRequest{
		IdempotencyKey: contractKey("ra-root"), Text: "just for the mentioned", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY}))
	if err != nil {
		t.Fatalf("CreatePost with a policy: %v", err)
	}
	rootID := root.Msg.GetPost().GetPost().GetPostId()
	if got := root.Msg.GetPost().GetPost().GetReplyPolicy(); got != postsv1.ReplyPolicy_REPLY_POLICY_MENTIONED_ONLY {
		t.Fatalf("echoed reply_policy = %v", got)
	}

	reply := func(token, key string) error {
		_, err := env.posts.CreatePost(ctx, authed(token, &postsv1.CreatePostRequest{IdempotencyKey: contractKey(key), Text: "reply", ReplyToPostId: rootID}))
		return err
	}
	d := wireError(t, reply(stranger, "ra-stranger"), connect.CodePermissionDenied)
	assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_REPLY_NOT_ALLOWED)
	if d.GetMetadata()["policy"] != "mentioned_only" {
		t.Errorf("metadata = %v, want policy=mentioned_only", d.GetMetadata())
	}
	if err := reply(author, "ra-author"); err != nil {
		t.Fatalf("the root author's own reply: %v", err)
	}

	got, err := env.posts.GetPost(ctx, authed(stranger, &postsv1.GetPostRequest{PostId: rootID}))
	if err != nil {
		t.Fatalf("GetPost: %v", err)
	}
	if h := got.Msg.GetPost().GetViewerReplyPermission(); h != postsv1.ReplyPermission_REPLY_PERMISSION_NOT_ALLOWED {
		t.Errorf("stranger's hint on the MENTIONED_ONLY root = %v, want NOT_ALLOWED", h)
	}

	// Flag off: no new policies, but the stored one is still enforced, and the list no longer names the feature.
	off := newChain(t, func(cfg *config.Config) {
		cfg.FeatureReplies = flags.Spec{Name: "replies", Mode: flags.On}
	})
	me, err = off.identity.GetMe(ctx, authed(author, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe (off): %v", err)
	}
	if got := me.Msg.GetEnabledFeatures(); containsString(got, "reply_audience") {
		t.Errorf("enabled_features with the flag off = %v, want no reply_audience", got)
	}
	_, err = off.posts.CreatePost(ctx, authed(stranger, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("ra-off"), Text: "reply", ReplyToPostId: rootID}))
	assertReason(t, wireError(t, err, connect.CodePermissionDenied), commonv1.ErrorReason_ERROR_REASON_REPLY_NOT_ALLOWED)
	_, err = off.posts.CreatePost(ctx, authed(author, &postsv1.CreatePostRequest{
		IdempotencyKey: contractKey("ra-off-set"), Text: "x", ReplyPolicy: postsv1.ReplyPolicy_REPLY_POLICY_FOLLOWING}))
	d = wireError(t, err, connect.CodeFailedPrecondition)
	if d.GetMetadata()["feature"] != "reply_audience" {
		t.Errorf("metadata = %v, want feature=reply_audience", d.GetMetadata())
	}
}

func containsString(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
