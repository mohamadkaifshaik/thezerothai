package keys

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ratelimit"
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
	fieldReason      = "remove_reason"
	outcomeDone      = "done"
	outcomeNoop      = "noop"
	outcomeRejected  = "rejected:"
	rejectValidation = "validation"
)

// MaxLookupUsers is the most user ids one GetDevices takes.
const MaxLookupUsers = 10

// lookupFanout bounds the concurrent device queries of one GetDevices (at most MaxLookupUsers in all).
const lookupFanout = 4

// LimitClaimsPerTargetDaily is the limit_name (RATE_LIMITED metadata["limit"]) of the per-(caller, target) daily cap on
// ClaimKeyPackages (KEYS_CLAIMS_PER_TARGET_PER_DAY).
const LimitClaimsPerTargetDaily = "keys_claims_per_target_daily"

// Deps wires the service. A nil Permission refuses every other user; a nil Flags is off for every target; a nil ClaimCap
// leaves claims uncapped per target (the composition root always sets it).
type Deps struct {
	Repo       Repo
	Now        func() time.Time
	Permission Permission
	Flags      FlagChecker
	// ClaimCap is the per-(caller, target) daily cap on Claim (KEYS_CLAIMS_PER_TARGET_PER_DAY), keyed by claimCapKey.
	ClaimCap *ratelimit.DailyCap
	// ChargeLookups reserves one unit per validated target before any permission or device read.
	ChargeLookups func(context.Context, string, int) error
	// ConversationID is messaging.ConversationID, injected by the composition root (keys never imports messaging).
	// Required: newKeysModule fails when nil. A service built without it answers "" as the conversation id of a claim.
	ConversationID func(callerUID, targetUID string) string
	// Log receives panics on the lookup's worker goroutines (default slog.Default()).
	Log *slog.Logger
	// ReauthMaxAge is ACCOUNT_DELETE_REAUTH_MAX_AGE (config.AccountDeleteReauthMaxAge): how recent the caller's sign-in
	// must be for a REMOTE removal of an id not yet marked. Zero refuses every such removal (fail closed).
	ReauthMaxAge time.Duration
}

