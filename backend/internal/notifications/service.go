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
	"github.com/dzeroth/dzeroth/backend/internal/graph"
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
	// Social is the caller's cached graph context: List hides rows whose actor the caller blocks or mutes, or who
	// blocks the caller, as of read time (a block after the fan-out check must take effect). Required.
	Social Social
	// Blocks answers "which of these actors blocked the caller" when the caller's blockedBy overflowed its cap (the
	// snapshot's BlockedBy is then incomplete). Never called otherwise. Nil with an overflowed caller fails the page.
	Blocks BlockLookup
	Seen   SeenStore
	// Validator checks a FCM token with a dry-run send before RegisterDevice stores it (N-5). Nil accepts every token.
	Validator TokenValidator
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

// List: reads the page of rows (20 at the default page, 50 at the maximum) and the caller's graph snapshot
// (cached 60 s). Only when the caller's blockedBy overflowed its cap does it also ask graph.BlockLookup about the
// page's actors: one call of at most graph.MaxBlockLookup users, each answered from the graph cache or by batched
// GetAlls of up to 25 docs (see overflowBlockers). The seen_at profile is the account-status interceptor's cached entry. It
// writes nothing.
//
// Filtering runs after the page query, so a page may come back shorter than page_size, or empty, while more rows
// exist: the tokens are computed from the raw rows (what was scanned), never the filtered ones, and the client
// keeps paging while next_page_token is set. There is deliberately no refill loop: reads stay bounded.
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
	// rows is the raw page: full, oldest and the since token below come from it, not from the filtered slice.
	var shown []Notification
	if len(rows) > 0 {
		snap, err := s.d.Social.Snapshot(ctx, uid)
		if err != nil {
			return ListResult{}, logger.RedactErr(fmt.Errorf("notifications: caller graph: %w", err), uid)
		}
		var ov *overflowBlocks
		if snap.BlockedByOverflow {
			ov, err = s.overflowBlockers(ctx, uid, rows, snap)
			if err != nil {
				return ListResult{}, err
			}
		}
		shown = make([]Notification, 0, len(rows))
		for _, n := range rows {
			if v, ok := visible(n, snap, ov); ok {
				shown = append(shown, v)
			}
		}
	}
	res := ListResult{Notifications: shown}
	if shown == nil {
		res.Notifications = []Notification{}
	}
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

	profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		// seen_at is a nicety (unread styling); the page itself is good. Log so a failing directory is visible.
		slog.WarnContext(ctx, "notifications_list_seen_at_unavailable", "uid_hash", logger.HashUID(uid), "err", logger.RedactErr(err, uid))
	} else {
		res.SeenAt = profiles[uid].NotificationsSeenAt
	}
	return res, nil
}

// overflowBlocks is what List established about the page's actors when the caller's blockedBy overflowed (F-04):
// blockers are the actors the graph module says blocked the caller; checked are the actors it was asked about.
type overflowBlocks struct {
	blockers map[string]bool
	checked  map[string]bool
}

// overflowBlockers asks graph.BlockLookup, in one batched call, which of the page's actors blocked the caller. Only
// actors the snapshot does not already hide are asked: every distinct shown actor first (at most MaxPageSize, always
// inside graph.MaxBlockLookup), then the folded ActorIDs in page order until the cap. A folded actor past the cap is
// unchecked and visible() counts it as suppressed. A failed or unwired lookup fails the whole page, the same policy
// as a failed caller-graph read: no row whose visibility is unknown is returned, and no token moves past rows that
// were never shown.
func (s *service) overflowBlockers(ctx context.Context, uid string, rows []Notification, snap graph.Snapshot) (*overflowBlocks, error) {
	known := func(id string) bool { return id == "" || snapHides(snap, id) }
	ov := &overflowBlocks{checked: map[string]bool{}}
	candidates := make([]string, 0, graph.MaxBlockLookup)
	add := func(id string) {
		if len(candidates) < graph.MaxBlockLookup && !known(id) && !ov.checked[id] {
			ov.checked[id] = true
			candidates = append(candidates, id)
		}
	}
	for _, n := range rows {
		add(n.Actor.UserID)
	}
	for _, n := range rows {
		for _, id := range n.ActorIDs {
			add(id)
		}
	}
	if len(candidates) == 0 {
		return ov, nil
	}
	if s.d.Blocks == nil {
		return nil, logger.RedactErr(errors.New("notifications: caller blockedBy overflowed and no block lookup is wired"), uid)
	}
	blockers, err := s.d.Blocks.BlockersAmong(ctx, uid, candidates)
	if err != nil {
		// The cause chain can name other users' graph documents: redact every uid the lookup was asked about.
		return nil, logger.RedactErr(fmt.Errorf("notifications: overflow block lookup: %w", err), append([]string{uid}, candidates...)...)
	}
	ov.blockers = blockers
	return ov, nil
}

