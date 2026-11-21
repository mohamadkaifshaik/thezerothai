package messaging

// The five MLS sync RPCs of an encrypted conversation: ListConversationCommits, ListEpochMessages, ListWelcomes,
// AckWelcomes and ListMessageTombstones (proto, each RPC comment), and the service caps of CommitConversation
// (commitCaps). Flag: "messaging" not globally off for all five (a caller dropped from the allowlist keeps catching up);
// ListMessageTombstones and ListEpochMessages with order = CREATED_AT also need e2ee_dm not globally off (never per
// caller, for the same reason). Request lines carry counts and enums only: never commit, welcome or message bytes, a
// device id or a uid.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

const (
	kindListCommits   = "list_commits"
	kindEpochMessages = "list_epoch_messages"
	kindListWelcomes  = "list_welcomes"
	kindAckWelcomes   = "ack_welcomes"
	fieldMore         = "more"
	fieldDropped      = "dropped_leftovers"

	// MaxAckWelcomes is the most welcome ids one AckWelcomes call deletes.
	MaxAckWelcomes = 50
	// MaxWelcomesPage is ListWelcomes' page size, default and maximum: a welcome is up to 64 KiB, so 10 bound one answer
	// to about 640 KiB (the 20 / 50 of the other lists would allow 3.2 MB).
	MaxWelcomesPage = 10

	// limitResetsDaily is the limit name of the CommitConversation reset cap (Limits.ResetsPerDay).
	limitResetsDaily = "messages_resets_daily"
	// limitCommitsPerConvDaily is the limit name of the CommitConversation per-(caller, conversation) cap
	// (Limits.CommitsPerConversationPerDay).
	limitCommitsPerConvDaily = "messages_commits_per_conversation_daily"

	// maxDocPart is the largest generation or epoch commitDocID writes in its 10 zero-padded digits (so ids sort by pair).
	// A stored pair never comes near it (10^10 commits or resets); an after-pair beyond it is clamped (commitsAfterID).
	maxDocPart = 9_999_999_999
	// afterEverything sorts after every commit document id (all digits and "_"): StartAfter it reads nothing.
	afterEverything = "~"

	// EpochResumeTrail is how far resume_page_token of an order = CREATED_AT page trails the read time: a message stamped
	// more than this before a read was committed by then. It must stay above the Cloud Run request_timeout_seconds (30,
	// the bound of a send's stamp-to-commit time) plus the clock skew between instances.
	EpochResumeTrail = 60 * time.Second
	// MaxTombstonePage and defaultTombstonePage are ListMessageTombstones' page size bounds.
	MaxTombstonePage     = 100
	defaultTombstonePage = 50

	kindTombstones     = "list_message_tombstones"
	fieldOrderFallback = "epoch_order_fallback"
	// fieldTombDropped counts ListMessageTombstones rows skipped for a state other than the two or a malformed id.
	fieldTombDropped = "dropped"

	// trailDocID is the document id a time-only position (a resume token's trail cut) is sealed with: the cursor codec
	// refuses an empty id, and this one is never a message id (not hex), so it cannot collide with a full position.
	trailDocID = "-"
)

// commitCaps draws on CommitConversation's two service caps, in this order, after the flag, the verified email and the
// step-1 form (a malformed call burns neither) and before any lookup (so a refusal says nothing about the conversation):
//
//  1. "messages_commits_per_conversation_daily" (MESSAGES_COMMITS_PER_CONVERSATION_PER_DAY) for every call, a reset
//     included, keyed by a hash of caller and conversation id (convCommitKey): a non-participant or an unknown id draws only
//     on the caller's own counter for that id;
//  2. "messages_resets_daily" (MESSAGES_RESETS_PER_DAY) for a call with reset = true only.
//
// Like the interceptor's per-call cap "messages_commits_daily" (and its per-minute bucket), which every call has already
// drawn on before the flag, they count every such call, a recognised retry and a refused one included. A call refused by
// the first does not draw on the second. A refusal is RATE_LIMITED with metadata["limit"] = the cap's name and retry_after
// the next IST day.
func (s *service) commitCaps(ctx context.Context, uid string, req *messagingv1.CommitConversationRequest) error {
	if s.convCommits != nil && !s.convCommits.Allow(convCommitKey(uid, req.GetConversationId())) {
		return s.convCommits.ExceededError(ctx, limitCommitsPerConvDaily)
	}
	if req.GetReset_() && s.resets != nil && !s.resets.Allow(uid) {
		return s.resets.ExceededError(ctx, limitResetsDaily)
	}
	return nil
}

