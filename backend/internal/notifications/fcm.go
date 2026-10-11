package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// fcmTTL is how long FCM keeps an undelivered push for an offline device: a day-old "new follower" is noise.
const fcmTTL = 24 * time.Hour

// pushText is the generic, localization-free title/body per type (ADR-0017 D6: no post text, no handle: a lock
// screen is a public surface). The app localizes from `data.type` when it is in the foreground.
func pushText(t Type) (title, body string) {
	switch t {
	case TypeFollow:
		return "New follower", "Someone started following you"
	case TypeMention:
		return "New mention", "Someone mentioned you in a post"
	case TypeReply:
		return "New reply", "Someone replied to your post"
	case TypeLike:
		return "New like", "Someone liked your post"
	case TypeRepost:
		return "New repost", "Someone reposted your post"
	case TypeQuote:
		return "New quote", "Someone quoted your post"
	}
	return "Notification", "You have a new notification"
}

// FCMSender sends through Firebase Cloud Messaging with the Admin SDK (HTTP v1). The messaging client is created on
// first use so process start does no I/O.
type FCMSender struct {
	app    *firebase.App
	once   sync.Once
	client *messaging.Client
	err    error
}

// NewFCMSender builds the sender from the process's Firebase app.
func NewFCMSender(app *firebase.App) *FCMSender { return &FCMSender{app: app} }

var _ PushSender = (*FCMSender)(nil)

// Send implements PushSender. It returns ErrTokenUnregistered when FCM says the registration is dead.
func (s *FCMSender) Send(ctx context.Context, token string, p Push) error {
	s.once.Do(func() { s.client, s.err = s.app.Messaging(context.WithoutCancel(ctx)) })
	if s.err != nil {
		return fmt.Errorf("notifications: fcm client: %w", s.err)
	}
	title, body := pushText(p.Type)
	ttl := fcmTTL
	msg := &messaging.Message{
		Token:        token, //nolint:staticcheck // SA1019: the client stores the FCM registration token (getToken()), which Token addresses; Fid is the installation id, a different identifier
		Notification: &messaging.Notification{Title: title, Body: body},
		Data: map[string]string{
			"type": string(p.Type), "notificationId": p.NotificationID, "postId": p.PostID, "actorId": p.ActorID,
		},
		Android: &messaging.AndroidConfig{
			Priority: "normal", TTL: &ttl, CollapseKey: p.NotificationID,
			Notification: &messaging.AndroidNotification{ChannelID: "social", Tag: p.NotificationID},
		},
		APNS: &messaging.APNSConfig{
			Headers: map[string]string{"apns-priority": "5", "apns-collapse-id": truncate(p.NotificationID, 64)},
		},
	}
	if _, err := s.client.Send(ctx, msg); err != nil {
		if messaging.IsUnregistered(err) || messaging.IsSenderIDMismatch(err) || messaging.IsInvalidArgument(err) {
			return ErrTokenUnregistered
		}
		return fmt.Errorf("notifications: fcm send: %w", err)
	}
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// LogSender records pushes to the log instead of sending them: local dev has no FCM.
type LogSender struct{ Log *slog.Logger }

var _ PushSender = LogSender{}

// Send implements PushSender.
func (l LogSender) Send(ctx context.Context, token string, p Push) error {
	log := l.Log
	if log == nil {
		log = slog.Default()
	}
	log.InfoContext(ctx, "notification_push_local", "type", string(p.Type), "notification_id", p.NotificationID, "token_hash", logger.HashUID(token))
	return nil
}
