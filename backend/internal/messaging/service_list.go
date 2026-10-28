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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	// DefaultPageSize and MaxPageSize are CLAUDE.md rule 5 (0 => 20, clamped to 50).
	DefaultPageSize = 20
	MaxPageSize     = 50
	// SettleWindow is how far since_token trails the newest returned entry, so an entry committed by another instance a
	// moment after this read is still returned by the next refresh (ADR-0027 D7; the same 5 s as notifications).
	SettleWindow = 5 * time.Second
	// RefreshTokenTTL is how long a persisted since or page token is accepted (30 days, the notifications value).
	RefreshTokenTTL = 30 * 24 * time.Hour
)

// Request-line fields of a list (ADR-0027 D11, plan W7-7). Counts only: never a uid, a conversation id or a snippet.
const (
	kindListConversations = "list_conversations"
	fieldFolder           = "folder"
	fieldResults          = "results"
	fieldDroppedBlocked   = "dropped_blocked"
	fieldDroppedMuted     = "dropped_muted"
	fieldDroppedBlockedBy = "dropped_blocked_by"
	folderLabelInbox      = "inbox"
	folderLabelRequests   = "requests"
)

// Token bindings: a token opens only for the uid, the folder and the token kind it was issued for (ADR-0027 D7).
func sinceBinding(uid, folder string) string {
	return "messaging|conversations|since|" + uid + "|" + folder
}
func pageBinding(uid, folder string) string {
	return "messaging|conversations|page|" + uid + "|" + folder
}

func clampPageSize(n int32) int {
	switch {
	case n <= 0:
		return DefaultPageSize
	case n > MaxPageSize:
		return MaxPageSize
	}
	return int(n)
}

// ListConversations implements Service.ListConversations (ADR-0027 D4 "On read", D7; plan W7-7).
//
// Flag: not globally off (a caller dropped from the allowlist can still read). Validation, in this order and before any
// read: folder INBOX or REQUESTS (VALIDATION "folder"), page_token and since_token not both (VALIDATION "page_token"),
// then the token itself (sealed, bound to the uid, the folder and the token kind, 30 days; a foreign, tampered or expired
// token is VALIDATION "page_token" or "since_token", 0 reads).
//
// Read-time rules from the caller's graph snapshot (cached 60 s): REQUESTS drops an entry whose peer the caller blocks or
// mutes or who blocks the caller; INBOX keeps every entry, with can_reply false when either side blocks the other. An
// erased peer (DeletedUID) is a "Deleted account" snapshot, never looked up, and can_reply is false. Filtering runs after
// the page query, so a page may be short or empty while next_page_token is set; both tokens come from the scanned rows,
// not the shown ones. There is no refill loop and no gap token: a since refresh returns at most page_size entries.
//
// Worst-case Firestore cost (budget.Counter; the account-status interceptor read is counted as the proto comment does):
//   - first INBOX page of 20: 23 reads (interceptor 1, query 20, caller graph 1, requests count() 1), planning 9
//   - REQUESTS page, or an older INBOX page: 22 (no count())
//   - since refresh: 3 (interceptor, query min 1, caller graph; the graph is not read for an empty query), planning 2
//   - writes 0
func (s *service) ListConversations(ctx context.Context, uid string, req *messagingv1.ListConversationsRequest) (*messagingv1.ListConversationsResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindListConversations)
	in, err := s.validateList(uid, req)
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldFolder, in.label)
	if s.d.Repo == nil || s.d.Social == nil || len(s.d.CursorKey) == 0 {
		return nil, errors.New("messaging: list is not configured")
	}
	return s.listConversations(ctx, uid, in)
}

// listInput is a validated ListConversations request.
type listInput struct {
	folder, label string
	limit         int
	before, since *cursor.Cursor
	// first: no token at all, the only page that carries request_count (INBOX).
	first bool
}

