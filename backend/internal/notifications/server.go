// server.go is the thin Connect handler for NotificationService: extract the caller's uid, check the
// FEATURE_NOTIFICATIONS flag, call Service, map the result. No business logic and no Firestore here.
package notifications

import (
	"context"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	notificationsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/notifications/v1/notificationsv1connect"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// rpcDeadline bounds every NotificationService call (<= 10 s, go-service skill).
const rpcDeadline = 5 * time.Second

// Server adapts Service to notificationsv1connect.NotificationServiceHandler.
type Server struct {
	notificationsv1connect.UnimplementedNotificationServiceHandler
	svc   Service
	flags FlagChecker
}

// NewServer builds the Connect handler. Use with notificationsv1connect.NewNotificationServiceHandler.
func NewServer(svc Service, fl FlagChecker) *Server { return &Server{svc: svc, flags: fl} }

var _ notificationsv1connect.NotificationServiceHandler = (*Server)(nil)

// guard is the ADR-0017 D7 flag check shared by every RPC: FAILED_PRECONDITION + FEATURE_DISABLED, 0 reads.
func (s *Server) guard(ctx context.Context) (string, error) {
	uid, ok := authn.UIDFromContext(ctx)
	if !ok || uid == "" {
		return "", apierr.New(connect.CodeUnauthenticated, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "unauthenticated")
	}
	var enabled func(uid, name string) bool
	if s.flags != nil {
		enabled = s.flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, FlagName); err != nil {
		return "", err
	}
	return uid, nil
}

// ListNotifications implements the RPC.
func (s *Server) ListNotifications(ctx context.Context, req *connect.Request[notificationsv1.ListNotificationsRequest]) (*connect.Response[notificationsv1.ListNotificationsResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	m := req.Msg
	res, err := s.svc.List(ctx, uid, ListInput{PageSize: m.GetPageSize(), PageToken: m.GetPageToken(), SinceToken: m.GetSinceToken()})
	if err != nil {
		return nil, err
	}
	out := &notificationsv1.ListNotificationsResponse{
		Notifications: make([]*notificationsv1.Notification, 0, len(res.Notifications)),
		NextPageToken: res.NextPageToken, SinceToken: res.SinceToken, GapPageToken: res.GapPageToken,
	}
	for _, n := range res.Notifications {
		out.Notifications = append(out.Notifications, ToProto(n))
	}
	if !res.SeenAt.IsZero() {
		out.SeenAt = timestamppb.New(res.SeenAt)
	}
	return connect.NewResponse(out), nil
}

// MarkNotificationsSeen implements the RPC.
func (s *Server) MarkNotificationsSeen(ctx context.Context, req *connect.Request[notificationsv1.MarkNotificationsSeenRequest]) (*connect.Response[notificationsv1.MarkNotificationsSeenResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	at, err := s.svc.MarkSeen(ctx, uid, req.Msg.GetIdempotencyKey())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&notificationsv1.MarkNotificationsSeenResponse{SeenAt: timestamppb.New(at)}), nil
}

// RegisterDevice implements the RPC.
func (s *Server) RegisterDevice(ctx context.Context, req *connect.Request[notificationsv1.RegisterDeviceRequest]) (*connect.Response[notificationsv1.RegisterDeviceResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	m := req.Msg
	err = s.svc.RegisterDevice(ctx, uid, DeviceInput{
		IdempotencyKey: m.GetIdempotencyKey(), DeviceID: m.GetDeviceId(), Token: m.GetFcmToken(), Platform: platformFromProto(m.GetPlatform()),
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&notificationsv1.RegisterDeviceResponse{}), nil
}

// UnregisterDevice implements the RPC.
func (s *Server) UnregisterDevice(ctx context.Context, req *connect.Request[notificationsv1.UnregisterDeviceRequest]) (*connect.Response[notificationsv1.UnregisterDeviceResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	if err := s.svc.UnregisterDevice(ctx, uid, req.Msg.GetIdempotencyKey(), req.Msg.GetDeviceId()); err != nil {
		return nil, err
	}
	return connect.NewResponse(&notificationsv1.UnregisterDeviceResponse{}), nil
}

func platformFromProto(p notificationsv1.DevicePlatform) Platform {
	switch p {
	case notificationsv1.DevicePlatform_DEVICE_PLATFORM_IOS:
		return PlatformIOS
	case notificationsv1.DevicePlatform_DEVICE_PLATFORM_ANDROID:
		return PlatformAndroid
	}
	return ""
}

func typeToProto(t Type) notificationsv1.NotificationType {
	switch t {
	case TypeFollow:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW
	case TypeMention:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_MENTION
	case TypeReply:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_REPLY
	case TypeLike:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_LIKE
	case TypeRepost:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_REPOST
	case TypeQuote:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_QUOTE
	}
	return notificationsv1.NotificationType_NOTIFICATION_TYPE_UNSPECIFIED
}

// ToProto maps a domain Notification to its wire form.
func ToProto(n Notification) *notificationsv1.Notification {
	count := len(n.ActorIDs)
	if count < 1 {
		count = 1
	}
	return &notificationsv1.Notification{
		Id:   n.ID,
		Type: typeToProto(n.Type),
		Actor: &commonv1.AuthorSnapshot{
			UserId: n.Actor.UserID, Handle: n.Actor.Handle, DisplayName: n.Actor.DisplayName,
			AvatarUrl: n.Actor.AvatarURL, Verified: n.Actor.Verified,
		},
		ActorCount: int32(count), //nolint:gosec // bounded by the row size
		PostId:     n.PostID,
		CreatedAt:  timestamppb.New(n.CreatedAt),
	}
}
