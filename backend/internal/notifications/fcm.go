package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/errorutils"
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
	case TypeFollowRequest:
		return "New follow request", "Someone asked to follow you"
	case TypeFollowAccepted:
		return "Follow request accepted", "Your follow request was accepted"
	}
	return "Notification", "You have a new notification"
}

// fcmClass maps one FCM error condition to the code logged for it and whether the device is pruned.
type fcmClass struct {
	code  string
	prune bool
	match func(error) bool
}

// fcmClasses is the classification table, first match wins. Only a token FCM says is dead is pruned
// (ADR-0017 D6): UNREGISTERED and SENDER_ID_MISMATCH. INVALID_ARGUMENT is deliberately NOT pruned: it can mean a
// payload or project misconfiguration of ours, and pruning on it would silently delete every user's device.
var fcmClasses = []fcmClass{
	{"UNREGISTERED", true, messaging.IsUnregistered},
	{"SENDER_ID_MISMATCH", true, messaging.IsSenderIDMismatch},
	{"INVALID_ARGUMENT", false, messaging.IsInvalidArgument},
	{"QUOTA_EXCEEDED", false, messaging.IsQuotaExceeded},
	{"THIRD_PARTY_AUTH_ERROR", false, messaging.IsThirdPartyAuthError},
	{"PERMISSION_DENIED", false, errorutils.IsPermissionDenied},
	{"UNAUTHENTICATED", false, errorutils.IsUnauthenticated},
	{"UNAVAILABLE", false, messaging.IsUnavailable},
	{"INTERNAL", false, messaging.IsInternal},
}

// classifySendError returns the redacted code of an FCM send error ("UNKNOWN" when no class matches) and whether
// the device must be pruned. It is pure over the table so tests can inject predicates (the SDK's error type has no
// public constructor). The code is a fixed string: never err.Error(), which can echo the token.
func classifySendError(err error, classes []fcmClass) (code string, prune bool) {
	for _, c := range classes {
		if c.match(err) {
			return c.code, c.prune
		}
	}
	return "UNKNOWN", false
}

// PushError is a failed send that does not prune the device; Code is the redacted FCM error code.
type PushError struct{ Code string }

// Error implements error. It carries only the fixed code.
func (e *PushError) Error() string { return "notifications: fcm send failed: " + e.Code }

// FCMSender sends through Firebase Cloud Messaging with the Admin SDK (HTTP v1). The messaging client is created on
// first use so process start does no I/O; a failed creation is retried on the next send (never cached).
type FCMSender struct {
	newClient func(ctx context.Context) (*messaging.Client, error)
	mu        sync.Mutex
	client    *messaging.Client
	classes   []fcmClass
}

// messagingClient returns the cached client, creating it on first success. An error is returned, not stored, so a
// transient failure does not disable push for the life of the instance.
func (s *FCMSender) messagingClient(ctx context.Context) (*messaging.Client, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client != nil {
		return s.client, nil
	}
	c, err := s.newClient(context.WithoutCancel(ctx))
	if err != nil {
		return nil, err
	}
	s.client = c
	return c, nil
}

// NewFCMSender builds the sender from the process's Firebase app.
func NewFCMSender(app *firebase.App) *FCMSender {
	return &FCMSender{newClient: app.Messaging, classes: fcmClasses}
}

var _ PushSender = (*FCMSender)(nil)

// buildMessage is the FCM message for one push. The collapse key, Android tag and apns-collapse-id are the
// notification TYPE, never the unique notification id (N-2): a burst of pushes of one type replaces itself on the
// device instead of stacking one banner per row. The id stays in `data` so the app can deep-link.
func buildMessage(token string, p Push) *messaging.Message {
	title, body := pushText(p.Type)
	ttl := fcmTTL
	collapse := string(p.Type)
	return &messaging.Message{
		Token:        token, //nolint:staticcheck // SA1019: the client stores the FCM registration token (getToken()), which Token addresses; Fid is the installation id, a different identifier
		Notification: &messaging.Notification{Title: title, Body: body},
		Data: map[string]string{
			"type": string(p.Type), "notificationId": p.NotificationID, "postId": p.PostID, "actorId": p.ActorID,
		},
		Android: &messaging.AndroidConfig{
			Priority: "normal", TTL: &ttl, CollapseKey: collapse,
			Notification: &messaging.AndroidNotification{ChannelID: "social", Tag: collapse},
		},
		APNS: &messaging.APNSConfig{
			Headers: map[string]string{"apns-priority": "5", "apns-collapse-id": truncate(collapse, 64)},
		},
	}
}

// Send implements PushSender. It returns ErrTokenUnregistered when FCM says the registration is dead.
func (s *FCMSender) Send(ctx context.Context, token string, p Push) error {
	client, err := s.messagingClient(ctx)
	if err != nil {
		return fmt.Errorf("notifications: fcm client: %w", err)
	}
	msg := buildMessage(token, p)
	if _, err := client.Send(ctx, msg); err != nil {
		code, prune := classifySendError(err, s.classes)
		if prune {
			return fmt.Errorf("%w: %s", ErrTokenUnregistered, code)
		}
		return &PushError{Code: code}
	}
	return nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// invalidTokenCodes are the FCM error codes that mean "this is not a valid registration token of this project".
var invalidTokenCodes = map[string]bool{"INVALID_ARGUMENT": true, "UNREGISTERED": true, "SENDER_ID_MISMATCH": true}

// dryRunMessage is the smallest message FCM accepts for a dry run: it carries no user content and is never delivered.
func dryRunMessage(token string) *messaging.Message {
	return &messaging.Message{
		Token: token, //nolint:staticcheck // SA1019: see buildMessage
		Data:  map[string]string{"type": "validate"},
	}
}

var _ TokenValidator = (*FCMSender)(nil)

// Validate implements TokenValidator with an FCM dry-run send (validation only, free, nothing delivered). It
// returns ErrTokenInvalid for INVALID_ARGUMENT, UNREGISTERED and SENDER_ID_MISMATCH, a *PushError (fixed code, never
// the token) for any other failure, and nil when FCM accepts the token.
func (s *FCMSender) Validate(ctx context.Context, token string) error {
	client, err := s.messagingClient(ctx)
	if err != nil {
		return fmt.Errorf("notifications: fcm client: %w", err)
	}
	if _, err := client.SendDryRun(ctx, dryRunMessage(token)); err != nil {
		code, _ := classifySendError(err, s.classes)
		if invalidTokenCodes[code] {
			return fmt.Errorf("%w: %s", ErrTokenInvalid, code)
		}
		return &PushError{Code: code}
	}
	return nil
}

// NopValidator accepts every token (local dev and the emulator, where there is no FCM).
type NopValidator struct{}

// Validate implements TokenValidator.
func (NopValidator) Validate(context.Context, string) error { return nil }

var _ TokenValidator = NopValidator{}

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