// convCommitKey is the per-(caller, conversation) cap's counter key: a hash, so the in-memory map holds no uid.
func convCommitKey(uid, convID string) string {
	sum := sha256.Sum256([]byte(uid + "|" + convID))
	return hex.EncodeToString(sum[:16])
}

// ListCommits implements Service.ListCommits (ListConversationCommits).
//
// Validation before any read: conversation_id (32 lower-case hex); page_size 0 or negative => 20, at most 50. The after
// pair is not validated: (0, 0) lists everything still stored.
//
// One read-only transaction (Repo.ListCommits): the conversation, fresh (never the instance cache), then for an MLS
// conversation one page of commit records strictly after (after_generation, after_epoch) in document-id order (= by
// generation, then epoch). Missing and non-participant answer the one NOT_FOUND before the commits are read; a NONE
// conversation answers no commits and the pair (0, 0).
//
// A record at or after the current pair is dropped (defence in depth): a record of this incarnation is always at a pair
// the conversation has LEFT (the record and the move are one transaction), so such a record can only be a leftover of an
// earlier conversation with the same id. The account eraser deletes the commit records with the conversation tree when
// both participants are gone (DeleteTreePage), so tree deletion no longer leaves any; the former second rule (a record
// created before the conversation, a cross-instance clock comparison) was removed with that change. more is true when the
// query returned a full page and at least one record is returned (a full page of dropped records alone answers more =
// false, so a client never re-asks the same after-pair forever; it is then a gap, handled by the client's catch-up rules).
func (s *service) ListCommits(ctx context.Context, uid string, req *messagingv1.ListConversationCommitsRequest) (*messagingv1.ListConversationCommitsResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindListCommits)
	id := req.GetConversationId()
	if !ValidID(id) {
		return nil, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	limit := clampPageSize(req.GetPageSize())
	if s.d.Repo == nil {
		return nil, errors.New("messaging: list commits is not configured")
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	afterGen, afterEpoch := req.GetAfterGeneration(), req.GetAfterEpoch()
	page, err := s.d.Repo.ListCommits(ctx, CommitsQuery{UID: uid, ConvID: id, AfterID: commitsAfterID(afterGen, afterEpoch), Limit: limit})
	if err != nil {
		return nil, s.failure(ctx, kindListCommits, uid, id, err)
	}
	resp := &messagingv1.ListConversationCommitsResponse{}
	if !page.Conv.encrypted() {
		logger.SetRequestField(ctx, fieldResults, 0)
		return resp, nil
	}
	resp.MlsGeneration, resp.MlsEpoch = wirePair(page.Conv.MlsGen), wirePair(page.Conv.MlsEpoch)
	dropped := 0
	for _, r := range page.Rows {
		if !commitAfter(r.CommitDoc, afterGen, afterEpoch) {
			continue // only possible for an after-pair beyond the id format (clamped); never returned
		}
		if !liveCommit(page.Conv, r.CommitDoc) {
			dropped++
			continue
		}
		resp.Commits = append(resp.Commits, &messagingv1.ConversationCommit{
			MlsGeneration: wirePair(r.Gen), MlsEpoch: wirePair(r.Epoch), Commit: r.Data,
			FromSelf: r.SenderID == uid, CreatedAt: timestamppb.New(r.CreatedAt),
		})
	}
	resp.More = len(page.Rows) == limit && len(resp.Commits) > 0
	logger.SetRequestField(ctx, fieldResults, len(resp.Commits))
	logger.SetRequestField(ctx, fieldMore, resp.More)
	if dropped > 0 {
		logger.SetRequestField(ctx, fieldDropped, dropped)
	}
	return resp, nil
}

// commitsAfterID is the commit document id to StartAfter for the after pair: commitDocID's format, computed on the unsigned
// wire values (a value above 2^63 - 1 must not turn negative and list everything). An epoch beyond the 10-digit format is
// clamped to the last id of that generation; a generation beyond it reads nothing.
func commitsAfterID(gen, epoch uint64) string {
	if gen > maxDocPart {
		return afterEverything
	}
	epoch = min(epoch, maxDocPart)
	return fmt.Sprintf("%010d_%010d", gen, epoch)
}

// commitAfter reports whether a stored record's pair is strictly after the request's after pair.
func commitAfter(c CommitDoc, gen, epoch uint64) bool {
	g, e := wirePair(c.Gen), wirePair(c.Epoch)
	return g > gen || (g == gen && e > epoch)
}

// liveCommit reports whether a record can belong to this incarnation of the conversation (see ListCommits): its pair is
// strictly before the conversation's current pair.
func liveCommit(conv ConvDoc, c CommitDoc) bool {
	return pairAfter(conv.MlsGen, conv.MlsEpoch, c.Gen, c.Epoch)
}

// epochPageBinding binds a ListEpochMessages page token to the caller, the conversation and the pair.
func epochPageBinding(uid, convID, key string) string {
	return "messaging|epoch|page|" + uid + "|" + convID + "|" + key
}

// epochTimePageBinding binds an order = CREATED_AT page or resume token: the id-order binding plus "|t", so a token of
// one order is refused by the other.
func epochTimePageBinding(uid, convID, key string) string {
	return epochPageBinding(uid, convID, key) + "|t"
}

// tombstonePageBinding binds a ListMessageTombstones page token to the caller and the conversation.
func tombstonePageBinding(uid, convID string) string {
	return "messaging|tombstones|page|" + uid + "|" + convID
}

// guardNotGloballyOff is the not-globally-off gate on one named flag (the shape of guardFlag): FAILED_PRECONDITION +
// FEATURE_DISABLED with metadata["feature"] = name, before any lookup. A nil checker is off.
func (s *service) guardNotGloballyOff(ctx context.Context, name string) error {
	err := flags.Guard(ctx, func(_, name string) bool { return s.flags != nil && !s.flags.GloballyOff(name) }, "", name)
	if err == nil {
		return nil
	}
	logger.SetRequestField(ctx, "feature", name)
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return ae.WithMeta("feature", name)
	}
	return err
}