func (s *service) validateList(uid string, req *messagingv1.ListConversationsRequest) (listInput, error) {
	var in listInput
	switch req.GetFolder() {
	case messagingv1.Folder_FOLDER_INBOX:
		in.folder, in.label = dmInboxCollection, folderLabelInbox
	case messagingv1.Folder_FOLDER_REQUESTS:
		in.folder, in.label = dmRequestsCollection, folderLabelRequests
	default:
		return in, apierr.Validation("folder", "folder must be INBOX or REQUESTS")
	}
	if req.GetPageToken() != "" && req.GetSinceToken() != "" {
		return in, apierr.Validation("page_token", "send either page_token or since_token, not both")
	}
	in.limit = clampPageSize(req.GetPageSize())
	now := s.d.Now()
	switch {
	case req.GetSinceToken() != "":
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, sinceBinding(uid, in.folder), req.GetSinceToken(), now, s.tokenTTL())
		if err != nil {
			return in, apierr.Validation("since_token", "invalid or expired since_token")
		}
		in.since = &c
	case req.GetPageToken() != "":
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, pageBinding(uid, in.folder), req.GetPageToken(), now, s.tokenTTL())
		if err != nil {
			return in, apierr.Validation("page_token", "invalid or expired page_token")
		}
		in.before = &c
	default:
		in.first = true
	}
	return in, nil
}

func (s *service) tokenTTL() time.Duration {
	if s.d.TokenTTL > 0 {
		return s.d.TokenTTL
	}
	return RefreshTokenTTL
}

func (s *service) listConversations(ctx context.Context, uid string, in listInput) (*messagingv1.ListConversationsResponse, error) {
	var (
		rows  []EntryRow
		count int64
	)
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(2)
	g.Go(func() (err error) {
		rows, err = s.d.Repo.ListEntries(gctx, uid, in.folder, ListQuery{Limit: in.limit, Before: in.before, After: in.since})
		return err
	})
	if in.first && in.folder == dmInboxCollection {
		g.Go(func() (err error) {
			count, err = s.d.Repo.CountRequests(gctx, uid)
			return err
		})
	}
	if err := g.Wait(); err != nil {
		return nil, s.listErr(ctx, uid, err)
	}

	// The caller's graph is read only when there is something to show (an empty refresh stays at the one query read).
	var snap graph.Snapshot
	if len(rows) > 0 {
		var err error
		if snap, err = s.d.Social.Snapshot(ctx, uid); err != nil {
			return nil, s.listErr(ctx, uid, fmt.Errorf("messaging: caller graph: %w", err))
		}
	}
	var dropped droppedCounts
	shown := make([]*messagingv1.Conversation, 0, len(rows))
	for _, r := range rows {
		if in.folder == dmRequestsCollection {
			if cause := requestHiddenBy(r.PeerID, snap); cause != "" {
				dropped.add(cause)
				continue
			}
		}
		shown = append(shown, conversationOf(r, in.folder, snap))
	}
	logger.SetRequestField(ctx, fieldResults, len(shown))
	logger.SetRequestField(ctx, fieldDroppedBlocked, dropped.blocked)
	logger.SetRequestField(ctx, fieldDroppedMuted, dropped.muted)
	logger.SetRequestField(ctx, fieldDroppedBlockedBy, dropped.blockedBy)

	now := s.d.Now()
	resp := &messagingv1.ListConversationsResponse{Conversations: shown, RequestCount: count}
	// Both tokens come from the scanned rows (what the query returned), never from the filtered ones, so a hidden
	// request still moves the position.
	if in.since == nil && len(rows) == in.limit {
		last := rows[len(rows)-1]
		resp.NextPageToken = cursor.EncodeAt(s.d.CursorKey, pageBinding(uid, in.folder), cursor.Cursor{CreatedAt: last.LastMessageAt, DocID: last.ID}, now)
	}
	if in.before == nil { // a first page or a refresh; an older page keeps the client's token
		resp.SinceToken = s.sinceToken(uid, in, rows, now)
	}
	return resp, nil
}

// sinceToken is the token for the next refresh: the newest scanned entry trailing by SettleWindow, the old position when
// nothing new arrived, or "now - settle" for an empty first page.
func (s *service) sinceToken(uid string, in listInput, rows []EntryRow, now time.Time) string {
	var c cursor.Cursor
	switch {
	case len(rows) > 0:
		c = cursor.Cursor{CreatedAt: rows[0].LastMessageAt.Add(-SettleWindow), DocID: rows[0].ID}
	case in.since != nil:
		c = *in.since
	default:
		c = cursor.Cursor{CreatedAt: now.Add(-SettleWindow), DocID: "-"}
	}
	return cursor.EncodeAt(s.d.CursorKey, sinceBinding(uid, in.folder), c, now)
}

