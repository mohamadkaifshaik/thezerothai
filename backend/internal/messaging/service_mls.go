package messaging

import (
	"context"
	"errors"
	"fmt"
	"math"
	"strconv"

	"cloud.google.com/go/firestore"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line fields of CommitConversation: kind, conversation_hash, reset, replay and refused_reason. Never the commit or
// welcome bytes, a device id or a uid.
const (
	kindCommit = "commit"
	fieldReset = "reset"
)

// maxCommitGen is the largest mls_generation a CommitConversation may state (2^63 - 2), so a reset's generation + 1 is
// still an int64.
const maxCommitGen = math.MaxInt64 - 1

// Commit implements Service.Commit: CommitConversation (proto, the RPC comment's numbered order).
//
// Flag: "messaging" on for the caller (perCaller, as SendMessage; e2ee_dm is not needed), then the verified email, both
// before any lookup. Step 1 (key, conversation id, the pair's form) is answered here before any read; the rest of the
// order runs in the repo's one transaction (Repo.Commit): the NOT_FOUND / VALIDATION conversation_id / CANNOT_MESSAGE
// refusals, retry recognition, the field verdict computed here (commitFieldErr), the welcome-device check, the pair. A
// recognised retry answers the conversation's current pair and writes nothing. The instance conversation cache is
// updated from the transaction's result. Nothing is emitted. Neither rev nor any message changes.
func (s *service) Commit(ctx context.Context, uid string, req *messagingv1.CommitConversationRequest) (*messagingv1.CommitConversationResponse, error) {
	if err := s.resetCap(ctx, uid, req); err != nil {
		return nil, err
	}
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindCommit)
	// Defence in depth behind authn.VerifiedIdentityInterceptor (security review L-8): no read.
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "changing a conversation's encryption"); err != nil {
		return nil, err
	}
	gen, epoch, err := validateCommitForm(req)
	if err != nil {
		return nil, err
	}
	if s.d.Repo == nil || s.d.Social == nil || s.d.TxSocial == nil {
		return nil, errors.New("messaging: commit is not configured")
	}
	id := req.GetConversationId()
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	logger.SetRequestField(ctx, fieldReset, req.GetReset_())
	p := CommitParams{
		UID: uid, ConvID: id, Gen: gen, Epoch: epoch, Reset: req.GetReset_(),
		Commit: req.GetCommit(), Welcome: req.GetWelcome(), DeviceIDs: req.GetWelcomeDeviceIds(),
		FieldErr: commitFieldErr(req), Now: s.d.Now(),
		RecipientGraphInTx: func(ctx context.Context, tx *firestore.Transaction, peer string) (graph.Snapshot, error) {
			return s.d.TxSocial.SnapshotInTx(ctx, tx, peer)
		},
		CallerBlocks: func(ctx context.Context, peer string) (bool, error) {
			mine, err := s.d.Social.Snapshot(ctx, uid)
			if err != nil {
				return false, err
			}
			return mine.Blocked[peer], nil
		},
		WelcomeTargets: s.commitWelcomeTargets(uid, req.GetWelcomeDeviceIds(), req.GetReset_()),
	}
	res, err := s.d.Repo.Commit(ctx, p)
	if err != nil {
		return nil, s.commitErr(ctx, uid, id, err)
	}
	logger.SetRequestField(ctx, fieldReplay, res.Retry)
	if res.Conv.State != "" && len(res.Conv.Participants) == 2 {
		s.putConv(id, res.Conv)
	}
	return &messagingv1.CommitConversationResponse{MlsGeneration: wirePair(res.Conv.MlsGen), MlsEpoch: wirePair(res.Conv.MlsEpoch)}, nil
}

// validateCommitForm is step 1, before any lookup: the key's format, the conversation id, and the pair's form
// (mls_generation 1 to 2^63 - 2; mls_epoch 1 to 2^63 - 1 unless reset, when it is ignored and returned as 0). It returns
// the pair as stored values.
func validateCommitForm(req *messagingv1.CommitConversationRequest) (gen, epoch int64, err error) {
	if err := validateKeyAndConv(req.GetIdempotencyKey(), req.GetConversationId()); err != nil {
		return 0, 0, err
	}
	g := req.GetMlsGeneration()
	if g < 1 || g > maxCommitGen {
		return 0, 0, apierr.Validation("mls_generation", "mls_generation must be 1-"+strconv.FormatInt(maxCommitGen, 10))
	}
	if req.GetReset_() {
		return int64(g), 0, nil
	}
	e := req.GetMlsEpoch()
	if e < 1 || e > math.MaxInt64 {
		return 0, 0, apierr.Validation("mls_epoch", "mls_epoch must be 1-"+strconv.FormatInt(math.MaxInt64, 10))
	}
	return int64(g), int64(e), nil
}

