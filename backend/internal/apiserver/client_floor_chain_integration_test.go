//go:build integration

package apiserver

// The app version floor for messaging over the real Build chain (Firestore and Auth emulators; plan 6 section 3.1, Task
// 3.B). With CLIENT_FLOOR_ANDROID=1: an android/0 build, a build with no header and an unknown platform lose the
// messaging family in GetMe and see "messaging" in features_needing_update, and MessagingService and KeyService answer
// FEATURE_DISABLED feature=messaging update_required=true; an android/1 build sees today's answers; the rest of the app
// (GetMe itself, posts) is unaffected. With every floor 0 GetMe is the same with and without the header.

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	keysv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/keys/v1/keysv1connect"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/config"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// withClient is authed plus the capability header ("" = an old build that sends none).
func withClient[T any](idToken, header string, msg *T) *connect.Request[T] {
	req := authed(idToken, msg)
	if header != "" {
		req.Header().Set("x-dz-client", header)
	}
	return req
}

func inbox() *messagingv1.ListConversationsRequest {
	return &messagingv1.ListConversationsRequest{Folder: messagingv1.Folder_FOLDER_INBOX, PageSize: 10}
}

func floorDetail(err error) (commonv1.ErrorReason, map[string]string) {
	var ce *connect.Error
	if !asConnectErr(err, &ce) {
		return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil
	}
	for _, d := range ce.Details() {
		if v, verr := d.Value(); verr == nil {
			if ed, ok := v.(*commonv1.ErrorDetail); ok {
				return ed.GetReason(), ed.GetMetadata()
			}
		}
	}
	return commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, nil
}

func TestClientFloorChain_MessagingBelowTheFloor(t *testing.T) {
	ctx := context.Background()
	e := newDMChain(t, func(c *config.Config) {
		c.FeatureE2EEDM = flags.Spec{Name: "e2ee_dm", Mode: flags.On}
		c.ClientFloors = config.ClientFloorsConfig{Android: 1, Web: 1, IOS: 1}
	})
	u := e.user(t)
	keysClient := keysv1connect.NewKeyServiceClient(http.DefaultClient, e.url)

	for _, header := range []string{"android/0", "", "other/0", "ios/0", "garbage"} {
		t.Run("below "+header, func(t *testing.T) {
			me, err := e.identity.GetMe(ctx, withClient(u.token, header, &identityv1.GetMeRequest{}))
			if err != nil {
				t.Fatalf("GetMe: %v (the rest of the app must keep working)", err)
			}
			for _, name := range []string{"messaging", "e2ee_dm"} {
				if slices.Contains(me.Msg.GetEnabledFeatures(), name) {
					t.Errorf("enabled_features = %v, want no %s below the floor", me.Msg.GetEnabledFeatures(), name)
				}
			}
			if got := me.Msg.GetFeaturesNeedingUpdate(); !slices.Equal(got, []string{"messaging"}) {
				t.Errorf("features_needing_update = %v, want [messaging]", got)
			}
			if !slices.Contains(me.Msg.GetEnabledFeatures(), "posts") {
				t.Errorf("enabled_features = %v, want posts kept", me.Msg.GetEnabledFeatures())
			}
			_, err = e.msg.ListConversations(ctx, withClient(u.token, header, inbox()))
			wantFloorRefusal(t, "ListConversations", err)
			_, err = keysClient.ListMyKeyDevices(ctx, withClient(u.token, header, &keysv1.ListMyKeyDevicesRequest{}))
			wantFloorRefusal(t, "ListMyKeyDevices", err)
			// Posts are untouched.
			if _, err := e.posts.CreatePost(ctx, withClient(u.token, header, &postsv1.CreatePostRequest{IdempotencyKey: contractKey("floor-post"), Text: "still posting"})); err != nil {
				t.Errorf("CreatePost below the floor: %v, want a post", err)
			}
		})
	}

	t.Run("at the floor", func(t *testing.T) {
		me, err := e.identity.GetMe(ctx, withClient(u.token, "android/1", &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if !slices.Contains(me.Msg.GetEnabledFeatures(), "messaging") || len(me.Msg.GetFeaturesNeedingUpdate()) != 0 {
			t.Errorf("android/1: enabled %v needing %v, want messaging on and nothing to update", me.Msg.GetEnabledFeatures(), me.Msg.GetFeaturesNeedingUpdate())
		}
		if _, err := e.msg.ListConversations(ctx, withClient(u.token, "android/1", inbox())); err != nil {
			t.Errorf("ListConversations at the floor: %v", err)
		}
		if _, err := keysClient.ListMyKeyDevices(ctx, withClient(u.token, "android/1", &keysv1.ListMyKeyDevicesRequest{})); err != nil {
			t.Errorf("ListMyKeyDevices at the floor: %v", err)
		}
	})
}

func wantFloorRefusal(t *testing.T, rpc string, err error) {
	t.Helper()
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("%s: %v, want FAILED_PRECONDITION", rpc, err)
	}
	reason, meta := floorDetail(err)
	if reason != commonv1.ErrorReason_ERROR_REASON_FEATURE_DISABLED || meta["feature"] != "messaging" || meta["update_required"] != "true" {
		t.Errorf("%s: %v %v, want FEATURE_DISABLED feature=messaging update_required=true", rpc, reason, meta)
	}
}

// TestClientFloorChain_Floor0ChangesNothing: with every floor 0 (the default) GetMe answers the same for every header.
func TestClientFloorChain_Floor0ChangesNothing(t *testing.T) {
	ctx := context.Background()
	e := newDMChain(t, nil)
	u := e.user(t)
	base, err := e.identity.GetMe(ctx, authed(u.token, &identityv1.GetMeRequest{}))
	if err != nil {
		t.Fatalf("GetMe: %v", err)
	}
	for _, header := range []string{"android/0", "ios/0", "other/0", "web/1", "garbage"} {
		me, err := e.identity.GetMe(ctx, withClient(u.token, header, &identityv1.GetMeRequest{}))
		if err != nil {
			t.Fatalf("GetMe %q: %v", header, err)
		}
		if !slices.Equal(me.Msg.GetEnabledFeatures(), base.Msg.GetEnabledFeatures()) || len(me.Msg.GetFeaturesNeedingUpdate()) != 0 {
			t.Errorf("%q: enabled %v needing %v, want %v and nothing", header, me.Msg.GetEnabledFeatures(), me.Msg.GetFeaturesNeedingUpdate(), base.Msg.GetEnabledFeatures())
		}
		if _, err := e.msg.ListConversations(ctx, withClient(u.token, header, inbox())); err != nil {
			t.Errorf("%q: ListConversations = %v, want a page", header, err)
		}
	}
}
