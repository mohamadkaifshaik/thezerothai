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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// rpcDeadline bounds every NotificationService call (<= 10 s).
const rpcDeadline = 5 * time.Second

// Server adapts Service to notificationsv1connect.NotificationServiceHandler.
type Server struct {
	notificationsv1connect.UnimplementedNotificationServiceHandler
	svc   Service
	flags FlagChecker
	// prefs serves GetNotificationPrefs and UpdateNotificationPrefs (WithPrefs); nil answers Unimplemented once the flags pass.
	prefs PrefsService
}

// ServerOption configures NewServer.
type ServerOption func(*Server)

// WithPrefs wires the service behind GetNotificationPrefs and UpdateNotificationPrefs (F6).
func WithPrefs(p PrefsService) ServerOption { return func(s *Server) { s.prefs = p } }

// NewServer builds the Connect handler. Use with notificationsv1connect.NewNotificationServiceHandler.
func NewServer(svc Service, fl FlagChecker, opts ...ServerOption) *Server {
	s := &Server{svc: svc, flags: fl}
	for _, o := range opts {
		o(s)
	}
	return s
}

var _ notificationsv1connect.NotificationServiceHandler = (*Server)(nil)

// guard is the flag check shared by every RPC: FAILED_PRECONDITION + FEATURE_DISABLED.
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

// guardPrefs is the flag check of the two preference RPCs: FEATURE_NOTIFICATIONS first (guard), then
// FEATURE_NOTIFICATION_PREFS for the caller, answered FEATURE_DISABLED with metadata feature=notification_prefs.
func (s *Server) guardPrefs(ctx context.Context) (string, error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return "", err
	}
	var enabled func(uid, name string) bool
	if s.flags != nil {
		enabled = s.flags.Enabled
	}
	if err := flags.Guard(ctx, enabled, uid, PrefsFlagName); err != nil {
		logger.SetRequestField(ctx, "feature", PrefsFlagName)
		return "", flags.DisabledError().WithMeta("feature", PrefsFlagName)
	}
	return uid, nil
}

// GetNotificationPrefs implements the RPC (F6).
func (s *Server) GetNotificationPrefs(ctx context.Context, req *connect.Request[notificationsv1.GetNotificationPrefsRequest]) (*connect.Response[notificationsv1.GetNotificationPrefsResponse], error) {
	uid, err := s.guardPrefs(ctx)
	if err != nil {
		return nil, err
	}
	if s.prefs == nil {
		return s.UnimplementedNotificationServiceHandler.GetNotificationPrefs(ctx, req)
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	p, err := s.prefs.GetPrefs(ctx, uid)
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&notificationsv1.GetNotificationPrefsResponse{Prefs: PrefsToProto(p)}), nil
}

// UpdateNotificationPrefs implements the RPC (F6).
func (s *Server) UpdateNotificationPrefs(ctx context.Context, req *connect.Request[notificationsv1.UpdateNotificationPrefsRequest]) (*connect.Response[notificationsv1.UpdateNotificationPrefsResponse], error) {
	uid, err := s.guardPrefs(ctx)
	if err != nil {
		return nil, err
	}
	if s.prefs == nil {
		return s.UnimplementedNotificationServiceHandler.UpdateNotificationPrefs(ctx, req)
	}
	if req.Msg.GetPrefs() == nil {
		return nil, apierr.Validation("prefs", "prefs is required")
	}
	ctx, cancel := context.WithTimeout(ctx, rpcDeadline)
	defer cancel()
	p, err := s.prefs.UpdatePrefs(ctx, uid, req.Msg.GetIdempotencyKey(), PrefsFromProto(req.Msg.GetPrefs()))
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&notificationsv1.UpdateNotificationPrefsResponse{Prefs: PrefsToProto(p)}), nil
}

// PrefsToProto maps Prefs to its wire form.
func PrefsToProto(p Prefs) *notificationsv1.NotificationPrefs {
	return &notificationsv1.NotificationPrefs{
		PlansPush: p.Plans, MentionsRepliesPush: p.MentionsReplies, LikesRepostsPush: p.LikesReposts,
		FollowersPush: p.Followers, MessagesPush: p.Messages,
	}
}

// PrefsFromProto maps the wire form to Prefs.
func PrefsFromProto(m *notificationsv1.NotificationPrefs) Prefs {
	return Prefs{
		Plans: m.GetPlansPush(), MentionsReplies: m.GetMentionsRepliesPush(), LikesReposts: m.GetLikesRepostsPush(),
		Followers: m.GetFollowersPush(), Messages: m.GetMessagesPush(),
	}
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
	case TypeFollowRequest:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW_REQUEST
	case TypeFollowAccepted:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_FOLLOW_ACCEPTED
	case TypeBeaconRequest:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_BEACON_REQUEST
	case TypeBeaconAccepted:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_BEACON_ACCEPTED
	case TypeBeaconCancelled:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_BEACON_CANCELLED
	case TypeBeaconUpdated:
		return notificationsv1.NotificationType_NOTIFICATION_TYPE_BEACON_UPDATED
	}
	return notificationsv1.NotificationType_NOTIFICATION_TYPE_UNSPECIFIED
}

// ToProto maps a domain Notification to its wire form. actor_count is max(ActorCount, len(ActorIDs)), at least 1:
// the max covers legacy rows whose stored count is 0 or below the ids (see visible), and List has already
// subtracted the hidden actors from ActorCount and pruned them from ActorIDs.
func ToProto(n Notification) *notificationsv1.Notification {
	count := max(n.ActorCount, len(n.ActorIDs))
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
		BeaconId:   n.BeaconID,
		CreatedAt:  timestamppb.New(n.CreatedAt),
	}
}
