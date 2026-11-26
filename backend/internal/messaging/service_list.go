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
	// DefaultPageSize and MaxPageSize are the query-limit rule (0 => 20, clamped to 50).
	DefaultPageSize = 20
	MaxPageSize     = 50
	// SettleWindow is how far since_token trails the newest returned entry, so an entry committed by another instance a
	// moment after this read is still returned by the next refresh (the same 5 s as notifications).
	SettleWindow = 5 * time.Second
	// RefreshTokenTTL is how long a persisted since or page token is accepted (30 days, the notifications value).
	RefreshTokenTTL = 30 * 24 * time.Hour
)

// Request-line fields of a list. Counts only: never a uid, a conversation id or a snippet.
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

// Token bindings: a token opens only for the uid, the folder and the token kind it was issued for.
//
// The since kind is "since-changed": the position is a changedAt, not a lastMessageAt. A token
// of the older kind fails to open (VALIDATION since_token, before any read) and the client cold-opens the folder once; an entry
// written before changedAt existed would otherwise be skipped by a query on it.
func sinceBinding(uid, folder string) string {
	return "messaging|conversations|since-changed|" + uid + "|" + folder
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

// ListConversations implements Service.ListConversations ("On read", D7).
//
// Flag: not globally off (a caller dropped from the allowlist can still read). Validation, in this order and before any
// read: folder INBOX or REQUESTS (VALIDATION "folder"), page_token and since_token not both (VALIDATION "page_token"),
// then the token itself (sealed, bound to the uid, the folder and the token kind, 30 days; a foreign, tampered or expired
// token is VALIDATION "page_token" or "since_token", before any read).
//
// Read-time rules from the graph snapshots (cached 60 s; the peer's only past the blockedBy cap): REQUESTS drops an entry whose
// peer the caller blocks or mutes or who blocks the caller; INBOX keeps every entry, with can_reply false when either side blocks the other. An
// erased peer (DeletedUID) is a "Deleted account" snapshot, never looked up, and can_reply is false. Every row agrees with
// the thread header (ListMessages.conversation) for the same caller (rowSources, rowPeer): a peer the directory no longer
// lists as ACTIVE (one batched, cache-first lookup per page) is "Deleted account" and read-only unless the peer blocks the
// caller (then the entry's frozen snapshot, so the block hides the account status), and a request whose recipient was
// erased stays REQUEST in the INBOX for its requester. Filtering runs after
// the page query, so a page may be short or empty while next_page_token is set; both tokens come from the scanned rows,
// not the shown ones. There is no refill loop and no gap token: a since refresh returns at most page_size entries.
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
	if s.d.Repo == nil || s.d.Social == nil || s.d.Profiles == nil || len(s.d.CursorKey) == 0 {
		return nil, errors.New("messaging: list is not configured")
	}
	return s.listConversations(ctx, uid, in)
}

