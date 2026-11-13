package messaging

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/mw"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line fields of a send. Never the text, a snippet, a peer uid or a conversation id in clear.
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
	refusedDMPolicy         = "dm_policy"
)

// Send implements Service.Send.
//
// Flag: per caller (FEATURE_DISABLED before any read) and per recipient (CANNOT_MESSAGE, the same bytes as a block).
// Validation (key, target, text) and the self check run before any read. The per-minute bucket and the MESSAGES_SENDS_PER_DAY
// cap run in the rate-limit interceptor; the new-account tier of that cap runs here.
func (s *service) Send(ctx context.Context, uid string, req *messagingv1.SendMessageRequest) (*messagingv1.SendMessageResponse, error) {
	if err := s.guard(ctx, uid, perCaller); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindSend)
	// Defence in depth behind authn.VerifiedIdentityInterceptor (security review L-8): no read, after the flag, before validation.
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "sending messages"); err != nil {
		return nil, err
	}
	in, err := validateSend(uid, req)
	if err != nil {
		return nil, err
	}
	// A shared post: its flags and its id shape run after the existing checks and before any lookup.
	if in.sharedRaw != "" {
		logger.SetRequestField(ctx, fieldSharedPost, true)
		if err := s.guardPostShare(ctx, uid, in.sharedRaw); err != nil {
			return nil, err
		}
	}
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil || s.d.TxSocial == nil || s.d.TxProfiles == nil {
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
	// sharedRaw is shared_post_id as sent ("" for none; bound into the request digest); shared is the post it resolved to
	// (the original), set once the visibility check passed.
	sharedRaw string
	shared    SharedPost
}

// validateSend is step 1: the key, the target and the text, before any read.
func validateSend(uid string, req *messagingv1.SendMessageRequest) (sendInput, error) {
	var in sendInput
	if !idempotency.KeyFormatValid(req.GetIdempotencyKey()) {
		return in, invalidKey()
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
	in.sharedRaw = req.GetSharedPostId()
	return in, nil
}

func (s *service) send(ctx context.Context, uid string, in sendInput) (*messagingv1.SendMessageResponse, error) {
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(in.convID))
	// Step 2: a conversation_id resolves to its peer through the participant check (cached 60 s).
	if in.byConvID {
		conv, err := s.conversation(ctx, uid, in.convID)
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

	// Step 3: the caller's graph snapshot (60 s cache; the recipient's graph is read inside the transaction) and
	// both profiles (the caller's is warm behind the account-status interceptor, the recipient's is the one directory read).
	mine, err := s.d.Social.Snapshot(ctx, uid)
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, fmt.Errorf("messaging: caller graph: %w", err))
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

	// Next, the recipient checks: every refusal is the one CANNOT_MESSAGE. The caller's own Blocked set is read here; the recipient's
	// is read inside the transaction (it has no overflow case), ahead of every cap.
	peer, active := profiles[in.peer]
	switch {
	case mine.Blocked[in.peer]:
		return nil, s.refuse(ctx, refusedBlocked)
	case !active:
		return nil, s.refuse(ctx, refusedRecipientOff)
	case s.flags == nil || !s.flags.Enabled(in.peer, FlagName):
		return nil, s.refuse(ctx, refusedRecipientFlagOff)
	}
	// A shared post: the GetPost rules and the protected-author rule, after the recipient checks and before the
	// transaction (NOT_FOUND "post not found" or PROTECTED_ACCOUNT, writing nothing).
	if in.sharedRaw != "" {
		sp, err := s.checkPostShare(ctx, uid, in.sharedRaw)
		if err != nil {
			return nil, s.mapErr(ctx, uid, in, err)
		}
		in.shared = sp
	}
	limit := s.d.Limits.DMNewPerDay
	if s.isNewAccount(caller, now) {
		limit = s.d.Limits.NewAccountDMNewPerDay
	}
	res, err := s.d.Repo.Send(ctx, SendParams{
		UID: uid, PeerUID: in.peer, ConvID: in.convID, MsgID: MessageID(uid, in.key),
		Text: in.text, RequestHash: requestHash(in.convID, in.text, in.sharedRaw), Now: now, SharedPostID: in.shared.ID,
		CallerFollowsPeer: mine.Following[in.peer], CallerSilent: mine.Muted[in.peer],
		RecipientFollowingOnly: peer.DMPolicy == identity.DMPolicyFollowingOnly && s.flags.Enabled(in.peer, identity.DMPolicyFlag),
		Caller:                 peerDocOf(caller), Peer: peerDocOf(peer),
		MaxUnanswered: s.d.Limits.RequestMaxUnanswered, DMNewLimit: limit,
		RecipientGraphInTx: func(ctx context.Context, tx *firestore.Transaction) (graph.Snapshot, error) {
			return s.d.TxSocial.SnapshotInTx(ctx, tx, in.peer)
		},
		RecipientInTx: func(ctx context.Context, tx *firestore.Transaction) (identity.Profile, error) {
			return s.d.TxProfiles.ProfileInTx(ctx, tx, in.peer)
		},
	})
	if err != nil {
		return nil, s.mapErr(ctx, uid, in, err)
	}
	s.afterSend(ctx, uid, in, res)
	out := sendResponse(in.convID, MessageID(uid, in.key), peer, res, mine.Muted[in.peer])
	// The sender's own card, decided like any page of ListMessages (cache-first: the check above just read the post).
	if cards := s.sharedCards(ctx, uid, []MessageRow{{ID: out.Message.Id, MsgDoc: res.Msg}}); cards != nil {
		out.Message.SharedPost = cards[res.Msg.SharedPostID]
	}
	return out, nil
}