// ListMessageTombstones implements Service.ListMessageTombstones.
//
// Gates, before any read, in this order: "messaging" not globally off, then "e2ee_dm" not globally off (never per caller:
// a user dropped from the allowlist keeps clearing removed text). Validation: conversation_id (32 lower-case hex);
// page_size (0 or negative => 50, max 100); the page token (tombstonePageBinding, 30 days, a message id: anything else is
// VALIDATION page_token). Then the participant check through the 60 s instance copy (the one NOT_FOUND, as
// ListEpochMessages), then Repo.ListTombstones (two queries of at most page_size documents, state only). The answer holds
// ids and states only: a stored state other than REMOVED / DELETED_ACCOUNT, or an id that is not a message id, is skipped
// (the "dropped" request field). next_page_token, when more, is at the page's last message id (a skipped one included, so
// the walk always advances).
func (s *service) ListMessageTombstones(ctx context.Context, uid string, req *messagingv1.ListMessageTombstonesRequest) (*messagingv1.ListMessageTombstonesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	if err := s.guardNotGloballyOff(ctx, keys.FlagName); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindTombstones)
	id := req.GetConversationId()
	if !ValidID(id) {
		return nil, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	limit := tombstonePageSize(req.GetPageSize())
	if s.d.Repo == nil || len(s.d.CursorKey) == 0 {
		return nil, errors.New("messaging: list message tombstones is not configured")
	}
	binding := tombstonePageBinding(uid, id)
	now := s.d.Now()
	var after string
	if tok := req.GetPageToken(); tok != "" {
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, binding, tok, now, s.tokenTTL())
		if err != nil || !ValidID(c.DocID) {
			return nil, invalidPageToken()
		}
		after = c.DocID
	}
	if _, err := s.participantConv(ctx, kindTombstones, uid, id); err != nil {
		return nil, err
	}
	rows, more, err := s.d.Repo.ListTombstones(ctx, id, after, limit)
	if err != nil {
		return nil, s.failure(ctx, kindTombstones, uid, id, err)
	}
	resp := &messagingv1.ListMessageTombstonesResponse{Tombstones: make([]*messagingv1.MessageTombstone, 0, len(rows))}
	dropped, lastID := 0, ""
	for _, r := range rows {
		if !ValidID(r.ID) {
			dropped++
			continue
		}
		lastID = r.ID
		st, ok := tombstoneState(r.State)
		if !ok {
			dropped++
			continue
		}
		resp.Tombstones = append(resp.Tombstones, &messagingv1.MessageTombstone{Id: r.ID, State: st})
	}
	if more && lastID != "" {
		resp.NextPageToken = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: now, DocID: lastID}, now)
	}
	logger.SetRequestField(ctx, fieldResults, len(resp.Tombstones))
	logger.SetRequestField(ctx, fieldMore, resp.NextPageToken != "")
	if dropped > 0 {
		logger.SetRequestField(ctx, fieldTombDropped, dropped)
	}
	return resp, nil
}