// snapHides is the snapshot-only rule: the caller blocks or mutes id, or id is in the caller's blockedBy.
func snapHides(snap graph.Snapshot, id string) bool {
	return snap.Blocked[id] || snap.Muted[id] || snap.BlockedBy[id]
}

// visible applies the caller's social context at read time. A row is hidden when its displayed (most recent)
// actor is blocked or muted by the caller, or blocks the caller: the same set the timelines and thread replies
// use. For a collapsed row the other actors that are suppressed are subtracted from the count.
//
// ov is nil unless the caller's blockedBy overflowed; the snapshot alone then decides, with no read. When it is
// set, an actor the graph lookup reports as a blocker is hidden by the same rule, and a folded actor the lookup did
// not cover (past its cap) is treated as suppressed for the count: fail closed. The shown actor is always covered.
func visible(n Notification, snap graph.Snapshot, ov *overflowBlocks) (Notification, bool) {
	hidden := func(id string) bool { return snapHides(snap, id) }
	if ov != nil {
		hidden = func(id string) bool {
			return snapHides(snap, id) || ov.blockers[id] || (id != "" && !ov.checked[id])
		}
	}
	if hidden(n.Actor.UserID) {
		return n, false
	}
	suppressed := 0
	for _, id := range n.ActorIDs {
		if hidden(id) {
			suppressed++
		}
	}
	if suppressed > 0 {
		n.ActorCount = max(max(n.ActorCount, len(n.ActorIDs))-suppressed, 1)
	}
	return n, true
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

// MarkSeenMinInterval is how recent a cached notificationsSeenAt must be for MarkSeen to be a no-op: a client
// that marks seen on every tab focus must not turn each focus into a write.
const MarkSeenMinInterval = 10 * time.Second

// MarkSeen: the profile is the account-status interceptor's cached entry. It writes the seen_at, but nothing when the cached seen_at is younger than MarkSeenMinInterval (the cached value is returned and
// nothing is evicted).
func (s *service) MarkSeen(ctx context.Context, uid, idempotencyKey string) (time.Time, error) {
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return time.Time{}, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	now := s.d.Now().UTC()
	if profiles, err := s.d.Directory.GetProfiles(ctx, []string{uid}); err == nil {
		// A seenAt slightly in the future (another instance's clock) is fresh too: now.Sub is negative.
		if seen := profiles[uid].NotificationsSeenAt; !seen.IsZero() && now.Sub(seen) < MarkSeenMinInterval {
			return seen, nil
		}
	}
	at := now.Truncate(time.Microsecond)
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

// validateTimeout bounds the FCM dry run inside RegisterDevice's 5 s RPC deadline, leaving the transaction time.
const validateTimeout = 2 * time.Second

// checkToken runs the FCM dry run (N-5). Only a definitive rejection fails; every other outcome (timeout, quota,
// permission before the fcmSend role is applied, FCM down) logs a WARN with the fixed code and lets the
// registration through.
func (s *service) checkToken(ctx context.Context, uid, token string) error {
	if s.d.Validator == nil {
		return nil
	}
	vctx, cancel := context.WithTimeout(ctx, validateTimeout)
	defer cancel()
	err := s.d.Validator.Validate(vctx, token)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, ErrTokenInvalid):
		slog.WarnContext(ctx, "notification_device_token_rejected", "uid_hash", logger.HashUID(uid))
		return apierr.Validation("fcm_token", "fcm_token is not a valid registration token")
	}
	code := "UNKNOWN"
	var pe *PushError
	if errors.As(err, &pe) {
		code = pe.Code
	}
	slog.WarnContext(ctx, "notification_token_validation_skipped", "uid_hash", logger.HashUID(uid), "fcm_code", code)
	return nil
}

// RegisterDevice: see FirestoreRepo.RegisterDevice for what is read and written (a fresh registration writes nothing).
// The FCM dry-run validation (N-5) is a Google API call, not a Firestore operation, and a token it rejects returns
// INVALID_ARGUMENT before the repo is touched.
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
	if err := s.checkToken(ctx, uid, in.Token); err != nil {
		return err
	}
	err := s.d.Repo.RegisterDevice(ctx, uid, Device{ID: in.DeviceID, Token: in.Token, Platform: in.Platform}, s.d.Now().UTC())
	if err != nil {
		return logger.RedactErr(fmt.Errorf("notifications: register device: %w", err), uid)
	}
	slog.InfoContext(ctx, "notification_device_registered", "uid_hash", logger.HashUID(uid), "platform", string(in.Platform))
	return nil
}

// UnregisterDevice removes the device and its token index (see FirestoreRepo.RemoveDevice).
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
