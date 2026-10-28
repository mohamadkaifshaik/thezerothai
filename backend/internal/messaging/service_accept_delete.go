package messaging

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line kinds of AcceptMessageRequest and DeleteConversation (ADR-0027 D11, plan W7-9). The line also carries
// conversation_hash, state, replay, folder (delete), refused_reason and the fs_reads / fs_writes / fs_deletes the logging
// interceptor adds: never a uid, a conversation id, a snippet or text.
const (
	kindAccept = "accept"
	kindDelete = "delete"
)

// Accept implements Service.Accept (ADR-0027 D4, D6, D11; plan W7-9).
//
// Flag: per caller (FEATURE_DISABLED before any read) and per recipient, the other participant (CANNOT_MESSAGE, the same
// bytes as a block; evaluated without a read, inside the transaction, only when something would be written). A malformed
// conversation_id is VALIDATION with 0 reads. idempotency_key is not stored or validated: the RPC is idempotent by
// state (MarkConversationRead's rule), and a replay is success with 0 writes.
//
// Only the recipient of the request (requestTo) may accept. An unknown id, a non-participant, the requester and a
// conversation that never was a request answer one byte-identical NOT_FOUND, as does a request the caller already deleted
// for themselves. An already ACCEPTED conversation is success with nothing written. A request whose peer deleted the
// account is CANNOT_MESSAGE. After a commit the instance's conversation cache is replaced from the written data (the
// state is not trusted from a cache by Send, but ListMessages reads it) and the caller's badge cache is evicted: the
// entry's unreadCount now counts in the Inbox badge (Deps.Badge, W7-11; nil until then). Nothing is emitted.
//
// Worst-case Firestore cost (budget.Counter, the account-status interceptor read counted as the proto comment does):
//   - accept: reads 3 (interceptor 1, conversation 1, request entry 1), planning 2.5; writes 2 (conversation state, dmInbox
//     entry); deletes 1 (dmRequests entry)
//   - already accepted: reads 2, writes 0; unknown id, non-participant or the requester: NOT_FOUND after 2 reads
func (s *service) Accept(ctx context.Context, uid string, req *messagingv1.AcceptMessageRequestRequest) (*messagingv1.AcceptMessageRequestResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindAccept)
	id := req.GetConversationId()
	if !ValidID(id) {
		return nil, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	if s.d.Repo == nil {
		return nil, errors.New("messaging: accept is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(id))
	res, err := s.d.Repo.Accept(ctx, AcceptParams{
		UID: uid, ConvID: id, Now: s.d.Now(),
		PeerAllowed: func(peer string) bool { return s.flags != nil && s.flags.Enabled(peer, FlagName) },
	})
	if err != nil {
		return nil, s.lifecycleErr(ctx, uid, id, "accept", err)
	}
	logger.SetRequestField(ctx, fieldState, stateLabelAccept)
	logger.SetRequestField(ctx, fieldReplay, res.Already)
	s.convs.Set(id, res.Conv)
	if !res.Already && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.AcceptMessageRequestResponse{}, nil
}

// Delete implements Service.Delete (ADR-0027 D1, D14; plan W7-9): "delete for me", also "delete request".
//
// Flag: not globally off (a user dropped from the allowlist can still clean up). A malformed conversation_id is
// VALIDATION with 0 reads. idempotency_key is not stored or validated (idempotent by state, like MarkConversationRead).
//
// The transaction sets clearedAt[caller] = now on the conversation and deletes the caller's own entry from the folder it
// lives in; the peer's entry, the messages and the conversation state are untouched. A deleted request stays a REQUEST
// for the sender, whose cap still applies; a later message recreates the caller's entry, and ListMessages shows only the
// messages newer than clearedAt. An unknown id and a non-participant answer one byte-identical NOT_FOUND; a repeat of a
// delete that already happened (no entry, clearedAt set) is success with nothing written.
//
// This instance's conversation cache is replaced from the written data, so clearedAt takes effect here at once; other
// instances converge within the cache TTL, 60 s (D14). The caller's badge cache is evicted when an entry was deleted
// (its unread count leaves the Inbox badge; Deps.Badge, W7-11, nil until then).
//
// Worst-case Firestore cost (budget.Counter, interceptor counted as the proto comment does):
//   - delete: reads 3 (interceptor 1, conversation 1, the caller's entry 1), planning 2.5; writes 1 (clearedAt on the
//     conversation); deletes 1 (the caller's entry)
//   - repeat: reads 3, writes 0, deletes 0; unknown id or non-participant: NOT_FOUND after 2 reads
func (s *service) Delete(ctx context.Context, uid string, req *messagingv1.DeleteConversationRequest) (*messagingv1.DeleteConversationResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindDelete)
	id := req.GetConversationId()
	if !ValidID(id) {
		return nil, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	if s.d.Repo == nil {
		return nil, errors.New("messaging: delete is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(id))
	res, err := s.d.Repo.Delete(ctx, DeleteParams{UID: uid, ConvID: id, Now: s.d.Now()})
	if err != nil {
		return nil, s.lifecycleErr(ctx, uid, id, "delete", err)
	}
	state := stateLabelAccept
	if res.Conv.State == stateRequest {
		state = stateLabelRequest
	}
	folder := folderLabelInbox
	if res.Folder == entryRequests {
		folder = folderLabelRequests
	}
	logger.SetRequestField(ctx, fieldState, state)
	logger.SetRequestField(ctx, fieldFolder, folder)
	logger.SetRequestField(ctx, fieldReplay, res.Replay)
	s.convs.Set(id, res.Conv)
	if res.EntryDeleted && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.DeleteConversationResponse{}, nil
}

// lifecycleErr turns an Accept or Delete repo error into the wire answer. ErrNotFound is the one NOT_FOUND of an unknown
// id, a non-participant and a deleted conversation (D11). Both CANNOT_MESSAGE causes are the one wire answer, told apart
// only by refused_reason on the log line. Ids are redacted from anything that reaches an ERROR log: a Firestore error
// embeds document paths, and a path names a uid and a conversation.
func (s *service) lifecycleErr(ctx context.Context, uid, convID, op string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.As(err, &ae):
		return err
	case errors.Is(err, ErrNotFound):
		return notFound()
	case errors.Is(err, errPeerFlagOff):
		return s.refuse(ctx, refusedRecipientFlagOff)
	case errors.Is(err, ErrCannotMessage):
		return s.refuse(ctx, refusedGone)
	case ctxFailure(ctx) != nil:
		return ctxFailure(ctx)
	case errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		s.d.Log.WarnContext(ctx, "messaging_"+op+"_contention", slog.String("uid_hash", logger.HashUID(uid)), slog.String(fieldConvHash, logger.HashUID(convID)))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "busy, please retry").WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("messaging: %s: %w", op, err), uid, convID)
}
