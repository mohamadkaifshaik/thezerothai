package messaging

import (
	"context"
	"errors"
	"fmt"
	"time"

	"golang.org/x/sync/errgroup"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-line fields of ListMessages and MarkConversationRead (ADR-0027 D11, plan W7-8). Counts and booleans only: never
// message text, a uid or a conversation id in clear (conversation_hash is the one-way hash).
const (
	kindListMessages = "list_messages"
	kindPoll         = "poll"
	kindMarkRead     = "mark_read"
	fieldPoll        = "poll"
	fieldSinceRetire = "since_retired"
	fieldCacheHit    = "cache_hit"
	fieldEntryFound  = "entry_found"
)

// Token bindings: a message token opens only for the uid, the conversation and the token kind it was issued for.
func messagesSinceBinding(uid, convID string) string {
	return "messaging|messages|since|" + uid + "|" + convID
}
func messagesPageBinding(uid, convID string) string {
	return "messaging|messages|page|" + uid + "|" + convID
}

// ListMessages implements Service.ListMessages (ADR-0027 D4 "On read", D7, D11; plan W7-8).
//
// Flag: not globally off. Validation before any read: conversation_id is 32 lower-case hex (VALIDATION
// "conversation_id"), page_token and since_token not both, then the token itself (sealed, bound to the uid, the
// conversation and the token kind, 30 days; a foreign, tampered or expired token is VALIDATION, 0 reads).
//
// Participant check: the conversation document (instance cache 60 s, so a clearedAt set on another instance is seen
// within 60 s). A missing document and a non-participant answer one byte-identical NOT_FOUND after at most 2 reads.
//
// Messages come newest first, `createdAt DESC, __name__ DESC`, without those at or before clearedAt[caller]. A tombstone
// keeps its state and an empty text; from_self is the only sender information on the wire. A `since` refresh trails the
// newest returned message by SettleWindow (the client dedupes by id); when its page is full the response carries
// gap_page_token (Window{Upper: oldest returned, Lower: old since}) and the client pages it. Tokens come from the rows
// scanned.
//
// Conversation is set on a first or older page (peer from the identity directory, cache-first 60 s; can_reply from the
// caller graph, cached 60 s) and unset on a since refresh, a gap fill included, which reads neither. An erased peer
// (DeletedUID) is "Deleted account", never looked up, and can_reply is false.
//
// Worst-case Firestore cost (budget.Counter; the account-status interceptor read counted as the proto comment does):
//   - first or older page of 20 / 50: 24 / 54 reads cold (interceptor 1, conversation 1, query page, peer users 1, caller
//     graph 1), planning 15; warm caches: 1 + page
//   - since poll: 3 cold (interceptor, conversation, query min 1) + 1 per new message returned, planning 1.2
//   - NOT_FOUND: at most 2 reads; writes 0
func (s *service) ListMessages(ctx context.Context, uid string, req *messagingv1.ListMessagesRequest) (*messagingv1.ListMessagesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	in, err := s.validateMessages(uid, req)
	if err != nil {
		logger.SetRequestField(ctx, fieldKind, kindListMessages)
		return nil, err
	}
	kind := kindListMessages
	if in.since != nil {
		kind = kindPoll
	}
	logger.SetRequestField(ctx, fieldKind, kind)
	logger.SetRequestField(ctx, fieldPoll, in.since != nil)
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(in.convID))
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil || len(s.d.CursorKey) == 0 {
		return nil, errors.New("messaging: list messages is not configured")
	}
	return s.listMessages(ctx, uid, in)
}

// messagesInput is a validated ListMessages request.
type messagesInput struct {
	convID string
	limit  int
	// since is a refresh position; before and after bound a page (window tokens: after is a gap fill's lower bound).
	since, before, after *cursor.Cursor
	// sinceRev is the thread revision sealed in the since token (0 for a token issued before revisions existed).
	sinceRev int64
	// paged: a page token was sent (an older page or a gap fill).
	paged bool
	// gapFill: the page token carried a lower bound, so this page is a refresh gap and carries no conversation.
	gapFill bool
}

