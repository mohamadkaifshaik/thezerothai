package identity

import (
	"context"
	"reflect"
	"slices"
	"testing"
	"time"

	"connectrpc.com/connect"

	identityv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/identity/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/clientinfo"
)

// The app version floor for messaging (plan 6 section 3.1, Task 3.B): below the floor GetMe omits the messaging family
// from enabled_features and lists "messaging" in features_needing_update; the rest of GetMe is untouched; floors of 0
// change nothing for any client, header or not.

// messagingFamilyOn is every name of the messaging family plus unrelated flags, in the order a registry returns them.
var messagingFamilyOn = []string{"graph", MessagingFlag, "e2ee_dm", "e2ee_required", "claim_live", "dm_share_check", "dm_post_share",
	"message_search", "read_receipts", "dm_suggestions", "dm_policy", "chat_shared_plans", "posts", ListsFlag}

// withoutMessaging is messagingFamilyOn below the floor.
var withoutMessaging = []string{"graph", "posts", ListsFlag}

func floorSvc(t *testing.T, enabled []string, floor ClientFloor, b *fakeBadge) *service {
	t.Helper()
	repo := newFakeRepo()
	repo.profiles["u"] = Profile{UserID: "u", Handle: "u", HandleLower: "u", Status: AccountStatusActive,
		HomeTabsEnc: encodeHomeTabs([]HomeTab{{Kind: HomeTabKindList, ID: "0000000000000000101"}})}
	opts := []Option{WithFeatureFlags(&fakeFeatureFlags{enabled: enabled}), WithMessageBadge(b, nil)}
	if floor != nil {
		opts = append(opts, WithClientFloor(floor))
	}
	return New(repo, NewCache(time.Minute), time.Hour, opts...).(*service)
}

func stamped(header string) context.Context {
	return clientinfo.WithClient(context.Background(), clientinfo.Parse(header))
}

// TestGetMe_BelowTheFloorOmitsTheMessagingFamilyAndListsMessagingInFeaturesNeedingUpdate is the plan's "GetMe below the
// floor omits the messaging family and lists messaging in features_needing_update".
func TestGetMe_BelowTheFloorOmitsTheMessagingFamilyAndListsMessagingInFeaturesNeedingUpdate(t *testing.T) {
	floors := clientinfo.Floors{Android: 1, Web: 1, IOS: 1}
	for _, tc := range []struct {
		name        string
		header      string
		enabled     []string
		wantEnabled []string
		wantNeeding []string
		wantBadge   int
	}{
		{"android/0 with messaging on", "android/0", messagingFamilyOn, withoutMessaging, []string{"messaging"}, 0},
		{"no header (an old build)", "", messagingFamilyOn, withoutMessaging, []string{"messaging"}, 0},
		{"other/0 (unknown platform, highest floor)", "other/0", messagingFamilyOn, withoutMessaging, []string{"messaging"}, 0},
		{"ios/0", "ios/0", messagingFamilyOn, withoutMessaging, []string{"messaging"}, 0},
		// Messaging off for the caller: the family is still stripped, but nothing is offered behind an update.
		{"below, messaging off for the caller", "android/0", []string{"graph", "read_receipts", ListsFlag}, []string{"graph", ListsFlag}, nil, 0},
		// At or above the floor: exactly what the flags say.
		{"android/1 at the floor", "android/1", messagingFamilyOn, messagingFamilyOn, nil, 1},
		{"web/2 above the floor", "web/2", messagingFamilyOn, messagingFamilyOn, nil, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			enabled := slices.Clone(tc.enabled)
			b := &fakeBadge{n: 3}
			got, err := floorSvc(t, enabled, floors, b).GetMe(stamped(tc.header), "u")
			if err != nil {
				t.Fatalf("GetMe: %v", err)
			}
			if !slices.Equal(got.EnabledFeatures, tc.wantEnabled) {
				t.Errorf("enabled_features = %v, want %v", got.EnabledFeatures, tc.wantEnabled)
			}
			if !slices.Equal(got.FeaturesNeedingUpdate, tc.wantNeeding) {
				t.Errorf("features_needing_update = %v, want %v", got.FeaturesNeedingUpdate, tc.wantNeeding)
			}
			if b.calls != tc.wantBadge {
				t.Errorf("messages badge calls = %d, want %d (no messaging read below the floor)", b.calls, tc.wantBadge)
			}
			if tc.wantBadge == 0 && got.UnreadConversationCount != 0 {
				t.Errorf("unread_conversation_count = %d below the floor, want 0", got.UnreadConversationCount)
			}
			// Nothing else in GetMe is affected: the pinned list tab survives.
			if len(got.HomeTabs) != 1 {
				t.Errorf("home_tabs = %v, want the one list tab", got.HomeTabs)
			}
			// The provider's slice is never filtered in place.
			if !slices.Equal(enabled, tc.enabled) {
				t.Errorf("the provider's enabled slice was modified: %v", enabled)
			}
		})
	}
}

