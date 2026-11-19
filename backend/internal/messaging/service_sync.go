package messaging

// The MLS sync RPCs of an encrypted conversation: ListConversationCommits, ListEpochMessages, ListWelcomes and AckWelcomes
// (proto, each RPC comment), and the reset cap of CommitConversation. Flag: "messaging" not globally off for all four
// (a caller dropped from the allowlist keeps catching up); e2ee_dm is never needed. Request lines carry counts and enums
// only: never commit, welcome or message bytes, a device id or a uid.

import (
	"context"
	"errors"
	"fmt"
	"strconv"

	"google.golang.org/protobuf/types/known/timestamppb"

	messagingv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/messaging/v1"
	"github.com/dzeroth/dzeroth/backend/internal/keys"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/cursor"
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

	// limitResetsDaily is the limit name of the CommitConversation reset cap (Limits.ResetsPerDay).
	limitResetsDaily = "messages_resets_daily"

	// maxDocPart is the largest generation or epoch commitDocID writes in its 10 zero-padded digits (so ids sort by pair).
	// A stored pair never comes near it (10^10 commits or resets); an after-pair beyond it is clamped (commitsAfterID).
	maxDocPart = 9_999_999_999
	// afterEverything sorts after every commit document id (all digits and "_"): StartAfter it reads nothing.
	afterEverything = "~"
)

// resetCap draws on the CommitConversation reset cap ("messages_resets_daily", MESSAGES_RESETS_PER_DAY) for a call with
// reset = true, before anything else of the service runs: like the interceptor's per-call cap "messages_commits_daily",
// which every call (a reset included) has already drawn on, it counts every reset call, a recognised retry and a refused one
// included. A refusal is RATE_LIMITED with metadata["limit"] = "messages_resets_daily" and retry_after the next IST day.
func (s *service) resetCap(ctx context.Context, uid string, req *messagingv1.CommitConversationRequest) error {
	if !req.GetReset_() || s.resets == nil || s.resets.Allow(uid) {
		return nil
	}
	return s.resets.ExceededError(ctx, limitResetsDaily)
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

// ListEpochMessages implements Service.ListEpochMessages.
//
// Validation before any read, in this order: conversation_id; mls_generation >= 1; mls_epoch >= 1; page_size (0 => 20, max
// 50); the page token (sealed, bound to caller, conversation and pair, 30 days: a foreign, tampered, expired or other-pair
// token is VALIDATION page_token). Then the participant check through the 60 s instance copy (the one NOT_FOUND), then ONE
// query: messages where mlsKey == "gen:epoch" in document-id order after the token's id, Limit page_size. The query runs
// even when the cached copy says NONE (it can be 60 s stale, and an empty answer reads as "complete"). Messages at or
// before the caller's clearedAt ARE returned (completeness counting; the client skips them), with the same mapping as
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
	binding := epochPageBinding(uid, id, key)
	now := s.d.Now()
	var after string
	if tok := req.GetPageToken(); tok != "" {
		c, err := cursor.DecodeAtTTL(s.d.CursorKey, binding, tok, now, s.tokenTTL())
		if err != nil || !ValidID(c.DocID) {
			return nil, apierr.Validation("page_token", "invalid or expired page_token")
		}
		after = c.DocID
	}
	logger.SetRequestField(ctx, fieldConvHash, logger.HashConversation(id))
	conv, hit, err := s.conversationHit(ctx, uid, id)
	logger.SetRequestField(ctx, fieldCacheHit, hit)
	if err == nil && peerOf(conv.Participants, uid) == "" {
		err = ErrNotFound
	}
	if err != nil {
		return nil, s.failure(ctx, kindEpochMessages, uid, id, err)
	}
	rows, err := s.d.Repo.ListEpochMessages(ctx, id, key, after, limit)
	if err != nil {
		return nil, s.failure(ctx, kindEpochMessages, uid, id, err)
	}
	resp := &messagingv1.ListEpochMessagesResponse{Messages: make([]*messagingv1.Message, 0, len(rows))}
	for _, r := range rows {
		resp.Messages = append(resp.Messages, messageOf(r, id, uid))
	}
	if len(rows) == limit {
		last := rows[len(rows)-1]
		resp.NextPageToken = cursor.EncodeAt(s.d.CursorKey, binding, cursor.Cursor{CreatedAt: last.CreatedAt, DocID: last.ID}, now)
	}
	logger.SetRequestField(ctx, fieldResults, len(rows))
	return resp, nil
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
// Validation: device_id's format (VALIDATION device_id), page_size (0 => 20, max 50). Then the device check (ownDevice),
// then ONE query of the caller's own users/{uid}/dmWelcomes where deviceId == device_id in welcome-id order (ids are
// hashes: not time order), Limit page_size. No cursor: acknowledging advances the list; more is true on a full page. The
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
	limit := clampPageSize(req.GetPageSize())
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