func (s *service) validateMessages(uid string, req *messagingv1.ListMessagesRequest) (messagesInput, error) {
	in := messagesInput{convID: req.GetConversationId()}
	if !ValidID(in.convID) {
		return in, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	if req.GetPageToken() != "" && req.GetSinceToken() != "" {
		return in, apierr.Validation("page_token", "send either page_token or since_token, not both")
	}
	in.limit = clampPageSize(req.GetPageSize())
	now := s.d.Now()
	switch {
	case req.GetSinceToken() != "":
		// Decoded before any read: a foreign or tampered token costs nothing. The revision it carries is compared with the
		// conversation's after the participant check (listMessages).
		c, rev, err := cursor.DecodeRevAtTTL(s.d.CursorKey, messagesSinceBinding(uid, in.convID), req.GetSinceToken(), now, s.tokenTTL())
		if err != nil {
			return in, apierr.Validation("since_token", "invalid or expired since_token")
		}
		in.since, in.after, in.sinceRev = &c, &c, rev
	case req.GetPageToken() != "":
		w, err := cursor.DecodeWindowAt(s.d.CursorKey, messagesPageBinding(uid, in.convID), req.GetPageToken(), now, s.tokenTTL())
		if err != nil || w.IsZero() {
			return in, apierr.Validation("page_token", "invalid or expired page_token")
		}
		up := w.Upper
		in.before, in.after, in.paged, in.gapFill = &up, w.Lower, true, w.Lower != nil
	}
	return in, nil
}

func (s *service) listMessages(ctx context.Context, uid string, in messagesInput) (*messagingv1.ListMessagesResponse, error) {
	conv, hit, err := s.conversationHit(ctx, in.convID)
	logger.SetRequestField(ctx, fieldCacheHit, hit)
	if err == nil && !conv.hasParticipant(uid) {
		err = ErrNotFound
	}
	if err != nil {
		return nil, s.messagesErr(ctx, uid, in.convID, err)
	}
	peer := peerOf(conv.Participants, uid)

	// The thread revision (ADR-0027 note 2026-10-29). A since token issued before the conversation changed under a cached
	// device (a takedown, an erasure) carries a lower revision: it is retired with the very answer of an expired token, so
	// the client makes the one cold open the token contract already prescribes. A higher revision means this instance's
	// 60 s copy is the stale one: accept the token, drop the copy and seal the higher revision (no read). Checked after the
	// participant check, so a non-participant never learns anything from it.
	rev := conv.Rev
	if in.since != nil {
		switch {
		case in.sinceRev < conv.Rev:
			logger.SetRequestField(ctx, fieldSinceRetire, true)
			return nil, apierr.Validation("since_token", "invalid or expired since_token")
		case in.sinceRev > conv.Rev:
			s.convs.Delete(in.convID)
			rev = in.sinceRev
		}
	}

	// The conversation block is for a first page and an older page; a since refresh and a gap fill read neither the peer
	// profile nor the graph.
	withConv := in.since == nil && !in.gapFill
	var (
		rows []MessageRow
		prof identity.Profile
		live bool
		snap graph.Snapshot
	)
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(3)
	g.Go(func() (err error) {
		rows, err = s.d.Repo.ListMessages(gctx, in.convID, MessageQuery{Limit: in.limit, Before: in.before, After: in.after, ClearedAt: conv.ClearedAt[uid]})
		return err
	})
	if withConv && peer != DeletedUID {
		g.Go(func() error {
			got, err := s.d.Profiles.GetProfiles(gctx, []string{peer})
			prof, live = got[peer], err == nil && got[peer].UserID != ""
			if err != nil {
				return fmt.Errorf("messaging: peer profile: %w", err)
			}
			return nil
		})
		g.Go(func() (err error) {
			snap, err = s.d.Social.Snapshot(gctx, uid)
			if err != nil {
				return fmt.Errorf("messaging: caller graph: %w", err)
			}
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, s.messagesErr(ctx, uid, in.convID, err)
	}

	msgs := make([]*messagingv1.Message, 0, len(rows))
	for _, r := range rows {
		msgs = append(msgs, messageOf(r, in.convID, uid))
	}
	logger.SetRequestField(ctx, fieldResults, len(msgs))

	now := s.d.Now()
	resp := &messagingv1.ListMessagesResponse{Messages: msgs}
	full := len(rows) == in.limit
	oldest := cursor.Cursor{}
	if len(rows) > 0 {
		last := rows[len(rows)-1]
		oldest = cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}
	}
	switch {
	case in.since != nil: // refresh: a full page leaves a gap below it
		if full {
			resp.GapPageToken = cursor.EncodeWindowAt(s.d.CursorKey, messagesPageBinding(uid, in.convID), cursor.Window{Upper: oldest, Lower: in.since}, now)
		}
		resp.SinceToken = s.messagesSinceToken(uid, in, rows, rev, now)
	case in.paged: // an older page, or a gap fill that keeps its lower bound
		if full {
			resp.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, messagesPageBinding(uid, in.convID), cursor.Window{Upper: oldest, Lower: in.after}, now)
		}
	default: // first page
		if full {
			resp.NextPageToken = cursor.EncodeWindowAt(s.d.CursorKey, messagesPageBinding(uid, in.convID), cursor.Window{Upper: oldest}, now)
		}
		resp.SinceToken = s.messagesSinceToken(uid, in, rows, rev, now)
	}
	if withConv {
		resp.Conversation = threadConversation(in.convID, conv, uid, peer, prof, live, snap)
	}
	return resp, nil
}

// messagesSinceToken is the token for the next poll (the position of sealSince over the newest scanned message, plus the
// thread revision rev: the larger of the token's and the conversation's, so a stale instance never moves it backwards).
func (s *service) messagesSinceToken(uid string, in messagesInput, rows []MessageRow, rev int64, now time.Time) string {
	var newest *cursor.Cursor
	if len(rows) > 0 {
		newest = &cursor.Cursor{CreatedAt: rows[0].CreatedAt, DocID: rows[0].ID}
	}
	return cursor.EncodeRevAt(s.d.CursorKey, messagesSinceBinding(uid, in.convID), sinceCursor(newest, in.since, now), max(rev, in.sinceRev), now)
}

// messageOf maps a stored message to the wire Message. There is no sender uid: from_self is the only sender signal (an
// erased sender's senderId is DeletedUID, so it is never "self"). A tombstone keeps its state with an empty text.
func messageOf(r MessageRow, convID, uid string) *messagingv1.Message {
	m := &messagingv1.Message{Id: r.ID, ConversationId: convID, FromSelf: r.SenderID == uid, CreatedAt: timestamppb.New(r.CreatedAt)}
	switch r.State {
	case msgVisible:
		m.State, m.Text = messagingv1.MessageState_MESSAGE_STATE_VISIBLE, r.Text
	case msgDeletedAccount:
		m.State = messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT
	case msgRemoved:
		m.State = messagingv1.MessageState_MESSAGE_STATE_REMOVED
	}
	return m
}

// threadConversation is Conversation as ListMessages carries it: identity, peer, state, folder and can_reply. The counters
// and the preview live on the caller's entry, which this RPC does not read (ListConversations owns them). The folder is
// the caller's entry's: the recipient of an unaccepted request sees it in REQUESTS, everyone else in INBOX. An erased
// peer, or one the directory no longer lists as ACTIVE, reads "Deleted account" and the thread is read-only.
func threadConversation(convID string, conv ConvDoc, uid, peer string, prof identity.Profile, live bool, snap graph.Snapshot) *messagingv1.Conversation {
	c := &messagingv1.Conversation{
		Id: convID, Kind: messagingv1.ConversationKind_CONVERSATION_KIND_DIRECT,
		State: messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED, Folder: messagingv1.Folder_FOLDER_INBOX,
	}
	if conv.State == stateRequest {
		c.State = messagingv1.ConversationState_CONVERSATION_STATE_REQUEST
		if conv.RequestTo == uid {
			c.Folder = messagingv1.Folder_FOLDER_REQUESTS
		}
	}
	if peer == DeletedUID || !live {
		c.Peer = &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
		return c
	}
	pd := peerDocOf(prof)
	c.Peer = &commonv1.AuthorSnapshot{UserId: peer, Handle: pd.Handle, DisplayName: pd.DisplayName, AvatarUrl: pd.AvatarThumbURL, Verified: pd.Verified}
	c.CanReply = canReply(peer, snap)
	return c
}

// messagesErr turns a repo, directory or graph error into the wire answer through the shared tail (failure): ErrNotFound is
// the one NOT_FOUND of an unknown id and a non-participant (D11), and ids are redacted from anything that reaches a log.
func (s *service) messagesErr(ctx context.Context, uid, convID string, err error) error {
	return s.failure(ctx, "list_messages", uid, convID, err)
}

// MarkRead implements Service.MarkRead (ADR-0027 D4, D10; plan W7-8).
//
// Flag: not globally off. idempotency_key (16-64 of [A-Za-z0-9_-]) and conversation_id (32 lower-case hex) are VALIDATION with 0
// reads; the key is format-validated but not stored (founder decision 2026-10-29, option (a): ADR-0021's rule for a key the
// RPC does not use). The RPC is idempotent by state, and the accepted risk is that a late retry sets unreadCount to 0 over
// a newer message (the badge and the Inbox miss it until the next message or open). The write is a field-level
// Update of the caller's own dmInbox entry, else dmRequests, with an Exists precondition: the path comes from the token
// uid, so a non-participant or an unknown or deleted conversation simply has no entry and the answer is success with 0
// writes, the same as a conversation that is already read. After a write the badge cache of this instance is evicted
// (Deps.Badge, W7-11; nil until then). The read time is never shown to the peer.
//
// Worst-case Firestore cost: reads 0 here (1 for the interceptor, planning 0.3); writes 1, 0 when the entry is missing.
// Under DEGRADED_MODE=readonly the interceptor refuses before this runs.
func (s *service) MarkRead(ctx context.Context, uid string, req *messagingv1.MarkConversationReadRequest) (*messagingv1.MarkConversationReadResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindMarkRead)
	id := req.GetConversationId()
	if err := validateKeyAndConv(req.GetIdempotencyKey(), id); err != nil {
		return nil, err
	}
	if s.d.Repo == nil {
		return nil, errors.New("messaging: mark read is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashUID(id))
	found, err := s.d.Repo.MarkRead(ctx, uid, id, s.d.Now())
	if err != nil {
		if ce := ctxFailure(ctx); ce != nil {
			return nil, ce
		}
		return nil, logger.RedactErr(fmt.Errorf("messaging: mark read: %w", err), uid, id)
	}
	logger.SetRequestField(ctx, fieldEntryFound, found)
	if found && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.MarkConversationReadResponse{}, nil
}