// tombstoneState maps a stored tombstone state to the wire; ok is false for any other state.
func tombstoneState(state string) (messagingv1.MessageState, bool) {
	switch state {
	case msgRemoved:
		return messagingv1.MessageState_MESSAGE_STATE_REMOVED, true
	case msgDeletedAccount:
		return messagingv1.MessageState_MESSAGE_STATE_DELETED_ACCOUNT, true
	}
	return messagingv1.MessageState_MESSAGE_STATE_UNSPECIFIED, false
}

// tombstonePageSize is ListMessageTombstones' page size: 0 or negative => defaultTombstonePage, at most MaxTombstonePage.
func tombstonePageSize(n int32) int {
	switch {
	case n <= 0:
		return defaultTombstonePage
	case n > MaxTombstonePage:
		return MaxTombstonePage
	}
	return int(n)
}

// ListEpochMessages implements Service.ListEpochMessages.
//
// Validation before any read, in this order: conversation_id; mls_generation >= 1; mls_epoch >= 1; page_size (0 => 20, max
// 50); order (an unknown value is VALIDATION order; CREATED_AT continues in listEpochByTime after the e2ee_dm
// not-globally-off gate); the page token (sealed, bound to caller, conversation and pair, 30 days: a foreign, tampered,
// expired, other-pair or other-order token is VALIDATION page_token). Then the participant check through the 60 s instance copy (the one NOT_FOUND), then ONE
// query: messages where mlsKey == "gen:epoch" in document-id order after the token's id, Limit page_size. The query runs
// even when the cached copy says NONE (it can be 60 s stale, and an empty answer reads as "complete"). Messages at or
// before the caller's clearedAt ARE returned (completeness counting; the client never shows or stores them) and that
// time is answered as cleared_at (from the same conversation copy, no extra read), with the same mapping as
// ListMessages: a tombstone or swept message has no ciphertext (ciphertext_removed), shared_post is never set.
// next_page_token is set when the page was full.
func (s *service) ListEpochMessages(ctx context.Context, uid string, req *messagingv1.ListEpochMessagesRequest) (*messagingv1.ListEpochMessagesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindEpochMessages)
	id := req.GetConversationId()
	if !ValidID(id) {
		return nil, apierr.Validation("conversation_id", "conversation_id must be 32 lower-case hex characters")
	}
	gen, epoch := req.GetMlsGeneration(), req.GetMlsEpoch()
	if gen < 1 {
		return nil, apierr.Validation("mls_generation", "mls_generation must be at least 1")
	}
	if epoch < 1 {
		return nil, apierr.Validation("mls_epoch", "mls_epoch must be at least 1")
	}
	limit := clampPageSize(req.GetPageSize())
	if s.d.Repo == nil || len(s.d.CursorKey) == 0 {
		return nil, errors.New("messaging: list epoch messages is not configured")
	}
	key := strconv.FormatUint(gen, 10) + ":" + strconv.FormatUint(epoch, 10) // = mlsKey for every stored pair
	now := s.d.Now()
	switch req.GetOrder() {
	case messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_UNSPECIFIED:
	case messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_CREATED_AT:
		if err := s.guardNotGloballyOff(ctx, keys.FlagName); err != nil {
			return nil, err
		}
		return s.listEpochByTime(ctx, uid, id, key, req.GetPageToken(), limit, now)
	default:
		return nil, apierr.Validation("order", "order must be EPOCH_MESSAGE_ORDER_UNSPECIFIED or EPOCH_MESSAGE_ORDER_CREATED_AT")
	}
	binding := epochPageBinding(uid, id, key)
	var after string
	if tok := req.GetPageToken(); tok != "" {
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, binding, tok, now, s.tokenTTL())
		if err != nil || !ValidID(c.DocID) {
			return nil, invalidPageToken()
		}
		after = c.DocID
	}
	conv, err := s.participantConv(ctx, kindEpochMessages, uid, id)
	if err != nil {
		return nil, err
	}
	rows, err := s.d.Repo.ListEpochMessages(ctx, id, key, after, limit)
	if err != nil {
		return nil, s.failure(ctx, kindEpochMessages, uid, id, err)
	}
	resp := epochPage(conv, id, uid, rows)
	if len(rows) == limit {
		last := rows[len(rows)-1]
		resp.NextPageToken = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}, now)
	}
	logger.SetRequestField(ctx, fieldResults, len(rows))
	return resp, nil
}