type service struct {
	repo          Repo
	now           func() time.Time
	perm          Permission
	flags         FlagChecker
	claimCap      *ratelimit.DailyCap
	chargeLookups func(context.Context, string, int) error
	convID        func(callerUID, targetUID string) string
	log           *slog.Logger
	reauthMaxAge  time.Duration
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
	return &service{repo: d.Repo, now: now, perm: d.Permission, flags: d.Flags, claimCap: d.ClaimCap, chargeLookups: d.ChargeLookups,
		convID: d.ConversationID, log: log, reauthMaxAge: d.ReauthMaxAge}
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

// fieldStuckRemovals is the request-line count of stuck REMOTE removals a Register finished (a count, never an id).
const fieldStuckRemovals = "stuck_removals_finished"

// Register validates, then publishes or refreshes the device. At the cap, when the repository reports device documents
// carrying removedAt (StuckRemovalsError: REMOTE removals that stopped after their mark), it finishes each of them with
// repo.Remove (the ids are already marked, so no sign-in is needed and the marks stay) and runs the repository's Register
// once more; a second StuckRemovalsError is LIMIT_REACHED, never a loop. Without this, up to MaxDevicesPerUser
// interrupted removals would hold every slot for good, with nothing in ListMyKeyDevices to remove.
func (s *service) Register(ctx context.Context, uid, deviceID string, signatureKey []byte) (Device, error) {
	begin(ctx, "register")
	if err := validDeviceID(ctx, deviceID); err != nil {
		return Device{}, err
	}
	if len(signatureKey) != SignatureKeyBytes {
		return Device{}, invalid(ctx, "signature_public_key", "signature_public_key must be exactly 32 bytes")
	}
	now := s.now()
	in := Device{ID: deviceID, SignatureKey: cloneBytes(signatureKey), CreatedAt: now, LastSeenAt: now}
	d, err := s.repo.Register(ctx, uid, in, now)
	var stuck *StuckRemovalsError
	if errors.As(err, &stuck) {
		for _, id := range stuck.DeviceIDs {
			if rerr := s.repo.Remove(ctx, uid, id); rerr != nil {
				return Device{}, s.mapErr(ctx, "register", uid, logger.RedactErr(rerr, id))
			}
		}
		logger.SetRequestField(ctx, fieldStuckRemovals, len(stuck.DeviceIDs))
		d, err = s.repo.Register(ctx, uid, in, now)
	}
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

// ListMine answers the caller's devices, oldest first, inactive ones included and marked (Inactive, from the clock).
func (s *service) ListMine(ctx context.Context, uid string) ([]Device, error) {
	begin(ctx, "list")
	ds, err := s.repo.List(ctx, uid)
	if err != nil {
		return nil, s.mapErr(ctx, "list", uid, err)
	}
	now := s.now()
	out := make([]Device, 0, len(ds))
	for _, d := range ds {
		d = cloneDevice(d)
		d.Inactive = !d.Active(now)
		out = append(out, d)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	logger.SetRequestField(ctx, fieldDevices, len(out))
	return out, nil
}

// Remove validates the id and the reason, then deletes the device; a missing device is success. RemoveRemote marks the id
// first (removal-server design 2026-11-23, 2.3): (1) whether the sign-in is recent (authn.IsRecentSignIn with
// ACCOUNT_DELETE_REAUTH_MAX_AGE; no read); (2) the mark transaction (MarkRemoved), which decides on the documents it reads:
// a retry (a mark, and no device document or one already carrying removedAt) needs no recent sign-in, anything else
// (no mark yet, or a mark over a live document an image without the marks wrote) does, else REAUTH_REQUIRED with nothing
// written; it stamps the device document with removedAt, so every read skips it from here on; (3) the usual sweep and
// delete. A REMOTE removal of an id that was never registered still writes a mark, so the answer tells nothing about
// whether the id existed.
func (s *service) Remove(ctx context.Context, uid, deviceID string, reason RemoveReason) error {
	begin(ctx, "remove")
	if err := validDeviceID(ctx, deviceID); err != nil {
		return err
	}
	if reason != RemoveSignOut && reason != RemoveRemote {
		return invalid(ctx, "reason", "reason must be a known RemoveReason")
	}
	logger.SetRequestField(ctx, fieldReason, reason.String())
	if reason == RemoveRemote {
		now := s.now()
		// A zero window is refused here too: authn.IsRecentSignIn with maxAge 0 still accepts an auth_time equal to now.
		maxAge := s.reauthMaxAge
		if maxAge <= 0 {
			maxAge = -time.Hour
		}
		recent := authn.IsRecentSignIn(ctx, maxAge, now)
		err := s.repo.MarkRemoved(ctx, uid, deviceID, now, recent)
		if errors.Is(err, ErrReauthRequired) {
			logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"reauth_required")
			return reauthRequired(ctx, maxAge, now)
		}
		if err != nil {
			return s.mapErr(ctx, "remove", uid, err)
		}
	}
	if err := s.repo.Remove(ctx, uid, deviceID); err != nil {
		return s.mapErr(ctx, "remove", uid, err)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	return nil
}

// reauthRequired is authn's own REAUTH_REQUIRED answer (same text, and reauth_required=true on the request line), for a
// MarkRemoved that refused (ErrReauthRequired): the sign-in that decided it was not recent, so RequireRecentSignIn with
// the same inputs refuses too. The fallback is the same answer, should the two ever disagree.
func reauthRequired(ctx context.Context, maxAge time.Duration, now time.Time) error {
	if err := authn.RequireRecentSignIn(ctx, maxAge, now); err != nil {
		return err
	}
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_REAUTH_REQUIRED, "please sign in again to continue")
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

// GetDevices, in this order: (1) validates the ids; (2) checks permission for every other user in request order (before
// any flag check, shared-conversation check or read); (3) asks Permission.SharesEncryptedConversation for every other user
// in request order (a failure is an error before any device read; a nil Permission is "not shared"); (4) reads devices
// concurrently, at most MaxLookupUsers queries of at most MaxDevicesPerUser documents each: the caller's own active
// devices when the caller's flag is on; for another user every registered device (List) when the pair shares an
// accepted encrypted conversation (a pending message request does not count), else the active devices (ActiveDevices)
// when the flag is on for both, else nothing; (5) strips another user's device to id, key and the Inactive marker.
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
	if s.chargeLookups != nil {
		if err := s.chargeLookups(ctx, uid, len(userIDs)); err != nil {
			logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"rate_limited")
			return nil, err
		}
	}
	for _, id := range userIDs {
		if id != uid {
			if err := s.permit(ctx, "get_devices", uid, id); err != nil {
				return nil, err
			}
		}
	}
	callerOn := s.targetOn(uid)
	shared := make([]bool, len(userIDs))
	if s.perm != nil {
		for i, id := range userIDs {
			if id == uid {
				continue
			}
			ok, err := s.perm.SharesEncryptedConversation(ctx, uid, id)
			if err != nil {
				return nil, s.mapErr(ctx, "get_devices", uid, sealPermissionErr(err, uid, id))
			}
			shared[i] = ok
		}
	}
	now := s.now()
	found := make([][]Device, len(userIDs))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(lookupFanout)
	for i, id := range userIDs {
		var read func(context.Context, string, time.Time) ([]Device, error)
		switch {
		case id == uid:
			if callerOn {
				read = s.repo.ActiveDevices
			}
		case shared[i]:
			read = func(ctx context.Context, target string, _ time.Time) ([]Device, error) {
				return s.repo.List(ctx, target)
			}
		case callerOn && s.targetOn(id):
			read = s.repo.ActiveDevices
		}
		if read == nil {
			continue
		}
		g.Go(mw.RecoverGo(ctx, s.log, "keys/lookup_worker", func() error {
			ds, err := read(gctx, id, now)
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
			inactive := !d.Active(now)
			if inactive && !shared[i] {
				continue // the activity filter of the ActiveDevices paths; a shared pair gets every registered device
			}
			d = cloneDevice(d)
			d.Inactive = inactive
			if id != uid {
				// Another user's device: only its id, signature key and the Inactive marker. No counts and no
				// timestamps (the handler sends zero times as absent); Inactive has already used LastSeenAt.
				d.PoolCount, d.HasLastResort = 0, false
				d.CreatedAt, d.LastSeenAt = time.Time{}, time.Time{}
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

var _ DeviceDirectory = (*service)(nil)

// ActiveDeviceIDs implements DeviceDirectory: one ActiveDevices query (Limit MaxDevicesPerUser), filtered again with
// Active(now) like GetDevices, with no permission or flag check and no request-line field.
func (s *service) ActiveDeviceIDs(ctx context.Context, uid string) ([]string, error) {
	now := s.now()
	ds, err := s.repo.ActiveDevices(ctx, uid, now)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("keys: active device ids: %w", err), uid)
	}
	out := make([]string, 0, len(ds))
	for _, d := range ds {
		if d.Active(now) {
			out = append(out, d.ID)
		}
	}
	return out, nil
}

// DeviceIDs implements DeviceDirectory: one List query (Limit MaxDevicesPerUser), inactive devices included, with no
// permission or flag check and no request-line field.
func (s *service) DeviceIDs(ctx context.Context, uid string) ([]string, error) {
	ds, err := s.repo.List(ctx, uid)
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("keys: device ids: %w", err), uid)
	}
	out := make([]string, 0, len(ds))
	for _, d := range ds {
		out = append(out, d.ID)
	}
	return out, nil
}

// Claim validates, draws one unit of the per-(caller, target) daily cap (every well-formed request, the caller's own id
// included), checks permission and the target's flag (another user), then claims through the repository
// (compare-and-delete per device). The excluded device is passed to the repository only for the caller's own id, where it must exist; for another user
// a well-formed exclude_device_id is accepted and not used (it exists for a device claiming its own user's others).
//
// It also returns the id of the (caller, target) conversation (the injected ConversationID) on every nil-error return for
// another user, the flag-off target's empty success included; "" for a self-claim and with every error.
func (s *service) Claim(ctx context.Context, uid, targetUID, excludeDeviceID string) ([]Claimed, string, error) {
	begin(ctx, "claim")
	if !ids.ValidUID(targetUID) {
		return nil, "", invalid(ctx, "user_id", ids.UIDMessage)
	}
	self := targetUID == uid
	if (self || excludeDeviceID != "") && !ValidDeviceID(excludeDeviceID) {
		return nil, "", invalid(ctx, "exclude_device_id", excludeMessage)
	}
	// The per-(caller, target) daily cap: counted for every well-formed request, self included, before the permission
	// check, the target's flag or any read, so a capped answer is the same for a blocked, unknown or real target.
	if s.claimCap != nil && !s.claimCap.Allow(claimCapKey(uid, targetUID)) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"rate_limited")
		return nil, "", s.claimCap.ExceededError(ctx, LimitClaimsPerTargetDaily)
	}
	exclude, convID := "", ""
	if self {
		exclude = excludeDeviceID
	} else {
		if err := s.permit(ctx, "claim", uid, targetUID); err != nil {
			return nil, "", err
		}
		if s.convID != nil {
			convID = s.convID(uid, targetUID)
		}
		if !s.targetOn(targetUID) {
			logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
			logger.SetRequestField(ctx, fieldDevices, 0)
			return []Claimed{}, convID, nil
		}
	}
	got, err := s.repo.Claim(ctx, targetUID, exclude, s.now())
	if errors.Is(err, ErrExcludeNotFound) {
		return nil, "", invalid(ctx, "exclude_device_id", excludeMessage)
	}
	if err != nil {
		return nil, "", s.mapErr(ctx, "claim", uid, logger.RedactErr(err, targetUID))
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
	return out, convID, nil
}

// claimCapKey is the per-target cap's key for the ordered pair (caller, target): the first 32 hex characters of the
// SHA-256 of "caller|target" ('|' is not a uid character, so the pair is unambiguous). Fixed-size, and it names neither
// uid, so the in-memory counter table holds no user id.
func claimCapKey(callerUID, targetUID string) string {
	sum := sha256.Sum256([]byte(callerUID + "|" + targetUID))
	return hex.EncodeToString(sum[:16])
}

// deviceRemovedText is the one text of DEVICE_REMOVED.
const deviceRemovedText = "this device was removed from your account"

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
	case errors.Is(err, ErrDeviceRemoved):
		// No metadata and no retry hint: the id is refused for at least RemovalMarkTTL; the device sets up again under a
		// new id. The id is never in the error or the log.
		logger.SetRequestField(ctx, fieldOutcome, outcomeRejected+"device_removed")
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_DEVICE_REMOVED, deviceRemovedText)
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