// afterSend is steps 6 and 7 and the request line: the instance cache is updated from the written data, the badge
// cache of both participants is evicted, and the push event leaves only for an accepted, non-silent, non-replayed
// message (a request never pushes, F7). silent is the transaction's own read of the recipient's Muted set, never a
// value computed before it, so a mute made 59 s ago on another instance no longer pushes.
func (s *service) afterSend(ctx context.Context, uid string, in sendInput, res SendResult) {
	logger.SetRequestField(ctx, fieldReplay, res.Replay)
	logger.SetRequestField(ctx, fieldSilent, res.Silent)
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
		s.putConv(in.convID, res.Conv)
	}
	if s.d.Badge != nil {
		s.d.Badge.Forget(uid, in.peer)
	}
	if s.d.Events != nil && !res.RecipientInRequests && !res.Silent {
		s.d.Events.MessageSent(ctx, MessageEvent{ActorUID: uid, RecipientUID: in.peer, ConversationID: in.convID, At: res.Msg.CreatedAt})
	}
	// Committed and not a replay: the share is recorded for Post.share_count, best effort.
	s.recordShare(ctx, uid, in.shared)
}

// conversation is the participant check's read for uid: the instance cache first (convCacheTTL) when uid is a participant of
// the cached copy, else a fresh read. A missing document is NOT_FOUND, the same answer as a non-participant (D11).
func (s *service) conversation(ctx context.Context, uid, id string) (ConvDoc, error) {
	c, _, err := s.conversationHit(ctx, uid, id)
	return c, err
}

