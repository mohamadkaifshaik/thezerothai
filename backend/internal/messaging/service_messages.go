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

// Request-line fields of ListMessages and MarkConversationRead. Counts and booleans only: never
// message text, a uid or a conversation id in clear (conversation_hash is the one-way hash).
const (
	kindListMessages = "list_messages"
	kindPoll         = "poll"
	kindMarkRead     = "mark_read"
	fieldPoll        = "poll"
	fieldSinceRetire = "since_retired"
	fieldCacheHit    = "cache_hit"
	fieldEntryFound  = "entry_found"
	fieldReceipt     = "read_receipt"
)

// Token bindings: a message token opens only for the uid, the conversation and the token kind it was issued for.
func messagesSinceBinding(uid, convID string) string {
	return "messaging|messages|since|" + uid + "|" + convID
}
func messagesPageBinding(uid, convID string) string {
	return "messaging|messages|page|" + uid + "|" + convID
}

// ListMessages implements Service.ListMessages ("On read", D7, D11).
//
// Flag: not globally off. Validation before any read: conversation_id is 32 lower-case hex (VALIDATION
// "conversation_id"), page_token and since_token not both, then the token itself (sealed, bound to the uid, the
// conversation and the token kind, 30 days; a foreign, tampered or expired token is VALIDATION, before any read).
//
// Participant check: the conversation document (instance cache 60 s for a participant, so a clearedAt set on another instance is seen
// within 60 s; a non-participant never reads from or writes to it). A missing document and a non-participant answer one
// byte-identical NOT_FOUND, warm or cold.
//
// Thread revision: a since token carries the conversation's `rev` as its issuer saw it. After the
// participant check, a token with a lower rev (a takedown or an erasure changed the thread) is VALIDATION since_token with
// the bytes of an expired token, with no query beyond the conversation read; a higher rev means this instance's
// 60 s copy is stale, so the copy is dropped (no read) and the higher rev is sealed again. A foreign or tampered token is
// still refused before any read.
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
// First page only: one more read, the caller's own entry (users/{uid}/dmInbox/{id}, or dmRequests when entryFolder
// says the caller is the recipient of an unaccepted request). The folder comes from the 60 s conversation copy, so an accept
// on another instance is seen within 60 s, and a stale answer is only a missing entry. The entry fills
// Conversation.unread_count and silent; a missing entry (delete-for-me, never created) is 0 / false. It runs after the
// participant check, so NOT_FOUND is unchanged. A since refresh and an older page never read it.
//
// Blocked peer (security review M-2): when the caller's graph says the peer blocked them (BlockedBy, or
// BlockedByOverflow, where the list cannot be trusted), the live directory profile is dropped from the answer and the peer is
// the frozen snapshot on the caller's own entry, what they already saw at the last message. Order: an erased peer
// (DeletedUID) is the placeholder; else a block decides, whatever the directory says (so the blocked caller cannot tell whether
// the blocker is ACTIVE, suspended or being deleted); else a peer the directory does not list is the placeholder. The frozen
// snapshot is used only when the entry exists and names this peer (an eraser rewriting the entry's peerId to DeletedUID is the
// placeholder); an older page reads no entry, so it answers the placeholder, never the live handle or avatar. The directory
// lookup runs in parallel with the graph read (no serial wait on the graph) and supplies liveness for the unblocked case.
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
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(in.convID))
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
	conv, hit, err := s.conversationHit(ctx, uid, in.convID)
	logger.SetRequestField(ctx, fieldCacheHit, hit)
	// peerOf is "" for a non-participant and for a document whose participants are not a pair: both read as an unknown id.
	var peer string
	if err == nil {
		if peer = peerOf(conv.Participants, uid); peer == "" {
			err = ErrNotFound
		}
	}
	if err != nil {
		return nil, s.messagesErr(ctx, uid, in.convID, err)
	}

	// The thread revision. A since token issued before the conversation changed under a cached
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
	// The caller's own entry (unread_count, silent, the frozen peer): the first page only, after the participant check.
	first := in.since == nil && !in.paged
	var (
		rows  []MessageRow
		prof  identity.Profile
		live  bool
		snap  graph.Snapshot
		entry EntryDoc
		found bool
		// callerReceipts is the caller's own read-receipts setting, loaded only on a first page with the flag on for both.
		callerReceipts bool
	)
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(4)
	if first {
		g.Go(s.recovered(ctx, func() (err error) {
			entry, found, err = s.d.Repo.GetEntry(gctx, uid, in.convID, entryFolder(conv, uid))
			return err
		}))
	}
	g.Go(s.recovered(ctx, func() (err error) {
		rows, err = s.d.Repo.ListMessages(gctx, in.convID, MessageQuery{Limit: in.limit, Before: in.before, After: in.after, ClearedAt: conv.ClearedAt[uid]})
		return err
	}))
	// F3: the caller's own setting rides on the peer profile lookup (one batched, cache-first call) of a first page, only
	// when the flag is on for both sides; the rest of the receipt rule runs after the page is read.
	wantReceipt := first && s.flags != nil && s.flags.Enabled(uid, identity.ReadReceiptsFlag) && s.flags.Enabled(peer, identity.ReadReceiptsFlag)
	if withConv && peer != DeletedUID {
		g.Go(s.recovered(ctx, func() error {
			lookup := []string{peer}
			if wantReceipt {
				lookup = append(lookup, uid)
			}
			got, err := s.d.Profiles.GetProfiles(gctx, lookup)
			prof, live = got[peer], err == nil && got[peer].UserID != ""
			callerReceipts = wantReceipt && err == nil && got[uid].ReadReceipts
			if err != nil {
				return fmt.Errorf("messaging: peer profile: %w", err)
			}
			return nil
		}))
		g.Go(s.recovered(ctx, func() (err error) {
			snap, err = s.d.Social.Snapshot(gctx, uid)
			if err != nil {
				return fmt.Errorf("messaging: caller graph: %w", err)
			}
			return nil
		}))
	}
	if err := g.Wait(); err != nil {
		return nil, s.messagesErr(ctx, uid, in.convID, err, peer)
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
	if first {
		logger.SetRequestField(ctx, fieldEntryFound, found)
	}
	if withConv {
		// The peer blocked the caller (or the list cannot say): never the live profile, only the frozen snapshot of the
		// caller's own entry (nil on an older page or when the entry is gone). Liveness and the block stay separate facts.
		blocked := peerBlockedCaller(snap, peer)
		var own *EntryDoc
		if found {
			own = &entry
		}
		resp.Conversation = threadConversation(in.convID, conv, uid, peer, prof, live, blocked, snap, own)
		if first {
			resp.Conversation.UnreadCount, resp.Conversation.Silent = entry.UnreadCount, entry.Silent
			if live && peer != DeletedUID {
				resp.Conversation.PeerReadAt = s.peerReadAt(ctx, conv, in.convID, peer, callerReceipts, prof.ReadReceipts, snap)
			}
		}
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
// and the preview live on the caller's entry; the caller fills unread_count and silent from it on a first page, and
// ListConversations owns the rest. The folder is the caller's entry's: the recipient of an unaccepted request sees it in
// REQUESTS, everyone else in INBOX. An erased peer, or one the directory no longer lists as ACTIVE, reads "Deleted account"
// and the thread is read-only, whoever asks. When blocked (the peer blocked the caller, or the block list overflowed) the peer is,
// whatever the directory says, the snapshot frozen on own, the caller's entry (nil on an older page or when it is gone), and only
// if that entry names this peer; anything else is the placeholder. The live profile is never shown to a blocked caller,
// and neither is the blocker's account status. can_reply is false for a blocked caller, an overflow caller included (canReply).
func threadConversation(convID string, conv ConvDoc, uid, peer string, prof identity.Profile, live, blocked bool, snap graph.Snapshot, own *EntryDoc) *messagingv1.Conversation {
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
	// The order matters (security audit): an erased peer first; then a block, whatever the directory says about the
	// peer, so a blocked caller learns nothing about the blocker's account status (GetProfile hides it too); only then liveness.
	if peer == DeletedUID {
		c.Peer = &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
		return c
	}
	if blocked {
		// The frozen snapshot is data the caller already received. During an erasure MarkGone rewrites the entry's peerId to
		// DeletedUID before the participants, so a mismatch here is the placeholder.
		frozen, ok := frozenPeer(peer, own)
		if !ok {
			c.Peer = &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
			return c
		}
		c.Peer, c.CanReply = peerSnapshotOf(peer, frozen), canReply(peer, snap)
		return c
	}
	if !live {
		c.Peer = &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
		return c
	}
	pd := peerDocOf(prof)
	c.Peer = &commonv1.AuthorSnapshot{UserId: peer, Handle: pd.Handle, DisplayName: pd.DisplayName, AvatarUrl: pd.AvatarThumbURL, Verified: pd.Verified}
	c.CanReply = canReply(peer, snap)
	return c
}

// messagesErr turns a repo, directory or graph error into the wire answer through the shared tail (failure): ErrNotFound is
// the one NOT_FOUND of an unknown id and a non-participant (D11), and ids are redacted from anything that reaches a log. redact adds
// ids known only later (the peer uid, L-7: a peer profile or graph error can carry it in a document path).
func (s *service) messagesErr(ctx context.Context, uid, convID string, err error, redact ...string) error {
	return s.failure(ctx, "list_messages", uid, convID, err, redact...)
}

// MarkRead implements Service.MarkRead.
//
// Flag: not globally off. idempotency_key (16-64 of [A-Za-z0-9_-]) and conversation_id (32 lower-case hex) are VALIDATION with 0
// reads; the key is format-validated but not stored (founder decision 2026-10-29, option (a): the rule for a key the
// RPC does not use). The RPC is idempotent by state, and the accepted risk is that a late retry sets unreadCount to 0 over
// a newer message (the badge and the Inbox miss it until the next message or open). The write is a field-level
// Update of the caller's own dmInbox entry, else dmRequests, with an Exists precondition: the path comes from the token
// uid, so a non-participant or an unknown or deleted conversation simply has no entry and the answer is success with 0
// writes, the same as a conversation that is already read. After a write the badge cache of this instance is evicted
// (Deps.Badge; nil until then). The read time is never shown to the peer.
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
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	receipt := s.receiptsOn(ctx, uid)
	logger.SetRequestField(ctx, fieldReceipt, receipt)
	found, err := s.d.Repo.MarkRead(ctx, uid, id, s.d.Now(), receipt)
	if err != nil {
		if ce := ctxFailure(ctx); ce != nil {
			return nil, ce
		}
		return nil, redactErr(fmt.Errorf("messaging: mark read: %w", err), uid, id)
	}
	logger.SetRequestField(ctx, fieldEntryFound, found)
	if found && s.d.Badge != nil {
		s.d.Badge.Forget(uid)
	}
	return &messagingv1.MarkConversationReadResponse{}, nil
}

// receiptsOn is the caller's side of the read-receipts rule (F3): FEATURE_READ_RECEIPTS on for uid AND uid's own setting on.
// The setting comes from the cache-first Profiles seam (60 s, refreshed on the serving instance by the write), so MarkRead
// stays at 0 reads when the profile is warm. A lookup failure reads as off: the mark-read still succeeds and stores no receipt.
func (s *service) receiptsOn(ctx context.Context, uid string) bool {
	if s.flags == nil || s.d.Profiles == nil || !s.flags.Enabled(uid, identity.ReadReceiptsFlag) {
		return false
	}
	got, err := s.d.Profiles.GetProfiles(ctx, []string{uid})
	if err != nil {
		s.d.Log.WarnContext(ctx, "read_receipt_setting_unavailable", "error", redactErr(fmt.Errorf("messaging: receipt setting: %w", err), uid).Error())
		return false
	}
	return got[uid].ReadReceipts
}

// peerReadAt is the peer's receipt for a first ListMessages page: set only when the flag is on for both, both settings are on
// (callerOn and peerOn come from the profiles the page already loaded) and neither side blocks the other, then ONE read of the
// peer's own entry. Zero otherwise, including a missing entry and a failed read (WARN, never fails the page).
func (s *service) peerReadAt(ctx context.Context, conv ConvDoc, convID, peer string, callerOn, peerOn bool, snap graph.Snapshot) *timestamppb.Timestamp {
	if !callerOn || !peerOn || snap.Blocked[peer] || peerBlockedCaller(snap, peer) {
		return nil
	}
	entry, found, err := s.d.Repo.GetEntry(ctx, peer, convID, entryFolder(conv, peer))
	if err != nil {
		s.d.Log.WarnContext(ctx, "peer_read_receipt_unavailable", "error", redactErr(fmt.Errorf("messaging: peer entry: %w", err), peer, convID).Error())
		return nil
	}
	if !found || entry.ReadReceiptAt.IsZero() {
		return nil
	}
	return timestamppb.New(entry.ReadReceiptAt)
}

// peerBlockedCaller is the one rule for "the peer blocked the caller, or the list cannot say" (security review M-2):
// BlockedBy[peer], or BlockedByOverflow (the list is truncated, so it fails closed). The thread header and the account export
// both decide through it.
func peerBlockedCaller(snap graph.Snapshot, peer string) bool {
	return snap.BlockedBy[peer] || snap.BlockedByOverflow
}

// frozenPeer is the one rule for the peer snapshot of a blocked caller: the snapshot frozen on own, the caller's entry,
// only when the entry exists and names this peer (an eraser rewriting the entry's peerId to DeletedUID, or a missing entry, is
// not ok). The live directory profile is never a fallback. The thread header and the account export both use it.
func frozenPeer(peer string, own *EntryDoc) (PeerDoc, bool) {
	if own == nil || own.PeerID != peer {
		return PeerDoc{}, false
	}
	return own.Peer, true
}
