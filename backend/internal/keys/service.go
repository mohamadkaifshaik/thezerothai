package keys

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
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
	outcomeDone      = "done"
	outcomeNoop      = "noop"
	outcomeRejected  = "rejected:"
	rejectValidation = "validation"
)

// Deps wires the service.
type Deps struct {
	Repo Repo
	Now  func() time.Time
}

type service struct {
	repo Repo
	now  func() time.Time
}

// New builds the service.
func New(d Deps) Service {
	now := d.Now
	if now == nil {
		now = time.Now
	}
	return &service{repo: d.Repo, now: now}
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