// conversationHit is conversation that also says whether the instance cache answered (the cache_hit log field).
//
// The cache is per instance and shared by every caller, and conversation ids are a public function of two public uids, so
// it must not tell a non-participant anything (security review, H-1: a probe that warms the cache and times a second
// probe is an existence oracle for "does A talk to B"). Hence: a cached copy answers only a caller who is in its
// participants; every other caller (a non-participant against a warm copy, or any miss) pays one fresh GetConversation,
// found or not, and a document read for a non-participant is never put into the cache. A non-participant probe therefore
// always does one fresh repo read and leaves no trace; a participant's path is unchanged (cache first, then a read). The
// returned document may belong to a conversation uid is not in: the caller's hasParticipant check turns it into NOT_FOUND.
func (s *service) conversationHit(ctx context.Context, uid, id string) (ConvDoc, bool, error) {
	if c, ok := s.convs.Get(id); ok && c.hasParticipant(uid) {
		return c, true, nil
	}
	c, found, err := s.d.Repo.GetConversation(ctx, id)
	if err != nil {
		return ConvDoc{}, false, err
	}
	if !found {
		return ConvDoc{}, false, ErrNotFound
	}
	if c.hasParticipant(uid) {
		s.putConv(id, c)
	}
	return c, false, nil
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

// mapErr turns a repo or lookup error into the wire answer: the send-specific sentinels first, then the shared tail
// (failure). The raw uids and ids are redacted from anything that reaches an ERROR log.
func (s *service) mapErr(ctx context.Context, uid string, in sendInput, err error) error {
	switch {
	case errors.Is(err, errRecipientInactive):
		return s.refuse(ctx, refusedRecipientOff)
	case errors.Is(err, errBlocked):
		return s.refuse(ctx, refusedBlocked)
	case errors.Is(err, errDMPolicy):
		return s.refuse(ctx, refusedDMPolicy)
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
	}
	return s.failure(ctx, "send", uid, in.convID, err, in.peer, MessageID(uid, in.key))
}

// isTxOp reports the ops of failure that run a Firestore transaction (the ops whose busy answer is safe to retry: they carry an
// idempotency key or are idempotent by state). Any other op, ListMessages above all, is a read path.
func isTxOp(op string) bool { return op == "send" || op == "accept" || op == "delete" }

// failure is the tail every RPC's error mapper shares (mapErr, messagesErr, lifecycleErr), reached after the mapper's own
// sentinels. In this order: an *apierr.Error is already a wire answer; ErrNotFound is the one byte-identical NOT_FOUND of an
// unknown id, a non-participant and a deleted conversation (D11); a request whose own context ended; for a transactional
// op only (send, accept, delete) a lost or timed-out transaction is UNAVAILABLE "busy, please retry" (retry after
// 1 s) with a WARN messaging_<op>_contention line; anything else, including a timeout on a read path (list_messages), is
// INTERNAL with uid, convID and every id in redact replaced by hashes, because a Firestore error embeds document paths and
// a path names a uid and a conversation. A read-path timeout stays INTERNAL on purpose: it is not contention, Error
// Reporting must see it, and the client's RetryInterceptor retries a read-only RPC on UNAVAILABLE, which would multiply
// the polls against an already degraded Firestore.
//
// "busy" means "outcome unknown, retry with the same idempotency key", not "nothing was written". A lost transaction
// (ErrContended, Aborted) wrote nothing, but a DeadlineExceeded may come from a commit that was already applied; the retry
// replays it (send: deterministic message id; accept and delete: idempotent by state). A replay pushes nothing, so the
// recipient's FCM push for a message whose sender saw busy is not sent; the recipient's next poll shows it.
func (s *service) failure(ctx context.Context, op, uid, convID string, err error, redact ...string) error {
	var ae *apierr.Error
	switch {
	case errors.As(err, &ae):
		return err
	case errors.Is(err, ErrNotFound):
		return notFound()
	case ctxFailure(ctx) != nil:
		return ctxFailure(ctx)
	case isTxOp(op) && (errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded):
		s.d.Log.WarnContext(ctx, "messaging_"+op+"_contention", slog.String("uid_hash", logger.HashUID(uid)), slog.String(fieldConvHash, logger.HashConversation(convID)))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "busy, please retry").WithRetryAfter(time.Second)
	}
	return redactErr(fmt.Errorf("messaging: %s: %w", op, err), append([]string{uid, convID}, redact...)...)
}

// recovered is mw.RecoverGo for the read fan-outs of this package.
func (s *service) recovered(ctx context.Context, fn func() error) func() error {
	return mw.RecoverGo(ctx, s.d.Log, "messaging/read_worker", fn)
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
				SharedPost: msgState == messagingv1.MessageState_MESSAGE_STATE_VISIBLE && res.Msg.SharedPostID != "",
			},
			CanReply: true, Silent: callerSilent, UpdatedAt: created,
		},
	}
}

// putConv stores a conversation read or written by a transaction in the instance cache, unless the cached copy has a later
// updatedAt: a handler that finishes late (a concurrent ListMessages that read before a DeleteConversation committed, or a
// Delete whose copy an Accept has already superseded) must not put an older document back over a newer one. The
// check-then-set is not atomic; the 60 s TTL bounds what a lost race can show (D14).
func (s *service) putConv(id string, c ConvDoc) {
	// With equal updatedAt (a coarse clock, an erasure racing a late reader) the higher revision wins; the revision only breaks
	// ties, so a newer document with a lower revision still replaces.
	if old, ok := s.convs.Get(id); ok && (old.UpdatedAt.After(c.UpdatedAt) || (old.UpdatedAt.Equal(c.UpdatedAt) && old.Rev > c.Rev)) {
		return
	}
	s.convs.Set(id, c)
}
