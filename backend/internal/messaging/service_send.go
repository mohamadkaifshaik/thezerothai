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
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields of a send (ADR-0027 D11). Never the text, a snippet, a peer uid or a conversation id in clear.
const (
	fieldKind         = "kind"
	fieldConvHash     = "conversation_hash"
	fieldState        = "state"
	fieldRefused      = "refused_reason"
	fieldSilent       = "silent"
	fieldReplay       = "replay"
	kindSend          = "send"
	stateLabelAccept  = "accepted"
	stateLabelRequest = "request"
	stateLabelNew     = "new"
)

// refused_reason is a fixed enum that stays in the log: the wire answer is one CANNOT_MESSAGE for all of them.
const (
	refusedBlocked          = "blocked"
	refusedRecipientOff     = "recipient_inactive"
	refusedRecipientFlagOff = "recipient_flag_off"
	refusedGone             = "gone"
)

// Send implements Service.Send: ADR-0027 D4 steps 1 to 7.
//
// Flag: per caller (FEATURE_DISABLED before any read) and per recipient (CANNOT_MESSAGE, the same bytes as a block).
// Validation (key, target, text) and the self check cost 0 reads. The per-minute bucket and the MESSAGES_SENDS_PER_DAY
// cap run in the rate-limit interceptor; the new-account tier of that cap runs here.
//
// Worst-case Firestore cost (budget.Counter, interceptor read included as the proto comment counts it):
//   - accepted conversation: reads 5 cold (interceptor, caller graph, recipient graph, recipient profile through the
//     directory, conversation in the transaction), planning 2.5; writes 3 (message, two entries)
//   - existing REQUEST, the requester's next message: writes 4 (+ requestCount); the reply that accepts it: 4 writes and
//     1 delete (the replier's dmRequests entry moves to dmInbox)
//   - new conversation: reads 7 (+ the recipient's status fresh, quotas), writes 5 (message, conversation, two entries,
//     quotas.dmNew)
//   - by conversation_id with a cold conversation cache: +1 read (the participant check); warm +0
//   - replay: +1 read (the stored message), 0 writes; refused: at most 5 reads, 0 writes
func (s *service) Send(ctx context.Context, uid string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindSend)
	in, err := validateSend(uid, req)
	if err != nil {
		return nil, err
	}
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil {
		return nil, errors.New("messaging: send is not configured")
	}
	return s.send(ctx, uid, in)
}

// sendInput is a validated SendMessage request.
type sendInput struct {
	key, text string
	// convID is the target conversation (given, or derived from the pair); peer is "" until a conversation_id is resolved.
	convID, peer string
	byConvID     bool
}