// listInput is a validated ListConversations request.
type listInput struct {
	folder, label string
	limit         int
	before, since *cursor.Cursor
	// withCount: INBOX and not an older page (no page_token): a first page or a since refresh, the responses that carry
	// request_count.
	withCount bool
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
	}
	in.withCount = in.folder == dmInboxCollection && in.before == nil
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
	g.Go(s.recovered(ctx, func() (err error) {
		rows, err = s.d.Repo.ListEntries(gctx, uid, in.folder, ListQuery{Limit: in.limit, Before: in.before, After: in.since})
		return err
	}))
	if in.withCount {
		g.Go(s.recovered(ctx, func() (err error) {
			count, err = s.d.Repo.CountRequests(gctx, uid)
			return err
		}))
	}
	if err := g.Wait(); err != nil {
		return nil, s.listErr(ctx, uid, err)
	}

	// The caller's graph, the peers' liveness and (rarely) the conversations of erased-peer rows are read only when there is
	// something to show (an empty refresh stays at the one query read).
	var rs rowSources
	if len(rows) > 0 {
		var err error
		if rs, err = s.rowSources(ctx, uid, in.folder, rows); err != nil {
			return nil, s.listErr(ctx, uid, err)
		}
	}
	snap := rs.snap
	var dropped droppedCounts
	shown := make([]*messagingv1.Conversation, 0, len(rows))
	for _, r := range rows {
		if in.folder == dmRequestsCollection {
			cause := requestHiddenBy(r.PeerID, snap)
			if cause == "" {
				blocked, err := s.requestBlockedByPeer(ctx, uid, r.PeerID, snap)
				if err != nil {
					return nil, s.listErr(ctx, uid, err)
				}
				if blocked {
					cause = causeBlockedBy
				}
			}
			if cause != "" {
				dropped.add(cause)
				continue
			}
		}
		shown = append(shown, conversationOf(r, in.folder, rs))
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

// sinceToken is the token for the next refresh: on a refresh the newest changed entry's changedAt trailing by SettleWindow,
// the old position when nothing changed; on a first page "now - settle" (its rows are ordered by lastMessageAt and do not
// bound recently changed entries further down, and an old newest lastMessageAt would make the next since page full).
func (s *service) sinceToken(uid string, in listInput, rows []EntryRow, now time.Time) string {
	var newest *cursor.Cursor
	if in.since != nil && len(rows) > 0 {
		newest = &cursor.Cursor{CreatedAt: rows[0].ChangedAt, DocID: rows[0].ID}
	}
	return s.sealSince(sinceBinding(uid, in.folder), newest, in.since, now)
}

// sealSince seals the next since position under binding (shared by ListConversations and ListMessages): newest (the first
// scanned row) trailing by SettleWindow, else prev (the position the client sent), else "now - settle".
func (s *service) sealSince(binding string, newest, prev *cursor.Cursor, now time.Time) string {
	return cursor.EncodeAt(s.d.CursorKey, binding, sinceCursor(newest, prev, now), now)
}

// sinceCursor is the position of the next refresh: newest trailing by SettleWindow, else prev, else "now - settle".
func sinceCursor(newest, prev *cursor.Cursor, now time.Time) cursor.Cursor {
	switch {
	case newest != nil:
		return cursor.Cursor{CreatedAt: newest.CreatedAt.Add(-SettleWindow), DocID: newest.DocID}
	case prev != nil:
		return *prev
	}
	return cursor.Cursor{CreatedAt: now.Add(-SettleWindow), DocID: "-"}
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

// requestHiddenBy is the REQUESTS read-time rule ("On read") as far as the caller's own graph can answer it: the
// cause that hides the entry, or "". An overflowed caller also needs requestBlockedByPeer.
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

// requestBlockedByPeer closes the gap requestHiddenBy leaves for a caller past the blockedBy cap, whose own list no longer
// names every blocker: it asks the peer's graph, as notifications' Fanout does. Only such a caller pays the read (cached
// 60 s, at most one per row of the page); a deleted peer has no graph to ask.
func (s *service) requestBlockedByPeer(ctx context.Context, uid, peer string, snap graph.Snapshot) (bool, error) {
	if !snap.BlockedByOverflow || peer == DeletedUID {
		return false, nil
	}
	ps, err := s.d.Social.Snapshot(ctx, peer)
	if err != nil {
		return false, redactErr(fmt.Errorf("messaging: peer graph: %w", err), peer)
	}
	return ps.Blocked[uid], nil
}

// rowSources is what a page of rows is decided from besides the rows themselves: the caller's graph, the peers the
// directory lists as ACTIVE, and the erased-peer INBOX rows whose conversation is still a REQUEST.
type rowSources struct {
	snap graph.Snapshot
	// live holds the peers GetProfiles returned (it drops every uid that is not ACTIVE: suspended, being deleted, missing).
	live map[string]bool
	// erasedRequests holds the ids of INBOX rows whose peer was erased while the conversation was a REQUEST (the eraser's
	// MarkGone deletes requestPending from the requester's entry, so the entry alone would read ACCEPTED).
	erasedRequests map[string]bool
}

// rowSources reads, in parallel, what conversationOf needs for a non-empty page, the same facts the thread header
// (ListMessages.conversation) is decided from:
//   - the caller's graph (60 s cache);
//   - the peers' liveness: ONE batched, cache-first directory call (identity's 60 s profile cache, then one GetAll on
//     users/* for the misses) over the page's distinct live-uid peers, at most MaxPageSize, within GetProfiles' 50. The
//     public-id interceptor reads the same profile cache for this response, so its lookup then hits what this one warmed;
//   - only when the page holds an INBOX row whose peer is erased and that is not RequestPending: those rows' conversations
//     (the instance's 60 s copy, else ONE GetAll for the misses), to tell a request whose recipient was erased (REQUEST in
//     the header) from an accepted conversation (ACCEPTED). A page without such a row reads none.
//
// Any failure fails the page, as the header fails on the same reads; peer uids are redacted from the error.
func (s *service) rowSources(ctx context.Context, uid, folder string, rows []EntryRow) (rowSources, error) {
	var (
		out    rowSources
		peers  []string
		erased []string
	)
	seen := make(map[string]bool, len(rows))
	for _, r := range rows {
		if r.PeerID == DeletedUID {
			if folder == dmInboxCollection && !r.RequestPending {
				erased = append(erased, r.ID)
			}
			continue
		}
		if !seen[r.PeerID] {
			seen[r.PeerID] = true
			peers = append(peers, r.PeerID)
		}
	}
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(3)
	g.Go(s.recovered(ctx, func() (err error) {
		if out.snap, err = s.d.Social.Snapshot(gctx, uid); err != nil {
			return fmt.Errorf("messaging: caller graph: %w", err)
		}
		return nil
	}))
	if len(peers) > 0 {
		g.Go(s.recovered(ctx, func() error {
			got, err := s.d.Profiles.GetProfiles(gctx, peers)
			if err != nil {
				return redactErr(fmt.Errorf("messaging: peer profiles: %w", err), peers...)
			}
			out.live = make(map[string]bool, len(got))
			for _, p := range peers {
				out.live[p] = got[p].UserID != "" // the header's rule (listMessages: live)
			}
			return nil
		}))
	}
	if len(erased) > 0 {
		g.Go(s.recovered(ctx, func() (err error) {
			out.erasedRequests, err = s.erasedPeerRequests(gctx, uid, erased)
			return err
		}))
	}
	if err := g.Wait(); err != nil {
		return rowSources{}, err
	}
	return out, nil
}

// erasedPeerRequests answers which of ids (the caller's own INBOX rows whose peer is erased) belong to a conversation that
// is still a REQUEST: the instance's 60 s copy when it names the caller, else one GetAll for the rest. A conversation the
// caller is not in, or a missing one, is not a request (the row keeps ACCEPTED; the header answers NOT_FOUND there). A
// request whose peer is gone can never be accepted, so a cached copy cannot be stale on this point.
func (s *service) erasedPeerRequests(ctx context.Context, uid string, ids []string) (map[string]bool, error) {
	out := map[string]bool{}
	var misses []string
	for _, id := range ids {
		if c, ok := s.convs.Get(id); ok && c.hasParticipant(uid) {
			out[id] = c.State == stateRequest
			continue
		}
		misses = append(misses, id)
	}
	if len(misses) == 0 {
		return out, nil
	}
	got, err := s.d.Repo.GetConversations(ctx, misses)
	if err != nil {
		return nil, redactErr(fmt.Errorf("messaging: erased-peer conversations: %w", err), misses...)
	}
	for id, c := range got {
		if !c.hasParticipant(uid) {
			continue
		}
		s.putConv(id, c)
		out[id] = c.State == stateRequest
	}
	return out, nil
}

// conversationOf maps an entry to the wire Conversation, agreeing with the thread header (threadConversation) for the
// same caller: same state, folder and can_reply, and the same "Deleted account" placeholder for an erased or inactive
// peer. The state comes from the folder: REQUESTS is REQUEST, INBOX is ACCEPTED, except an INBOX row with RequestPending
// (the requester's own entry while the peer has not accepted) or in rs.erasedRequests (a request whose recipient was
// erased), which is REQUEST in the INBOX, the pair the header returns for the requester. A live peer is shown from the
// entry's own snapshot (the header shows the live profile; the entry copy is what the list always showed).
func conversationOf(r EntryRow, folder string, rs rowSources) *messagingv1.Conversation {
	peer, reply := rowPeer(r, rs)
	c := &messagingv1.Conversation{
		Id: r.ID, Kind: messagingv1.ConversationKind_CONVERSATION_KIND_DIRECT,
		Peer: peer, State: messagingv1.ConversationState_CONVERSATION_STATE_ACCEPTED,
		Folder: messagingv1.Folder_FOLDER_INBOX, LastMessage: previewOf(r),
		UnreadCount: r.UnreadCount, CanReply: reply, Silent: r.Silent,
		UpdatedAt: timestamppb.New(r.LastMessageAt),
	}
	if folder == dmRequestsCollection {
		c.State, c.Folder = messagingv1.ConversationState_CONVERSATION_STATE_REQUEST, messagingv1.Folder_FOLDER_REQUESTS
	}
	if folder == dmInboxCollection && (r.RequestPending || rs.erasedRequests[r.ID]) {
		c.State = messagingv1.ConversationState_CONVERSATION_STATE_REQUEST
	}
	return c
}

// rowPeer is the peer and can_reply of a row, in the header's order (security audit): an erased peer first; then a block
// of the caller (or an overflowed blockedBy list), whatever the directory says, so a blocked caller learns nothing about the
// blocker's account status (the entry's snapshot is the frozen one the header shows, as the row is the caller's own entry
// naming this peer); only then liveness, where a peer the directory does not list as ACTIVE is "Deleted account" and
// read-only.
func rowPeer(r EntryRow, rs rowSources) (*commonv1.AuthorSnapshot, bool) {
	switch {
	case r.PeerID == DeletedUID:
		return &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}, false
	case peerBlockedCaller(rs.snap, r.PeerID):
		return peerSnapshotOf(r.PeerID, r.Peer), canReply(r.PeerID, rs.snap)
	case !rs.live[r.PeerID]:
		return &commonv1.AuthorSnapshot{DisplayName: DeletedAccountName}, false
	}
	return peerSnapshotOf(r.PeerID, r.Peer), canReply(r.PeerID, rs.snap)
}

// canReply: false when either side blocks the other or the peer deleted the account (read-only thread, still reportable). A
// caller whose blockedBy list overflowed cannot tell who blocks them, so it is fail-closed too (security audit); the send
// path stays authoritative.
func canReply(peer string, snap graph.Snapshot) bool {
	return peer != DeletedUID && !snap.Blocked[peer] && !snap.BlockedBy[peer] && !snap.BlockedByOverflow
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
// empty snippet; the client renders "Message deleted". An encrypted last message (last.encrypted) is encrypted = true with
// an empty snippet and shared_post false, whatever else the entry holds: the server never has text for it.
func previewOf(r EntryRow) *messagingv1.MessagePreview {
	p := &messagingv1.MessagePreview{FromSelf: r.Last.FromSelf, CreatedAt: timestamppb.New(r.LastMessageAt)}
	switch r.Last.State {
	case msgVisible:
		p.State, p.Snippet, p.SharedPost = messagingv1.MessageState_MESSAGE_STATE_VISIBLE, r.Last.Snippet, r.Last.SharedPost
	case msgDeletedAccount:
		p.State = messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT
	case msgRemoved:
		p.State = messagingv1.MessageState_MESSAGE_STATE_REMOVED
	}
	if r.Last.Encrypted {
		p.Encrypted, p.Snippet, p.SharedPost = true, "", false
	}
	return p
}

// listErr turns a repo or graph error into the wire answer; ids are redacted from anything that reaches a log.
func (s *service) listErr(ctx context.Context, uid string, err error) error {
	if ce := ctxFailure(ctx); ce != nil {
		return ce
	}
	return redactErr(fmt.Errorf("messaging: list conversations: %w", err), uid)
}
