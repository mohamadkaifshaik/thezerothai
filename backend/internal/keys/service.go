package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"
	"golang.org/x/sync/errgroup"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields: enums and counts only, never a device id, a key or a key package.
const (
	fieldOp          = "keys_op"
	fieldOutcome     = "outcome"
	fieldDevices     = "device_count"
	fieldPackages    = "package_count"
	fieldPoolCount   = "pool_count"
	fieldLastResort  = "has_last_resort"
	fieldUsers       = "user_count"
	fieldLRUsed      = "last_resort_count"
	outcomeDone      = "done"
	outcomeNoop      = "noop"
	outcomeRejected  = "rejected:"
	rejectValidation = "validation"
)

// MaxLookupUsers is the most user ids one GetDevices takes.
const MaxLookupUsers = 10

// lookupFanout bounds the concurrent device queries of one GetDevices (at most MaxLookupUsers in all).
const lookupFanout = 4

// Deps wires the service. A nil Permission refuses every other user; a nil Flags is off for every target.
type Deps struct {
	Repo       Repo
	Now        func() time.Time
	Permission Permission
	Flags      FlagChecker
	// Log receives panics on the lookup's worker goroutines (default slog.Default()).
	Log *slog.Logger
}

type service struct {
	repo  Repo
	now   func() time.Time
	perm  Permission
	flags FlagChecker
	log   *slog.Logger
}

// New builds the service.
func New(d Deps) Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	log := d.Log
	if log == nil {
		log = slog.Default()
	}
	return &service{repo: d.Repo, now: now, perm: d.Permission, flags: d.Flags, log: log}
}

var _ Service = (*service)(nil)

func begin(ctx context.Context, op string) { logger.SetRequestField(ctx, fieldOp, op) }

// invalid records the rejection on the request line and returns the VALIDATION error. The value is never echoed.
func invalid(ctx context.Context, field, msg string) error {
	logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+rejectValidation)
	return apierr.Validation(field, msg)
}

func validDeviceID(ctx context.Context, id string) error {
	if !ValidDeviceID(id) {
		return invalid(ctx, "device_id", "device_id must be 16-64 characters of [A-Za-z0-9_-]")
	}
	return nil
}

// Register validates, then publishes or refreshes the device.
func (s *service) Register(ctx context.Context, uid, deviceID string, signatureKey []byte) (Device, error) {
	begin(ctx, "register")
	if err := validDeviceID(ctx, deviceID); err != nil {
		return Device{}, err
	}
	if len(signatureKey) != SignatureKeyBytes {
		return Device{}, invalid(ctx, "signature_public_key", "signature_public_key must be exactly 32 bytes")
	}
	now := s.now()
	d, err := s.repo.Register(ctx, uid, Device{ID: deviceID, SignatureKey: cloneBytes(signatureKey), CreatedAt: now, LastSeenAt: now}, now)
	if err != nil {
		return Device{}, s.mapErr(ctx, "register", uid, err)
	}
	if d.LastSeenAt.Equal(now) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
	return cloneDevice(d), nil
}

// ListMine answers the caller's devices, oldest first, inactive ones included.
func (s *service) ListMine(ctx context.Context, uid string) ([]Device, error) {
	begin(ctx, "list")
	ds, err := s.repo.List(ctx, uid)
	if err != nil {
		return nil, s.mapErr(ctx, "list", uid, err)
	}
	out := make([]Device, 0, len(ds))
	for _, d := range ds {
		out = append(out, cloneDevice(d))
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldDevices, len(out))
	return out, nil
}