// invalidPageToken is the one VALIDATION page_token answer of the sync lists.
func invalidPageToken() *apierr.Error {
	return apierr.Validation("page_token", "invalid or expired page_token")
}

// participantConv is the participant check of ListEpochMessages and ListMessageTombstones: the conversation through the
// 60 s instance copy (conversationHit), and the one NOT_FOUND for a missing conversation or a non-participant. It logs the
// conversation hash and whether the copy was cached.
func (s *service) participantConv(ctx context.Context, op, uid, id string) (ConvDoc, error) {
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	conv, hit, err := s.conversationHit(ctx, uid, id)
	logger.SetRequestField(ctx, fieldCacheHit, hit)
	if err == nil && peerOf(conv.Participants, uid) == "" {
		err = ErrNotFound
	}
	if err != nil {
		return ConvDoc{}, s.failure(ctx, op, uid, id, err)
	}
	return conv, nil
}

// epochPage is a ListEpochMessages answer of rows, with cleared_at: the caller's own DeleteConversation time from the
// conversation already read for the participant check (the 60 s instance copy, like ListMessages' own filter); no extra
// read.
func epochPage(conv ConvDoc, convID, uid string, rows []MessageRow) *messagingv1.ListEpochMessagesResponse {
	resp := &messagingv1.ListEpochMessagesResponse{Messages: make([]*messagingv1.Message, 0, len(rows))}
	if c := conv.ClearedAt[uid]; !c.IsZero() {
		resp.ClearedAt = timestamppb.New(c)
	}
	for _, r := range rows {
		resp.Messages = append(resp.Messages, messageOf(r, convID, uid))
	}
	return resp
}

// listEpochByTime is ListEpochMessages with order = CREATED_AT, after the flags and the request validation.
//
// The token (epochTimePageBinding, 30 days) holds a position (createdAt, id): a full position resumes after that message;
// a time-only one (sealed with trailDocID, accepted only with a non-zero time) resumes at that time, before every id. Any
// other token is VALIDATION page_token, before any read. Then the participant check (the one NOT_FOUND), then ONE query
// (Repo.ListEpochMessagesByTime): messages of the pair by (createdAt, id) ascending from the position, Limit page_size.
//
// next_page_token (a full page only) is at the last row. resume_page_token is at R = max(request position, min(a, cut)),
// with a = after the last row (the request position on an empty page) and cut = (read time - EpochResumeTrail, before
// every id); positions compare on (createdAt, id) with "" first. resume_settled = (R == a). R is "" only when the request
// had no position and no row came back.
//
// Without the index (ErrOrderIndex) it fails closed: an empty page with order unset, no next or resume token, not settled,
// cleared_at as usual, and one ERROR line epoch_order_fallback=true with the conversation hash and the kind (no uid, no id).
func (s *service) listEpochByTime(ctx context.Context, uid, id, key, tok string, limit int, now time.Time) (*messagingv1.ListEpochMessagesResponse, error) {
	binding := epochTimePageBinding(uid, id, key)
	var after cursor.Cursor
	if tok != "" {
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, binding, tok, now, s.tokenTTL())
		switch {
		case err != nil:
			return nil, invalidPageToken()
		case c.DocID == trailDocID && !c.CreatedAt.IsZero():
			c.DocID = ""
		case !ValidID(c.DocID):
			return nil, invalidPageToken()
		}
		after = c
	}
	conv, err := s.participantConv(ctx, kindEpochMessages, uid, id)
	if err != nil {
		return nil, err
	}
	rows, err := s.d.Repo.ListEpochMessagesByTime(ctx, id, key, after, limit)
	if errors.Is(err, ErrOrderIndex) {
		logger.SetRequestField(ctx, fieldOrderFallback, true)
		logger.SetRequestField(ctx, fieldResults, 0)
		s.d.Log.ErrorContext(ctx, "messaging_"+fieldOrderFallback, slog.Bool(fieldOrderFallback, true),
			slog.String(fieldConvHash, logger.HashConversation(id)), slog.String(fieldKind, kindEpochMessages))
		return epochPage(conv, id, uid, nil), nil
	}
	if err != nil {
		return nil, s.failure(ctx, kindEpochMessages, uid, id, err)
	}
	resp := epochPage(conv, id, uid, rows)
	a := after
	if len(rows) > 0 {
		last := rows[len(rows)-1]
		a = cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}
		if len(rows) == limit {
			resp.NextPageToken = s.sealTimePos(binding, a, now)
		}
	}
	cut := cursor.Cursor{CreatedAt: now.Add(-EpochResumeTrail).Truncate(time.Microsecond)}
	r := maxPos(after, minPos(a, cut))
	resp.ResumeSettled = comparePos(r, a) == 0
	if !cursor.IsFirstPage(r) {
		resp.ResumePageToken = s.sealTimePos(binding, r, now)
	}
	resp.Order = messagingv1.EpochMessageOrder_EPOCH_MESSAGE_ORDER_CREATED_AT
	logger.SetRequestField(ctx, fieldResults, len(rows))
	return resp, nil
}