// validateSend is step 1: the key, the target and the text, 0 reads.
func validateSend(uid string, req *messagingv1.SendMessageRequest) (sendInput, error) {
	var in sendInput
	if !idempotency.KeyFormatValid(req.GetIdempotencyKey()) {
		return in, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	in.key = req.GetIdempotencyKey()
	switch t := req.GetTarget().(type) {
	case *messagingv1.SendMessageRequest_ConversationId:
		if !ValidID(t.ConversationId) {
			return in, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
		}
		in.convID, in.byConvID = t.ConversationId, true
	case *messagingv1.SendMessageRequest_RecipientUserId:
		switch {
		case !ids.ValidUID(t.RecipientUserId):
			return in, apierr.Validation("recipient_user_id", "recipient_user_id is not a valid user id")
		case t.RecipientUserId == uid:
			return in, apierr.Validation("recipient_user_id", "you can't message yourself")
		}
		in.peer, in.convID = t.RecipientUserId, ConversationID(uid, t.RecipientUserId)
	default:
		return in, apierr.Validation("recipient_user_id", "conversation_id or recipient_user_id is required")
	}
	norm, err := text.Normalize(req.GetText())
	if err != nil {
		return in, err
	}
	in.text = norm
	return in, nil
}

func (s *service) send(ctx context.Context, uid string, in sendInput) (*messagingv1.SendMessageResponse, error) {
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(in.convID))
	// Step 2: a conversation_id resolves to its peer through the participant check (cached 60 s).
	if in.byConvID {
		conv, err := s.conversation(ctx, in.convID)
		if err != nil {
			return nil, s.mapErr(ctx, uid, in, err)
		}
		if !conv.hasParticipant(uid) {
			return nil, notFound()
		}
		if len(conv.Gone) > 0 {
			return nil, s.refuse(ctx, refusedGone)
		}
		if in.peer = peerOf(conv.Participants, uid); in.peer == "" {
			return nil, notFound() // not a two-person conversation: nothing a 1:1 send can address
		}
	}

	// Step 3: both graph snapshots (60 s cache) and both profiles (the caller's is warm behind the account-status
	// interceptor, the recipient's is the one directory read).
	mine, err := s.d.Social.Snapshot(ctx, uid)
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, fmt.Errorf("messaging: caller graph: %w", err))
	}
	theirs, err := s.d.Social.Snapshot(ctx, in.peer)
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, fmt.Errorf("messaging: recipient graph: %w", err))
	}
	profiles, err := s.d.Profiles.GetProfiles(ctx, []string{uid, in.peer})
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, fmt.Errorf("messaging: profiles: %w", err))
	}
	caller, ok := profiles[uid]
	if !ok {
		return nil, s.mapErr(ctx, uid, in, errors.New("messaging: caller profile unavailable"))
	}
	now := s.d.Now()
	if rerr := s.newAccountCap(ctx, uid, caller, now); rerr != nil {
		return nil, rerr
	}

	// Steps 3 and 4: every refusal is the one CANNOT_MESSAGE. A block is read from the two Blocked sets, which are
	// authoritative for their owner (the recipient's snapshot has no overflow case, ADR-0027 Context).
	peer, active := profiles[in.peer]
	switch {
	case mine.Blocked[in.peer] || theirs.Blocked[uid]:
		return nil, s.refuse(ctx, refusedBlocked)
	case !active:
		return nil, s.refuse(ctx, refusedRecipientOff)
	case s.flags == nil || !s.flags.Enabled(in.peer, FlagName):
		return nil, s.refuse(ctx, refusedRecipientFlagOff)
	}
	silent := theirs.Muted[uid]
	logger.SetRequestField(ctx, fieldSilent, silent)

	limit := s.d.Limits.DMNewPerDay
	if s.isNewAccount(caller, now) {
		limit = s.d.Limits.NewAccountDMNewPerDay
	}
	res, err := s.d.Repo.Send(ctx, SendParams{
		UID: uid, PeerUID: in.peer, ConvID: in.convID, MsgID: MessageID(uid, in.key),
		Text: in.text, RequestHash: requestHash(in.convID, in.text), Now: now,
		Mutual: mine.Following[in.peer] && theirs.Following[uid], Silent: silent, CallerSilent: mine.Muted[in.peer],
		Caller: peerDocOf(caller), Peer: peerDocOf(peer),
		MaxUnanswered: s.d.Limits.RequestMaxUnanswered, DMNewLimit: limit,
		FreshRecipient: func(ctx context.Context) error { return s.freshRecipient(ctx, in.peer) },
	})
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, err)
	}
	s.afterSend(ctx, uid, in, res, silent)
	return sendResponse(in.convID, MessageID(uid, in.key), peer, res, mine.Muted[in.peer]), nil
}

