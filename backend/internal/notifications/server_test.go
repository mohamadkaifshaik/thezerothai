package notifications

import (
	"context"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"

	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

func authedCtx(uid string) context.Context {
	return authn.WithClaims(context.Background(), authn.Claims{UID: uid, SignInProvider: authn.SignInProviderGoogle})
}

func newTestServer(fl FlagChecker) (*Server, *fakeRepo, *fakeSeen) {
	repo, seen := newFakeRepo(), &fakeSeen{}
	svc := NewService(Deps{Repo: repo, Directory: newDirectory("me"), Seen: seen, CursorKey: testKey, Now: func() time.Time { return t0 }})
	return NewServer(svc, fl), repo, seen
}

func TestServer_FlagGuardOnEveryRPC(t *testing.T) {
	calls := map[string]func(*Server) error{
		"ListNotifications": func(s *Server) error {
			_, err := s.ListNotifications(authedCtx("me"), connect.NewRequest(&notificationsv1.ListNotificationsRequest{}))
			return err
		},
		"MarkNotificationsSeen": func(s *Server) error {
			_, err := s.MarkNotificationsSeen(authedCtx("me"), connect.NewRequest(&notificationsv1.MarkNotificationsSeenRequest{IdempotencyKey: goodKey}))
			return err
		},
		"RegisterDevice": func(s *Server) error {
			_, err := s.RegisterDevice(authedCtx("me"), connect.NewRequest(&notificationsv1.RegisterDeviceRequest{
				IdempotencyKey: goodKey, DeviceId: "device-0123456789", FcmToken: "tok", Platform: notificationsv1.DevicePlatform_DEVICE_PLATFORM_IOS}))
			return err
		},
		"UnregisterDevice": func(s *Server) error {
			_, err := s.UnregisterDevice(authedCtx("me"), connect.NewRequest(&notificationsv1.UnregisterDeviceRequest{IdempotencyKey: goodKey, DeviceId: "device-0123456789"}))
			return err
		},
	}
	for name, call := range calls {
		t.Run(name+" flag off", func(t *testing.T) {
			s, repo, seen := newTestServer(fakeFlags{})
			err := call(s)
			ce := apierr.ToConnect(err)
			if ce == nil || ce.Code() != connect.CodeFailedPrecondition {
				t.Fatalf("err = %v, want FAILED_PRECONDITION", err)
			}
			if repo.lastList.Limit != 0 || len(repo.devices) != 0 || seen.uid != "" {
				t.Error("a disabled flag must cost nothing")
			}
		})
		t.Run(name+" flag on", func(t *testing.T) {
			s, _, _ := newTestServer(fakeFlags{"me": true})
			if err := call(s); err != nil {
				t.Fatalf("err = %v", err)
			}
		})
	}
}

func TestServer_Unauthenticated(t *testing.T) {
	s, _, _ := newTestServer(allFlags{})
	_, err := s.ListNotifications(context.Background(), connect.NewRequest(&notificationsv1.ListNotificationsRequest{}))
	if ce := apierr.ToConnect(err); ce == nil || ce.Code() != connect.CodeUnauthenticated {
		t.Fatalf("err = %v", err)
	}
}

func TestServer_ListMapsRowsAndTokens(t *testing.T) {
	s, repo, _ := newTestServer(allFlags{})
	repo.rows["me"] = map[string]Notification{
		"like_x": {ID: "like_x", Type: TypeLike, PostID: postA, CreatedAt: t0, ActorIDs: []string{"a", "b", "c"},
			Actor: Actor{UserID: "c", Handle: "carol", DisplayName: "Carol", AvatarURL: "https://x/c", Verified: true}},
	}
	res, err := s.ListNotifications(authedCtx("me"), connect.NewRequest(&notificationsv1.ListNotificationsRequest{PageSize: 10}))
	mustNoErr(t, err)
	if len(res.Msg.Notifications) != 1 || res.Msg.SinceToken == "" {
		t.Fatalf("response = %+v", res.Msg)
	}
	n := res.Msg.Notifications[0]
	if n.Id != "like_x" || n.Type != notificationsv1.NotificationType_NOTIFICATION_TYPE_LIKE || n.ActorCount != 3 || n.PostId != postA ||
		n.Actor.Handle != "carol" || !n.Actor.Verified || !n.CreatedAt.AsTime().Equal(t0) {
		t.Errorf("notification = %+v", n)
	}
}

func TestToProto(t *testing.T) {
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote} {
		got := ToProto(Notification{ID: "i", Type: ty, CreatedAt: t0})
		if got.Type == notificationsv1.NotificationType_NOTIFICATION_TYPE_UNSPECIFIED {
			t.Errorf("%s maps to UNSPECIFIED", ty)
		}
		if got.ActorCount != 1 {
			t.Errorf("an empty actorIds list must report 1 actor, got %d", got.ActorCount)
		}
	}
	if ToProto(Notification{Type: "poke"}).Type != notificationsv1.NotificationType_NOTIFICATION_TYPE_UNSPECIFIED {
		t.Error("unknown type must be UNSPECIFIED")
	}
}

func TestPlatformFromProto(t *testing.T) {
	tests := map[notificationsv1.DevicePlatform]Platform{
		notificationsv1.DevicePlatform_DEVICE_PLATFORM_IOS:         PlatformIOS,
		notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID:     PlatformAndroid,
		notificationsv1.DevicePlatform_DEVICE_PLATFORM_UNSPECIFIED: "",
	}
	for in, want := range tests {
		if got := platformFromProto(in); got != want {
			t.Errorf("platformFromProto(%v) = %q, want %q", in, got, want)
		}
	}
}

func TestPushText_NoHandleNoPostText(t *testing.T) {
	for _, ty := range []Type{TypeFollow, TypeMention, TypeReply, TypeLike, TypeRepost, TypeQuote, "poke"} {
		title, body := pushText(ty)
		if title == "" || body == "" {
			t.Errorf("%s: empty text", ty)
		}
		if strings.Contains(title+body, "@") {
			t.Errorf("%s: a handle on the lock screen: %q %q", ty, title, body)
		}
	}
}

func TestLogSenderAndTruncate(t *testing.T) {
	if err := (LogSender{}).Send(context.Background(), "secret-token", Push{Type: TypeFollow, NotificationID: "n"}); err != nil {
		t.Fatal(err)
	}
	if truncate("abcdef", 3) != "abc" || truncate("ab", 3) != "ab" {
		t.Error("truncate")
	}
}