// TestGetMe_Floor0ChangesNothing: with every floor 0 (or no floor wired) GetMe is identical to today's for every client,
// header or not.
func TestGetMe_Floor0ChangesNothing(t *testing.T) {
	for _, header := range []string{"", "android/0", "ios/0", "other/0", "web/1", "garbage", "web/1/2"} {
		baseline, err := floorSvc(t, messagingFamilyOn, nil, &fakeBadge{n: 3}).GetMe(stamped(header), "u")
		if err != nil {
			t.Fatalf("baseline GetMe: %v", err)
		}
		if baseline.FeaturesNeedingUpdate != nil {
			t.Errorf("no floor wired: features_needing_update = %v, want nil", baseline.FeaturesNeedingUpdate)
		}
		got, err := floorSvc(t, messagingFamilyOn, clientinfo.Floors{}, &fakeBadge{n: 3}).GetMe(stamped(header), "u")
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if !reflect.DeepEqual(got, baseline) {
			t.Errorf("header %q, floors 0: GetMe = %+v, want %+v", header, got, baseline)
		}
	}
}

// TestGetMe_UnknownPlatformUsesTheHighestFloor: a platform word the server does not know is held to the highest floor.
func TestGetMe_UnknownPlatformUsesTheHighestFloor(t *testing.T) {
	floors := clientinfo.Floors{Android: 1, Web: 3, IOS: 0}
	for header, below := range map[string]bool{"other/2": true, "desktop/3": false, "ios/0": false, "web/2": true} {
		got, err := floorSvc(t, messagingFamilyOn, floors, &fakeBadge{}).GetMe(stamped(header), "u")
		if err != nil {
			t.Fatalf("GetMe: %v", err)
		}
		if has := slices.Contains(got.FeaturesNeedingUpdate, "messaging"); has != below {
			t.Errorf("%s: features_needing_update = %v, want below=%v", header, got.FeaturesNeedingUpdate, below)
		}
		if has := slices.Contains(got.EnabledFeatures, MessagingFlag); has == below {
			t.Errorf("%s: enabled_features = %v, want messaging=%v", header, got.EnabledFeatures, !below)
		}
	}
}

// TestServer_GetMe_FeaturesNeedingUpdate: the handler copies the service's list to GetMeResponse.features_needing_update
// and leaves it empty when there is none.
func TestServer_GetMe_FeaturesNeedingUpdate(t *testing.T) {
	for _, want := range [][]string{nil, {"messaging"}} {
		svc := &fakeService{meResult: MeResult{Profile: Profile{UserID: "uid-1"}, FeaturesNeedingUpdate: want}}
		client, closeFn := newTestServerHTTP(t, svc, "uid-1")
		resp, err := client.GetMe(context.Background(), connect.NewRequest(&identityv1.GetMeRequest{}))
		closeFn()
		if err != nil {
			t.Fatalf("GetMe() error = %v", err)
		}
		if got := resp.Msg.GetFeaturesNeedingUpdate(); !slices.Equal(got, want) {
			t.Errorf("features_needing_update = %v, want %v", got, want)
		}
	}
}