// afterSend is steps 6 and 7 and the request line: the instance cache is updated from the written data, the badge
// cache of both participants is evicted, and the push event leaves only for an accepted, non-silent, non-replayed
// message (a request never pushes, F7).
func (s *service) afterSend(ctx context.Context, uid string, in sendInput, res SendResult, silent bool) {
	logger.SetRequestField(ctx, fieldReplay, res.Replay)
	switch {
	case res.Created:
		logger.SetRequestField(ctx, fieldState, stateLabelNew)
	case res.Conv.State == stateRequest:
		logger.SetRequestField(ctx, fieldState, stateLabelRequest)
	default:
		logger.SetRequestField(ctx, fieldState, stateLabelAccept)
	}
	if res.Replay {
		return
	}
	if res.Conv.State != "" && len(res.Conv.Participants) == 2 {
		s.convs.Set(in.convID, res.Conv)
	}
	if s.d.Badge != nil {
		s.d.Badge.Forget(uid, in.peer)
	}
	if s.d.Events != nil && !res.RecipientInRequests && !silent {
		s.d.Events.MessageSent(ctx, MessageEvent{ActorUID: uid, RecipientUID: in.peer, ConversationID: in.convID, At: res.Msg.CreatedAt})
	}
}

// conversation is the participant check's read: the instance cache first (convCacheTTL), else 1 read. A missing
// document is NOT_FOUND, the same answer as a non-participant (D11).
func (s *service) conversation(ctx context.Context, id string) (ConvDoc, error) {
	c, _, err := s.conversationHit(ctx, id)
	return c, err
}

// conversationHit is conversation that also says whether the instance cache answered (the cache_hit log field).
func (s *service) conversationHit(ctx context.Context, id string) (ConvDoc, bool, error) {
	if c, ok := s.convs.Get(id); ok {
		return c, true, nil
	}
	c, found, err := s.d.Repo.GetConversation(ctx, id)
	if err != nil {
		return ConvDoc{}, false, err
	}
	if !found {
		return ConvDoc{}, false, ErrNotFound
	}
	s.convs.Set(id, c)
	return c, false, nil
}

// freshRecipient is the purge-race check of a new conversation (ADR-0027 D8): the recipient's account status without
// the cache. The directory reports a non-ACTIVE or missing user as absent.
func (s *service) freshRecipient(ctx context.Context, peerUID string) error {
	s.d.Profiles.Forget(peerUID)
	got, err := s.d.Profiles.GetProfiles(ctx, []string{peerUID})
	if err != nil {
		return fmt.Errorf("messaging: recipient status: %w", err)
	}
	if _, ok := got[peerUID]; !ok {
		return errRecipientInactive
	}
	return nil
}

func (s *service) isNewAccount(p identity.Profile, now time.Time) bool {
	return !p.CreatedAt.IsZero() && now.Sub(p.CreatedAt) < s.d.Limits.NewAccountWindow
}

// newAccountCap applies the new-account tier (MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY) of the SendMessage call cap. It is
// counted per instance like the interceptor's cap, which still counts the call too.
func (s *service) newAccountCap(ctx context.Context, uid string, caller identity.Profile, now time.Time) error {
	if s.newSends == nil || !s.isNewAccount(caller, now) || s.newSends.Allow(uid) {
		return nil
	}
	noteLimit(ctx, limitMessagesDaily)
	return apierr.New(connect.CodeResourceExhausted, commonv1.ErrorReason_ERROR_REASON_RATE_LIMITED, "too many requests, please slow down").
		WithMeta("limit", limitMessagesDaily).WithRetryAfter(quota.UntilNextDay(now))
}

// noteLimit records which cap refused the request: RequestInfo.LimitName is the field the Logging interceptor emits as
// limit_name for every limiter, so abuse-spike queries find these next to the interceptor's own.
func noteLimit(ctx context.Context, name string) {
	if info := logger.RequestInfoFromContext(ctx); info != nil {
		info.LimitName = name
	}
}

// refuse records the fixed-enum reason on the request line and returns the one CANNOT_MESSAGE answer.
func (s *service) refuse(ctx context.Context, reason string) error {
	logger.SetRequestField(ctx, fieldRefused, reason)
	return cannotMessage()
}