// Remove validates the id, then deletes the device; a missing device is success.
func (s *service) Remove(ctx context.Context, uid, deviceID string) error {
	begin(ctx, "remove")
	if err := validDeviceID(ctx, deviceID); err != nil {
		return err
	}
	if err := s.repo.Remove(ctx, uid, deviceID); err != nil {
		return s.mapErr(ctx, "remove", uid, err)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	return nil
}

// Upload validates, deduplicates the packages by bytes (first occurrence wins, order kept) and hands copies to the repo.
func (s *service) Upload(ctx context.Context, uid, deviceID string, packages [][]byte, lastResort []byte) (int, bool, error) {
	begin(ctx, "upload")
	if err := validDeviceID(ctx, deviceID); err != nil {
		return 0, false, err
	}
	if len(packages) > MaxUploadBatch {
		return 0, false, invalid(ctx, "key_packages", "at most 100 key packages per upload")
	}
	for _, p := range packages {
		if len(p) < 1 || len(p) > MaxKeyPackageBytes {
			return 0, false, invalid(ctx, "key_packages", "each key package must be 1-4096 bytes")
		}
	}
	if len(lastResort) > MaxKeyPackageBytes {
		return 0, false, invalid(ctx, "last_resort_key_package", "last_resort_key_package must be 1-4096 bytes")
	}
	// proto3 cannot tell an empty bytes field from an absent one, so empty means "no last-resort package".
	var lr []byte
	if len(lastResort) > 0 {
		lr = cloneBytes(lastResort)
	}
	if len(packages) == 0 && lr == nil {
		return 0, false, invalid(ctx, "key_packages", "send key_packages or last_resort_key_package")
	}
	uniq := dedupe(packages)
	logger.SetRequestField(ctx, fieldPackages, len(uniq))
	n, has, err := s.repo.Upload(ctx, uid, deviceID, uniq, lr, s.now())
	if err != nil {
		return 0, false, s.mapErr(ctx, "upload", uid, err)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldPoolCount, n)
	logger.SetRequestField(ctx, fieldLastResort, has)
	return n, has, nil
}

// cannotMessageText is the one text of every CANNOT_MESSAGE answer (the same words as messaging's).
const cannotMessageText = "you can't message this account"

// cannotMessage is the single refusal of GetDevices and Claim for every cause: built here only, fresh on each call (so
// no caller can mutate a shared value), with no metadata, cause or retry hint, so its wire form is byte-identical.
func cannotMessage(ctx context.Context) error {
	logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"cannot_message")
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE, cannotMessageText)
}

