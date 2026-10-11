package notifications

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ListInput is one ListNotifications call (already past the flag guard).
type ListInput struct {
	PageSize   int32
	PageToken  string
	SinceToken string
}

// ListResult is one ListNotifications response.
type ListResult struct {
	Notifications []Notification
	NextPageToken string
	SinceToken    string
	GapPageToken  string
	// SeenAt is the caller's notificationsSeenAt (zero when never marked seen).
	SeenAt time.Time
}

// DeviceInput is one RegisterDevice call.
type DeviceInput struct {
	IdempotencyKey string
	DeviceID       string
	Token          string
	Platform       Platform
}

// Service is the Connect handler's dependency.
type Service interface {
	List(ctx context.Context, uid string, in ListInput) (ListResult, error)
	MarkSeen(ctx context.Context, uid, idempotencyKey string) (time.Time, error)
	RegisterDevice(ctx context.Context, uid string, in DeviceInput) error
	UnregisterDevice(ctx context.Context, uid, idempotencyKey, deviceID string) error
}

// Deps are the Service's collaborators.
type Deps struct {
	Repo      Repo
	Directory Directory
	Seen      SeenStore
	CursorKey []byte
	// TokenTTL is the lifetime of a persisted since/gap token (RefreshTokenTTL when zero).
	TokenTTL time.Duration
	Now      func() time.Time
}

type service struct {
	d Deps
}

// NewService builds the Service.
func NewService(d Deps) Service {
	if d.Now == nil {
		d.Now = time.Now
	}
	if d.TokenTTL <= 0 {
		d.TokenTTL = RefreshTokenTTL
	}
	return &service{d: d}
}

var deviceIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,64}$`)

func sinceBinding(uid string) string { return "notifications|since|" + uid }
func pageBinding(uid string) string  { return "notifications|page|" + uid }

func clampPageSize(n int32) int {
	switch {
	case n <= 0:
		return DefaultPageSize
	case n > MaxPageSize:
		return MaxPageSize
	}
	return int(n)
}

// List: reads 1 + rows returned worst (21 at the default page); a refresh with nothing new reads 1; the seen_at
// profile is the account-status interceptor's cached entry (0 reads on a hit, +1 on a cold instance). Writes 0.
func (s *service) List(ctx context.Context, uid string, in ListInput) (ListResult, error) {
	if in.PageToken != "" && in.SinceToken != "" {
		return ListResult{}, apierr.Validation("page_token", "send either page_token or since_token, not both")
	}
	limit := clampPageSize(in.PageSize)
	now := s.d.Now()

	var q ListQuery
	q.Limit = limit
	var since *cursor.Cursor
	var gapLower *cursor.Cursor
	switch {
	case in.SinceToken != "":
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, sinceBinding(uid), in.SinceToken, now, s.d.TokenTTL)
		if err != nil {
			return ListResult{}, apierr.Validation("since_token", "invalid or expired since_token")
		}
		since = &c
		q.After = &c
	case in.PageToken != "":
		w, err := cursor.DecodeWindowAt(s.d.CursorKey, pageBinding(uid), in.PageToken, now, s.d.TokenTTL)
		if err != nil || w.IsZero() {
			return ListResult{}, apierr.Validation("page_token", "invalid or expired page_token")
		}
		up := w.Upper
		q.Before = &up
		q.After = w.Lower
		gapLower = w.Lower
	}

	rows, err := s.d.Repo.List(ctx, uid, q)
	if err != nil {
		return ListResult{}, logger.RedactErr(err, uid)
	}
	res := ListResult{Notifications: rows}
	full := len(rows) == limit
	oldest := cursor.Cursor{}
	if len(rows) > 0 {
		last := rows[len(rows)-1]
		oldest = cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}
	}

	switch {
	case since != nil: // refresh
		if full {
			res.GapPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest, Lower: since}, now)
		}
		res.SinceToken = s.sinceToken(uid, rows, since, now)
	case in.PageToken != "": // scroll or gap fill
		if full {
			res.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest, Lower: gapLower}, now)
		}
	default: // cold open
		if full {
			res.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, pageBinding(uid), cursor.Window{Upper: oldest}, now)
		}
		res.SinceToken = s.sinceToken(uid, rows, nil, now)
	}

	if profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid}); err == nil {
		res.SeenAt = profiles[uid].NotificationsSeenAt
	}
	return res, nil
}

// sinceToken returns the token for the next refresh: the newest returned row trailing by SettleWindow, the old
// position when nothing new arrived, or "now - settle" for an empty first page.
func (s *service) sinceToken(uid string, rows []Notification, prev *cursor.Cursor, now time.Time) string {
	var c cursor.Cursor
	switch {
	case len(rows) > 0:
		c = cursor.Cursor{CreatedAt: rows[0].CreatedAt.Add(-SettleWindow), DocID: rows[0].ID}
	case prev != nil:
		c = *prev
	default:
		c = cursor.Cursor{CreatedAt: now.Add(-SettleWindow), DocID: "-"}
	}
	return cursor.EncodeAt(s.d.CursorKey, sinceBinding(uid), c, now)
}

// MarkSeen: 0 reads, 1 write.
func (s *service) MarkSeen(ctx context.Context, uid, idempotencyKey string) (time.Time, error) {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return time.Time{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	at := s.d.Now().UTC().Truncate(time.Microsecond)
	if err := s.d.Seen.MarkNotificationsSeen(ctx, uid, at); err != nil {
		if errors.Is(err, identity.ErrNotFound) {
			return time.Time{}, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "profile required")
		}
		return time.Time{}, logger.RedactErr(fmt.Errorf("notifications: mark seen: %w", err), uid)
	}
	// The cached profile carries the old seen_at and the cached unread count the old badge: evict both here.
	s.d.Directory.Forget(uid)
	return at, nil
}

// validateToken checks the registration token's shape. It never echoes the token.
func validateToken(token string) error {
	if token == "" || len(token) > MaxFCMTokenBytes {
		return apierr.Validation("fcm_token", "fcm_token must be 1-4096 bytes")
	}
	if strings.IndexFunc(token, func(r rune) bool { return r <= ' ' || r == 0x7f }) >= 0 {
		return apierr.Validation("fcm_token", "fcm_token must not contain whitespace or control characters")
	}
	return nil
}

// RegisterDevice: reads worst 8 / typical 2, writes worst 5 / typical 2 (0 when fresh). See FirestoreRepo.RegisterDevice.
func (s *service) RegisterDevice(ctx context.Context, uid string, in DeviceInput) error {
	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !deviceIDPattern.MatchString(in.DeviceID) {
		return apierr.Validation("device_id", "device_id must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if err := validateToken(in.Token); err != nil {
		return err
	}
	if in.Platform != PlatformIOS && in.Platform != PlatformAndroid {
		return apierr.Validation("platform", "platform must be ios or android")
	}
	err := s.d.Repo.RegisterDevice(ctx, uid, Device{ID: in.DeviceID, Token: in.Token, Platform: in.Platform}, s.d.Now().UTC())
	if err != nil {
		return logger.RedactErr(fmt.Errorf("notifications: register device: %w", err), uid)
	}
	slog.InfoContext(ctx, "notification_device_registered", "uid_hash", logger.HashUID(uid), "platform", string(in.Platform))
	return nil
}

// UnregisterDevice: reads 2, deletes 0-2.
func (s *service) UnregisterDevice(ctx context.Context, uid, idempotencyKey, deviceID string) error {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !deviceIDPattern.MatchString(deviceID) {
		return apierr.Validation("device_id", "device_id must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if err := s.d.Repo.RemoveDevice(ctx, uid, deviceID, ""); err != nil {
		return logger.RedactErr(fmt.Errorf("notifications: unregister device: %w", err), uid)
	}
	return nil
}