// commitFieldErr is the verdict of step 4's field rules, computed here (pure, no read) and answered by the transaction
// only after retry recognition: commit 1-16384 bytes (VALIDATION commit); the welcome and its device ids (validateWelcome:
// at most 65536 bytes, together, 1-10 distinct well-formed ids); a reset requires both (VALIDATION welcome_device_ids).
func commitFieldErr(req *messagingv1.CommitConversationRequest) error {
	if n := len(req.GetCommit()); n < 1 || n > MaxCommitBytes {
		return apierr.Validation("commit", "commit must be 1-"+strconv.Itoa(MaxCommitBytes)+" bytes")
	}
	if err := validateWelcome(req.GetWelcome(), req.GetWelcomeDeviceIds()); err != nil {
		return err
	}
	if req.GetReset_() && len(req.GetWelcomeDeviceIds()) == 0 {
		return apierr.Validation("welcome_device_ids", "a reset requires a welcome for at least one of the peer's devices")
	}
	return nil
}

// commitWelcomeTargets is CommitParams.WelcomeTargets: the ACTIVE device ids of the caller and the peer (2 queries of at
// most 5 documents, through Devices, never transactional), each id assigned to its owner; any id neither's, or a reset
// with none of the peer's, is errWelcomeDevices. The transaction calls it after the conversation read named the peer and
// only past the refusals and retry recognition; a successful verdict is kept for the transaction's re-runs, so a contended
// commit still costs at most the 2 queries. A lookup failure is an error, never "no devices".
func (s *service) commitWelcomeTargets(uid string, ids []string, reset bool) func(context.Context, string) ([]welcomeTarget, error) {
	var (
		done    bool
		targets []welcomeTarget
		verdict error
	)
	return func(ctx context.Context, peer string) ([]welcomeTarget, error) {
		if done {
			return targets, verdict
		}
		if s.d.Devices == nil {
			return nil, errors.New("messaging: commit has no device directory configured")
		}
		mine, err := s.d.Devices.ActiveDeviceIDs(ctx, uid)
		if err != nil {
			return nil, fmt.Errorf("messaging: caller devices: %w", err)
		}
		theirs, err := s.d.Devices.ActiveDeviceIDs(ctx, peer)
		if err != nil {
			return nil, fmt.Errorf("messaging: peer devices: %w", err)
		}
		t, ok := assignWelcomeTargets(ids, uid, peer, mine, theirs, reset)
		done, targets = true, t
		if !ok {
			targets, verdict = nil, errWelcomeDevices
		}
		return targets, verdict
	}
}

// commitErr turns a Commit repo error into the wire answer: the CANNOT_MESSAGE causes (one answer, told apart only by
// refused_reason), VALIDATION conversation_id for a NONE conversation, the welcome-device verdict, STALE_EPOCH with the
// current pair; then the shared tail (failure: an *apierr.Error such as the field verdict passes as is, ErrNotFound is the
// one NOT_FOUND, contention is "busy").
func (s *service) commitErr(ctx context.Context, uid, convID string, err error) error {
	switch {
	case errors.Is(err, errBlocked):
		return s.refuse(ctx, refusedBlocked)
	case errors.Is(err, ErrCannotMessage):
		return s.refuse(ctx, refusedGone)
	case errors.Is(err, errNotEncrypted):
		return apierr.Validation("conversation_id", "this conversation is not end-to-end encrypted: start encryption with SendMessage mls_init")
	case errors.Is(err, errWelcomeDevices):
		return commitWelcomeDevicesInvalid()
	}
	var stale *staleEpochError
	if errors.As(err, &stale) {
		return staleEpoch(stale.Gen, stale.Epoch, "")
	}
	return s.failure(ctx, "commit", uid, convID, err)
}