// sealTimePos seals an order = CREATED_AT position; a time-only one (DocID "") is sealed with trailDocID.
func (s *service) sealTimePos(binding string, p cursor.Cursor, now time.Time) string {
	if p.DocID == "" {
		p.DocID = trailDocID
	}
	return cursor.EncodeAt(s.d.CursorKey, binding, p, now)
}

// comparePos orders two listing positions on (createdAt, id), "" (a time-only position) before every id.
func comparePos(a, b cursor.Cursor) int {
	if c := a.CreatedAt.Compare(b.CreatedAt); c != 0 {
		return c
	}
	return strings.Compare(a.DocID, b.DocID)
}

func minPos(a, b cursor.Cursor) cursor.Cursor {
	if comparePos(a, b) <= 0 {
		return a
	}
	return b
}

func maxPos(a, b cursor.Cursor) cursor.Cursor {
	if comparePos(a, b) >= 0 {
		return a
	}
	return b
}

// deviceIDInvalid is the one VALIDATION device_id answer of ListWelcomes and AckWelcomes: a malformed id and an id that is
// not one of the caller's registered devices get the same bytes.
func deviceIDInvalid() *apierr.Error {
	return apierr.Validation("device_id", "device_id must be one of your registered encryption devices")
}

// ownDevice is the device_id rule of ListWelcomes and AckWelcomes: the format, then one of the caller's REGISTERED devices,
// active or not (Devices.DeviceIDs: one query of at most 5 device documents). A lookup failure is an error, never a
// refusal. It is a filter, not an authentication between the user's own devices (proto "Devices").
func (s *service) ownDevice(ctx context.Context, op, uid, deviceID string) error {
	ids, err := s.d.Devices.DeviceIDs(ctx, uid)
	if err != nil {
		return s.failure(ctx, op, uid, "", fmt.Errorf("messaging: caller devices: %w", err), deviceID)
	}
	for _, d := range ids {
		if d == deviceID {
			return nil
		}
	}
	return deviceIDInvalid()
}