// mapErr turns a repo or lookup error into the wire answer. The raw uids and ids are redacted from anything that
// reaches an ERROR log: a Firestore error embeds document paths, and a path names a uid and a conversation.
func (s *service) mapErr(ctx context.Context, uid string, in sendInput, err error) error {
	var ae *apierr.Error
	switch {
	case errors.As(err, &ae):
		return err
	case errors.Is(err, ErrNotFound):
		return notFound()
	case errors.Is(err, errRecipientInactive):
		return s.refuse(ctx, refusedRecipientOff)
	case errors.Is(err, ErrCannotMessage):
		return s.refuse(ctx, refusedGone) // the peer deleted the account
	case errors.Is(err, ErrRequestLimit):
		noteLimit(ctx, limitRequestUnanswered)
		return limitReached(limitRequestUnanswered)
	case errors.Is(err, ErrDMNewDaily):
		noteLimit(ctx, limitDMNewDaily)
		return limitReached(limitDMNewDaily)
	case errors.Is(err, ErrKeyReused):
		return keyReused()
	case ctxFailure(ctx) != nil:
		return ctxFailure(ctx)
	case errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		s.d.Log.WarnContext(ctx, "messaging_send_contention", slog.String("uid_hash", logger.HashUID(uid)), slog.String(fieldConvHash, logger.HashUID(in.convID)))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "busy, please retry").WithRetryAfter(time.Second)
	}
	return logger.RedactErr(fmt.Errorf("messaging: send: %w", err), uid, in.peer, in.convID, MessageID(uid, in.key))
}

// ctxFailure is the wire answer for a request whose own context ended (canceled or past its deadline), else nil.
func ctxFailure(ctx context.Context) *apierr.Error {
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	}
	return nil
}

func peerDocOf(p identity.Profile) PeerDoc {
	thumb := p.AvatarThumbURL
	if thumb == "" {
		thumb = p.AvatarURL
	}
	return PeerDoc{Handle: p.Handle, DisplayName: p.DisplayName, AvatarThumbURL: thumb, Verified: p.Verified}
}

// sendResponse builds the SendMessage answer from the committed (or replayed) message. The conversation is the sender's
// own view: INBOX (a requester sees the conversation in the Inbox), nothing unread, and read-write. A replay of a message a
// moderator took down (state REMOVED, text cleared) answers that tombstone, never an empty VISIBLE message.
func sendResponse(convID, msgID string, peer identity.Profile, res SendResult, callerSilent bool) *messagingv1.SendMessageResponse {
	created := timestamppb.New(res.Msg.CreatedAt)
	msgState, text, snippet := messagingv1.MessageState_MESSAGE_STATE_VISIBLE, res.Msg.Text, snippetOf(res.Msg.Text)
	if res.Msg.State == msgRemoved {
		msgState, text, snippet = messagingv1.MessageState_MESSAGE_STATE_REMOVED, "", ""
	}
	state := messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED
	if res.Conv.State == stateRequest {
		state = messagingv1.ConversationState_CONVERSATION_STATE_REQUEST
	}
	pd := peerDocOf(peer)
	return &messagingv1.SendMessageResponse{
		Message: &messagingv1.Message{
			Id: msgID, ConversationId: convID, FromSelf: true, Text: text,
			State: msgState, CreatedAt: created,
		},
		Conversation: &messagingv1.Conversation{
			Id: convID, Kind: messagingv1.ConversationKind_CONVERSATION_KIND_DIRECT,
			Peer: &commonv1.AuthorSnapshot{
				UserId: peer.UserID, Handle: pd.Handle, DisplayName: pd.DisplayName, AvatarUrl: pd.AvatarThumbURL, Verified: pd.Verified,
			},
			State: state, Folder: messagingv1.Folder_FOLDER_INBOX,
			LastMessage: &messagingv1.MessagePreview{
				Snippet: snippet, FromSelf: true, State: msgState, CreatedAt: created,
			},
			CanReply: true, Silent: callerSilent, UpdatedAt: created,
		},
	}
}
