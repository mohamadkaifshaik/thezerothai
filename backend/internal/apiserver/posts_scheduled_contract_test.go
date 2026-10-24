//go:build integration

package apiserver

// Wire contract of the FEATURE_SCHEDULED_POSTS foundation (ADR-0021 D4, CMP-D2): the flag is advertised in
// GetMe.enabled_features only when on for the caller, and the three RPCs are not implemented yet, so they answer
// Unimplemented through the embedded handler whatever the flag says. The Schedule/List/Cancel service replaces
// these Unimplemented rows with its own contract tests.

import (
	"context"
	"slices"
	"testing"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestPostsContract_ScheduledPostsFlagAndUnimplemented(t *testing.T) {
	ctx := context.Background()
	token, _ := mintToken(t, "")

	for _, tt := range []struct {
		name   string
		mutate func(*config.Config)
		listed bool
	}{
		{"flag off (the default)", nil, false},
		{"flag on", func(cfg *config.Config) {
			cfg.FeatureScheduledPosts = flags.Spec{Name: "scheduled_posts", Mode: flags.On}
		}, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			env := newChain(t, tt.mutate)
			env.createProfile(t, token)
			me, err := env.identity.GetMe(ctx, authed(token, &identityv1.GetMeRequest{}))
			if err != nil {
				t.Fatalf("GetMe: %v", err)
			}
			if got := slices.Contains(me.Msg.GetEnabledFeatures(), "scheduled_posts"); got != tt.listed {
				t.Errorf("enabled_features = %v, scheduled_posts listed = %v, want %v", me.Msg.GetEnabledFeatures(), got, tt.listed)
			}

			_, err = env.posts.SchedulePost(ctx, authed(token, &postsv1.SchedulePostRequest{IdempotencyKey: contractKey("sched"), Text: "later"}))
			if connect.CodeOf(err) != connect.CodeUnimplemented {
				t.Errorf("SchedulePost: %v, want Unimplemented", err)
			}
			_, err = env.posts.ListScheduledPosts(ctx, authed(token, &postsv1.ListScheduledPostsRequest{}))
			if connect.CodeOf(err) != connect.CodeUnimplemented {
				t.Errorf("ListScheduledPosts: %v, want Unimplemented", err)
			}
			_, err = env.posts.CancelScheduledPost(ctx, authed(token, &postsv1.CancelScheduledPostRequest{IdempotencyKey: contractKey("cancel"), ScheduledId: "0123456789abcdef0123456789abcdef"}))
			if connect.CodeOf(err) != connect.CodeUnimplemented {
				t.Errorf("CancelScheduledPost: %v, want Unimplemented", err)
			}
		})
	}
}