// ListWelcomes implements Service.ListWelcomes.
//
// Validation: device_id's format (VALIDATION device_id), page_size (0 or negative => 10, max 10: welcomesPageSize). Then
// the device check (ownDevice), then ONE query of the caller's own users/{uid}/dmWelcomes where deviceId == device_id in
// welcome-id order (ids are hashes: not time order), Limit page_size. No cursor: acknowledging advances the list; more is true on a full page. The
// path comes from the caller's uid, so another user's welcomes are out of reach, and the deviceId filter keeps the caller's
// other devices' welcomes out. A welcome for a generation the conversation has since left is returned as stored (dropping
// it would cost a conversation read per welcome, beyond the proto's cost): the client ignores a welcome below the current
// generation.
func (s *service) ListWelcomes(ctx context.Context, uid string, req *messagingv1.ListWelcomesRequest) (*messagingv1.ListWelcomesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindListWelcomes)
	dev := req.GetDeviceId()
	if !keys.ValidDeviceID(dev) {
		return nil, deviceIDInvalid()
	}
	limit := welcomesPageSize(req.GetPageSize())
	if s.d.Repo == nil || s.d.Devices == nil {
		return nil, errors.New("messaging: list welcomes is not configured")
	}
	if err := s.ownDevice(ctx, kindListWelcomes, uid, dev); err != nil {
		return nil, err
	}
	rows, err := s.d.Repo.ListWelcomes(ctx, uid, dev, limit)
	if err != nil {
		return nil, s.failure(ctx, kindListWelcomes, uid, "", err, dev)
	}
	resp := &messagingv1.ListWelcomesResponse{Welcomes: make([]*messagingv1.Welcome, 0, len(rows)), More: len(rows) == limit}
	for _, r := range rows {
		resp.Welcomes = append(resp.Welcomes, &messagingv1.Welcome{
			Id: r.ID, ConversationId: r.ConvID, MlsGeneration: wirePair(r.Gen), MlsEpoch: wirePair(r.Epoch),
			Welcome: r.Data, CreatedAt: timestamppb.New(r.CreatedAt),
		})
	}
	logger.SetRequestField(ctx, fieldResults, len(rows))
	logger.SetRequestField(ctx, fieldMore, resp.More)
	return resp, nil
}

// welcomesPageSize is ListWelcomes' page size: 0 or negative => MaxWelcomesPage, at most MaxWelcomesPage.
func welcomesPageSize(n int32) int {
	if n <= 0 || n > MaxWelcomesPage {
		return MaxWelcomesPage
	}
	return int(n)
}

// AckWelcomes implements Service.AckWelcomes.
//
// Validation before any read, in this order: idempotency_key's format (not stored: naturally idempotent); device_id's
// format; ids 1-50, each 32 lower-case hex (VALIDATION ids). Then the device check (ownDevice; device_id does not further
// scope the delete), then one batch deleting users/{uid}/dmWelcomes/{id} for each distinct id, no other read: a missing id
// (acknowledged, replaced, expired, never existed) and another user's id (not under the caller's path) delete nothing, so a
// replay is a success. Refused under DEGRADED_MODE=readonly by the interceptor (a mutation).
func (s *service) AckWelcomes(ctx context.Context, uid string, req *messagingv1.AckWelcomesRequest) (*messagingv1.AckWelcomesResponse, error) {
	if err := s.guard(ctx, uid, notGloballyOff); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldKind, kindAckWelcomes)
	if !idempotency.KeyFormatValid(req.GetIdempotencyKey()) {
		return nil, invalidKey()
	}
	dev := req.GetDeviceId()
	if !keys.ValidDeviceID(dev) {
		return nil, deviceIDInvalid()
	}
	ids, err := validAckIDs(req.GetIds())
	if err != nil {
		return nil, err
	}
	if s.d.Repo == nil || s.d.Devices == nil {
		return nil, errors.New("messaging: ack welcomes is not configured")
	}
	if err := s.ownDevice(ctx, kindAckWelcomes, uid, dev); err != nil {
		return nil, err
	}
	if err := s.d.Repo.AckWelcomes(ctx, uid, ids); err != nil {
		return nil, s.failure(ctx, kindAckWelcomes, uid, "", err, append([]string{dev}, ids...)...)
	}
	logger.SetRequestField(ctx, fieldResults, len(ids))
	return &messagingv1.AckWelcomesResponse{}, nil
}

// validAckIDs checks AckWelcomes ids (1-MaxAckWelcomes, each 32 lower-case hex, else VALIDATION ids) and returns them
// without duplicates, in request order.
func validAckIDs(ids []string) ([]string, error) {
	if len(ids) < 1 || len(ids) > MaxAckWelcomes {
		return nil, apierr.Validation("ids", "ids must be 1-"+strconv.Itoa(MaxAckWelcomes)+" welcome ids")
	}
	seen := make(map[string]struct{}, len(ids))
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if !ValidID(id) {
			return nil, apierr.Validation("ids", "each id must be a welcome id (32 lower-case hex characters)")
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out, nil
}