// permit asks the messaging rules whether uid may message target. As far as the wire is concerned the seam's answer is
// one of three things: nil (allowed); a refusal (ErrCannotMessage, or any *apierr.Error with reason CANNOT_MESSAGE,
// whatever its message or metadata), which becomes the one cannotMessage value; or a failure to decide, which is sealed
// so nothing of the seam's error reaches the client (see sealPermissionErr). No separate existence check: the seam
// refuses an unknown user exactly like a blocked one.
func (s *service) permit(ctx context.Context, op, uid, target string) error {
	if s.perm == nil {
		return cannotMessage(ctx)
	}
	err := s.perm.CanMessage(ctx, uid, target)
	if err == nil {
		return nil
	}
	var ae *apierr.Error
	if errors.Is(err, ErrCannotMessage) || errors.As(err, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_CANNOT_MESSAGE {
		return cannotMessage(ctx)
	}
	return s.mapErr(ctx, op, uid, sealPermissionErr(err, uid, target))
}

// sealPermissionErr turns a seam failure into an error that carries nothing the client could see: no *apierr.Error or
// *connect.Error is reachable through it (so its code, reason, message, metadata and retry hint are dropped), only its
// class survives, the way mapErr derives classes for repository errors: contention stays Aborted and a deadline stays
// DeadlineExceeded (both UNAVAILABLE with retry), anything else is an unknown error (INTERNAL). The text, with both uids
// hashed, is kept for the server log.
func sealPermissionErr(err error, uid, target string) error {
	text := logger.RedactErr(fmt.Errorf("keys: permission: %w", err), uid, target).Error()
	switch {
	case store.IsContention(err):
		return status.Error(codes.Aborted, text)
	case errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		return status.Error(codes.DeadlineExceeded, text)
	}
	return errors.New(text)
}

// targetOn reports whether the flag is on for target (a nil checker is off).
func (s *service) targetOn(target string) bool {
	return s.flags != nil && s.flags.Enabled(target, FlagName)
}

// GetDevices validates the ids, checks permission for every other user in request order (before any flag check or
// read), then reads the active devices of the caller and of every other user with the flag on, concurrently (at most
// MaxLookupUsers queries of at most MaxDevicesPerUser documents each).
func (s *service) GetDevices(ctx context.Context, uid string, userIDs []string) (map[string][]Device, error) {
	begin(ctx, "get_devices")
	if len(userIDs) < 1 || len(userIDs) > MaxLookupUsers {
		return nil, invalid(ctx, "user_ids", "send 1-10 user_ids")
	}
	seen := make(map[string]bool, len(userIDs))
	for _, id := range userIDs {
		if !ids.ValidUID(id) {
			return nil, invalid(ctx, "user_ids", ids.UIDMessage)
		}
		if seen[id] {
			return nil, invalid(ctx, "user_ids", "user_ids must be distinct")
		}
		seen[id] = true
	}
	logger.SetRequestField(ctx, fieldUsers, len(userIDs))
	for _, id := range userIDs {
		if id != uid {
			if err := s.permit(ctx, "get_devices", uid, id); err != nil {
				return nil, err
			}
		}
	}
	now := s.now()
	found := make([][]Device, len(userIDs))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(lookupFanout)
	for i, id := range userIDs {
		if id != uid && !s.targetOn(id) {
			continue
		}
		g.Go(mw.RecoverGo(ctx, s.log, "keys/lookup_worker", func() error {
			ds, err := s.repo.ActiveDevices(gctx, id, now)
			if err != nil {
				return logger.RedactErr(err, id)
			}
			found[i] = ds
			return nil
		}))
	}
	if err := g.Wait(); err != nil {
		return nil, s.mapErr(ctx, "get_devices", uid, err)
	}
	out := make(map[string][]Device, len(userIDs))
	total := 0
	for i, id := range userIDs {
		list := make([]Device, 0, len(found[i]))
		for _, d := range found[i] {
			if !d.Active(now) {
				continue
			}
			d = cloneDevice(d)
			if id != uid {
				d.PoolCount, d.HasLastResort = 0, false
			}
			list = append(list, d)
		}
		out[id] = list
		total += len(list)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldDevices, total)
	return out, nil
}

// Claim validates, checks permission and the target's flag (another user), then claims through the repository
// (compare-and-delete per device). The excluded device is passed to the repository only for the caller's own id, where it must exist; for another user
// a well-formed exclude_device_id is accepted and not used (it exists for a device claiming its own user's others).
func (s *service) Claim(ctx context.Context, uid, targetUID, excludeDeviceID string) ([]Claimed, error) {
	begin(ctx, "claim")
	if !ids.ValidUID(targetUID) {
		return nil, invalid(ctx, "user_id", ids.UIDMessage)
	}
	self := targetUID == uid
	if (self || excludeDeviceID != "") && !ValidDeviceID(excludeDeviceID) {
		return nil, invalid(ctx, "exclude_device_id", excludeMessage)
	}
	exclude := ""
	if self {
		exclude = excludeDeviceID
	} else {
		if err := s.permit(ctx, "claim", uid, targetUID); err != nil {
			return nil, err
		}
		if !s.targetOn(targetUID) {
			logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
			logger.SetRequestField(ctx, fieldDevices, 0)
			return []Claimed{}, nil
		}
	}
	got, err := s.repo.Claim(ctx, targetUID, exclude, s.now())
	if errors.Is(err, ErrExcludeNotFound) {
		return nil, invalid(ctx, "exclude_device_id", excludeMessage)
	}
	if err != nil {
		return nil, s.mapErr(ctx, "claim", uid, logger.RedactErr(err, targetUID))
	}
	out := make([]Claimed, 0, len(got))
	consumed, lastResort := 0, 0
	for _, c := range got {
		switch {
		case c.LastResort:
			lastResort++
		case c.HasKeyPackage:
			consumed++
		}
		out = append(out, cloneClaimed(c))
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldDevices, len(out))
	logger.SetRequestField(ctx, fieldPackages, consumed)
	logger.SetRequestField(ctx, fieldLRUsed, lastResort)
	return out, nil
}

// excludeMessage is the VALIDATION text for exclude_device_id (the value is never echoed).
const excludeMessage = "exclude_device_id must be one of your devices"

// dedupe returns copies of the distinct packages in first-seen order. At most MaxUploadBatch, so the scan is bounded.
func dedupe(packages [][]byte) [][]byte {
	out := make([][]byte, 0, len(packages))
	for _, p := range packages {
		dup := false
		for _, q := range out {
			if bytes.Equal(p, q) {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, cloneBytes(p))
		}
	}
	return out
}

// mapErr turns a repository error into the handler's answer. Sentinels become their API errors; shaped apierrs pass
// through; a client that left is CANCELED / DEADLINE_EXCEEDED; contention is a retryable UNAVAILABLE; anything else is an
// internal error with the uid replaced by its hash. No message carries a device id, key or package.
func (s *service) mapErr(ctx context.Context, op, uid string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrDeviceLimit):
		logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"limit_reached")
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, "too many encryption devices").
			WithMeta("limit", limitKeyDevices)
	case errors.Is(err, ErrKeyMismatch):
		return invalid(ctx, "signature_public_key", "this device is already registered with a different key")
	case errors.Is(err, ErrNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"not_found")
		return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "device not found")
	case errors.As(err, &ae):
		logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+ae.Code.String())
		return err
	}
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldOutcome, "contention")
		slog.WarnContext(ctx, "keys_contention", fieldOp, op, "uid_hash", logger.HashUID(uid))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
			WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("keys: %s: %w", op, err), uid)
}