// droppedCounts is the per-cause tally of REQUESTS entries hidden at read time (log fields only).
type droppedCounts struct{ blocked, muted, blockedBy int }

const (
	causeBlocked   = "blocked"
	causeMuted     = "muted"
	causeBlockedBy = "blocked_by"
)

func (d *droppedCounts) add(cause string) {
	switch cause {
	case causeBlocked:
		d.blocked++
	case causeMuted:
		d.muted++
	case causeBlockedBy:
		d.blockedBy++
	}
}

// requestHiddenBy is the REQUESTS read-time rule (ADR-0027 D4 "On read"): the cause that hides the entry, or "". The
// blockedBy overflow flag is not consulted (it would cost a graph read per peer), like the notifications list.
func requestHiddenBy(peer string, snap graph.Snapshot) string {
	switch {
	case snap.Blocked[peer]:
		return causeBlocked
	case snap.Muted[peer]:
		return causeMuted
	case snap.BlockedBy[peer]:
		return causeBlockedBy
	}
	return ""
}

// conversationOf maps an entry to the wire Conversation. The state comes from the folder (the entry holds none, and a
// conversation read per row would break the budget): REQUESTS is REQUEST, INBOX is ACCEPTED.
func conversationOf(r EntryRow, folder string, snap graph.Snapshot) *messagingv1.Conversation {
	c := &messagingv1.Conversation{
		Id: r.ID, Kind: messagingv1.ConversationKind_CONVERSATION_KIND_DIRECT,
		Peer: peerSnapshotOf(r.PeerID, r.Peer), State: messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED,
		Folder: messagingv1.Folder_FOLDER_INBOX, LastMessage: previewOf(r),
		UnreadCount: r.UnreadCount, CanReply: canReply(r.PeerID, snap), Silent: r.Silent,
		UpdatedAt: timestamppb.New(r.LastMessageAt),
	}
	if folder == dmRequestsCollection {
		c.State, c.Folder = messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.Folder_FOLDER_REQUESTS
	}
	return c
}

// canReply: false when either side blocks the other or the peer deleted the account (read-only thread, still reportable).
func canReply(peer string, snap graph.Snapshot) bool {
	return peer != DeletedUID && !snap.Blocked[peer] && !snap.BlockedBy[peer]
}

// peerSnapshotOf is Conversation.peer from the entry's own snapshot. An erased peer (DeletedUID) is "Deleted account"
// with no user id, handle or avatar, whatever the entry holds: it is never looked up.
func peerSnapshotOf(peerID string, p PeerDoc) *commonv1.AuthorSnapshot {
	if peerID == DeletedUID {
		return &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}
	}
	return &commonv1.AuthorSnapshot{UserId: peerID, Handle: p.Handle, DisplayName: p.DisplayName, AvatarUrl: p.AvatarThumbURL, Verified: p.Verified}
}

// previewOf is the last-message line. A tombstone (the sender deleted the account, or a moderator removed it) has an
// empty snippet; the client renders "Message deleted".
func previewOf(r EntryRow) *messagingv1.MessagePreview {
	p := &messagingv1.MessagePreview{FromSelf: r.Last.FromSelf, CreatedAt: timestamppb.New(r.LastMessageAt)}
	switch r.Last.State {
	case msgVisible:
		p.State, p.Snippet = messagingv1.MessageState_MESSAGE_STATE_VISIBLE, r.Last.Snippet
	case msgDeletedAccount:
		p.State = messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT
	case msgRemoved:
		p.State = messagingv1.MessageState_MESSAGE_STATE_REMOVED
	}
	return p
}

// listErr turns a repo or graph error into the wire answer; ids are redacted from anything that reaches a log.
func (s *service) listErr(ctx context.Context, uid string, err error) error {
	if ce := ctxFailure(ctx); ce != nil {
		return ce
	}
	return logger.RedactErr(fmt.Errorf("messaging: list conversations: %w", err), uid)
}
