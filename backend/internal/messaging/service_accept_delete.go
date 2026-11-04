package messaging

import (
	"context"
	"errors"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line kinds of AcceptMessageRequest and DeleteConversation. The line also carries
// conversation_hash, state, replay, folder (delete), and refused_reason: never a uid, a conversation id, a snippet or text.
const (
	kindAccept = "accept"
	kindDelete = "delete"
)

// Accept implements Service.Accept.
//
// Flag: per caller (FEATURE_DISABLED before any read) and per recipient, the other participant (CANNOT_MESSAGE, the same
// bytes as a block; evaluated without a read, inside the transaction, only when something would be written). A malformed
// idempotency_key or conversation_id is VALIDATION before any read. The key is format-validated but not stored (the rule for
// a key the RPC does not use; founder decision 2026-10-29, option (a)): the RPC is idempotent by
// state, and a replay is success and writes nothing.
//
// Only the recipient of the request (requestTo) may accept. An unknown id, a non-participant, the requester and a
// conversation that never was a request answer one byte-identical NOT_FOUND, as does a request the caller already deleted
// for themselves, unless the peer is gone or outside the flag cohort: those two are checked before the caller's entry is
// read, so they answer CANNOT_MESSAGE even for a deleted request. An already ACCEPTED conversation is success with nothing
// written. After a commit the instance's conversation cache is replaced from the written data (the
// state is not trusted from a cache by Send, but ListMessages reads it) and the caller's badge cache is evicted: the
// entry's unreadCount now counts in the Inbox badge (Deps.Badge; nil until then). Nothing is emitted.
func (s *service) Accept(ctx context.Context, uid string, req *messagingv1.AcceptMessageRequestRequest) (*messagingv1.AcceptMessageRequestResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindAccept)
	// Defence in depth behind authn.VerifiedIdentityInterceptor (security review L-8): no read.
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "accepting message requests"); err != nil {
		return nil, err
	}
	id := req.GetConversationId()
	if err := validateKeyAndConv(req.GetIdempotencyKey(), id); err != nil {
		return nil, err
	}
	if s.d.Repo == nil {
		return nil, errors.New("messaging: accept is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	res, err := s.d.Repo.Accept(ctx, AcceptParams{
		UID: uid, ConvID: id, Now: s.d.Now(),
		PeerAllowed: func(peer string) bool { return s.flags != nil && s.flags.Enabled(peer, FlagName) },
	})
	if err != nil {
		return nil, s.lifecycleErr(ctx, uid, id, "accept", err)
	}
	logger.SetRequestField(ctx, fieldState, stateLabelAccept)
	logger.SetRequestField(ctx, fieldReplay, res.Already)
	s.putConv(id, res.Conv)
	if !res.Already && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.AcceptMessageRequestResponse{}, nil
}

// Delete implements Service.Delete: "delete for me", also "delete request".
//
// Flag: not globally off (a user dropped from the allowlist can still clean up). A malformed idempotency_key or
// conversation_id is VALIDATION before any read.
//
// The transaction sets clearedAt[caller] = now on the conversation, stores the digest of the idempotency_key as
// clearedKey[caller] in the same update (no extra read or write) and deletes the caller's own
// entry from the folder it lives in; the peer's entry, the messages and the conversation state are untouched. A deleted
// request stays a REQUEST for the sender, whose cap still applies; a later message recreates the caller's entry, and
// ListMessages shows only the messages newer than clearedAt. An unknown id and a non-participant answer one byte-identical
// NOT_FOUND.
//
// Replay: a retry with the same key (its digest equals clearedKey[caller]) is success with nothing written whatever
// happened since, so it can never hide a newer message or delete the entry that message recreated; a delete under another
// key that finds no entry and a clearedAt already set is success with nothing written too; a delete under a new key that
// finds an entry is a real delete.
//
// This instance's conversation cache is replaced from the written data, so clearedAt takes effect here at once; other
// instances converge within the cache TTL, 60 s (D14). The caller's badge cache is evicted when an entry was deleted
// (its unread count leaves the Inbox badge; Deps.Badge, nil until then).
func (s *service) Delete(ctx context.Context, uid string, req *messagingv1.DeleteConversationRequest) (*messagingv1.DeleteConversationResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindDelete)
	id := req.GetConversationId()
	if err := validateKeyAndConv(req.GetIdempotencyKey(), id); err != nil {
		return nil, err
	}
	if s.d.Repo == nil {
		return nil, errors.New("messaging: delete is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	res, err := s.d.Repo.Delete(ctx, DeleteParams{UID: uid, ConvID: id, Now: s.d.Now(), KeyDigest: keyDigest(uid, opDelete, req.GetIdempotencyKey())})
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
	s.putConv(id, res.Conv)
	if res.EntryDeleted && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.DeleteConversationResponse{}, nil
}

// lifecycleErr turns an Accept or Delete repo error into the wire answer: the two CANNOT_MESSAGE causes first (one wire
// answer, told apart only by refused_reason on the log line), then the shared tail (failure).
func (s *service) lifecycleErr(ctx context.Context, uid, convID, op string, err error) error {
	switch {
	case errors.Is(err, errPeerFlagOff):
		return s.refuse(ctx, refusedRecipientFlagOff)
	case errors.Is(err, ErrCannotMessage):
		return s.refuse(ctx, refusedGone)
	}
	return s.failure(ctx, op, uid, convID, err)
}

// validateKeyAndConv is step 1 of Accept, Delete and MarkRead, before any read: the key's format, then the conversation id. Accept
// and MarkRead do not store the key (idempotent by state, founder decision 2026-10-29: the rule for a key the RPC does
// not use, "unused but still format-validated"); Delete stores its digest (clearedKey). A malformed key is VALIDATION
// idempotency_key.
func validateKeyAndConv(key, convID string) error {
	if !idempotency.KeyFormatValid(key) {
		return invalidKey()
	}
	if !ValidID(convID) {
		return apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	return nil
}
