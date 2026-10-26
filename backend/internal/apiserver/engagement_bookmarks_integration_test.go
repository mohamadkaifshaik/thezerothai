//go:build integration

package apiserver

// Wire contract of the bookmark flag gate (ADR-0023 D5, ticket W2-2) over the real Build chain: GetMe.enabled_features
// lists "bookmarks" only for the allowlisted caller; with the flag off all three RPCs answer FAILED_PRECONDITION +
// FEATURE_DISABLED (metadata feature=bookmarks) with 0 Firestore reads; in allowlist mode a caller outside the list is
// refused AddBookmark only, while Remove and List pass the gate (a passed gate shows as INVALID_ARGUMENT from Add and Remove,
// whose placeholder post id fails validation with 0 reads, and as Unimplemented from List until W2-4). Helpers come from
// posts_contract_test.go and posts_restricted_test.go.

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	engagementv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/engagement/v1/engagementv1connect"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// passedGate reports whether err shows the flag gate was passed: Add and Remove then reject the placeholder post id as
// INVALID_ARGUMENT, ListBookmarks answers Unimplemented until W2-4.
func passedGate(rpc string, err error) bool {
	if rpc == "ListBookmarks" {
		return connect.CodeOf(err) == connect.CodeUnimplemented
	}
	return connect.CodeOf(err) == connect.CodeInvalidArgument
}

func bookmarkRPCs(c engagementv1connect.EngagementServiceClient, token string) map[string]error {
	ctx := context.Background()
	out := map[string]error{}
	_, out["AddBookmark"] = c.AddBookmark(ctx, authed(token, &engagementv1.AddBookmarkRequest{IdempotencyKey: contractKey("bm-add"), PostId: "1"}))
	_, out["RemoveBookmark"] = c.RemoveBookmark(ctx, authed(token, &engagementv1.RemoveBookmarkRequest{IdempotencyKey: contractKey("bm-rm"), PostId: "1"}))
	_, out["ListBookmarks"] = c.ListBookmarks(ctx, authed(token, &engagementv1.ListBookmarksRequest{}))
	return out
}

func TestBookmarksContract_FlagOff(t *testing.T) {
	token, _ := mintToken(t, "")
	env := newChain(t, nil)
	env.createProfile(t, token)

	me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	if slices.Contains(me.Msg.GetEnabledFeatures(), "bookmarks") {
		t.Errorf("enabled_features = %v lists bookmarks with the flag off", me.Msg.GetEnabledFeatures())
	}
	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url)
	for name, err := range bookmarkRPCs(eng, token) {
		d := wireError(t, err, connect.CodeFailedPrecondition)
		assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
		if d.GetMetadata()["feature"] != "bookmarks" {
			t.Errorf("%s: metadata = %v, want feature=bookmarks", name, d.GetMetadata())
		}
	}
}

func TestBookmarksContract_AllowlistCohort(t *testing.T) {
	insideToken, insideUID := mintToken(t, "")
	outsideToken, _ := mintToken(t, "")
	env := newChain(t, func(cfg *config.Config) {
		cfg.FeatureBookmarks = flags.Spec{Name: "bookmarks", Mode: flags.Allowlist, Allowlist: map[string]struct{}{insideUID: {}}}
	})
	env.createProfile(t, insideToken)
	env.createProfile(t, outsideToken)

	for token, want := range map[string]bool{insideToken: true, outsideToken: false} {
		me, err := env.identity.GetMe(context.Background(), authed(token, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if got := slices.Contains(me.Msg.GetEnabledFeatures(), "bookmarks"); got != want {
			t.Errorf("enabled_features = %v, bookmarks listed = %v, want %v", me.Msg.GetEnabledFeatures(), got, want)
		}
	}

	eng := engagementv1connect.NewEngagementServiceClient(http.DefaultClient, env.url)
	// Inside: every RPC passes the gate.
	for name, err := range bookmarkRPCs(eng, insideToken) {
		if !passedGate(name, err) {
			t.Errorf("inside %s: err = %v, want the gate passed", name, err)
		}
	}
	// Outside: AddBookmark is refused, Remove and List still pass the gate.
	for name, err := range bookmarkRPCs(eng, outsideToken) {
		if name == "AddBookmark" {
			d := wireError(t, err, connect.CodeFailedPrecondition)
			assertReason(t, d, commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED)
			if d.GetMetadata()["feature"] != "bookmarks" {
				t.Errorf("AddBookmark: metadata = %v, want feature=bookmarks", d.GetMetadata())
			}
			continue
		}
		if !passedGate(name, err) {
			t.Errorf("outside %s: err = %v, want the gate passed", name, err)
		}
	}
}
