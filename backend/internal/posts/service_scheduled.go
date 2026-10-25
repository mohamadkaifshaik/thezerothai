// service_scheduled.go is the service layer of scheduled posts (ADR-0021 D4, CMP-D3): SchedulePost, ListScheduledPosts
// and CancelScheduledPost. They touch only users/{caller}/scheduled (plus quotas/{caller} and the caller's media docs
// inside the schedule transaction); another user's id is simply absent from the path built from the token uid, so it is
// NOT_FOUND exactly like an unknown id. The publish sweep (CMP-D4) lives in service_sweep.go.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts/text"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// ScheduledPostsFlagName is the wire name of FEATURE_SCHEDULED_POSTS (ADR-0021 D4). The three RPCs need it AND
// FEATURE_POSTS; GuardFeature runs first.
const ScheduledPostsFlagName = "scheduled_posts"

// Limit names carried in LIMIT_REACHED metadata["limit"].
const (
	limitScheduledPending = "scheduled_pending"
	limitScheduledWindow  = "scheduled_window"
)

// Request-log values of the scheduled RPCs (posts_op and outcome). Never text, ids or times.
const (
	opSchedule       = "schedule"
	opScheduleList   = "schedule_list"
	opScheduleCancel = "schedule_cancel"

	outcomeScheduled = "scheduled"
	outcomeCancelled = "cancelled"
	outcomeUnchanged = "unchanged"

	fieldLimit = "limit"
)

// ScheduleLimits are the plain-value limits of the Scheduler, filled by the wiring from config.Scheduled and
// config.Quota (posts does not import config).
type ScheduleLimits struct {
	// MaxPending is the most PENDING items one user holds (SCHEDULED_MAX_PENDING, soft: the count runs outside the
	// transaction).
	MaxPending int
	// WindowCap is the most PENDING items within +/-ScheduledWindowRadius of a new publish_at
	// (SCHEDULED_PER_AUTHOR_PER_RUN, >= 1). Exact: the count runs inside the schedule transaction.
	WindowCap int
	// MinLead and Horizon bound publish_at: now+MinLead <= publish_at <= now+Horizon.
	MinLead, Horizon time.Duration
	// TerminalTTL is how long a CANCELLED item is kept before the Firestore TTL deletes it (SCHEDULED_TERMINAL_TTL).
	TerminalTTL time.Duration
	// SchedulesPerDay and NewAccountSchedulesPerDay are the SchedulePost calls per IST day (quota.Schedules); the
	// second applies to accounts younger than the service's new-account window.
	SchedulesPerDay, NewAccountSchedulesPerDay int64
}

// ScheduleInput is the SchedulePost request at the domain layer (server.go converts from the proto and makes every
// flag decision; none comes from the request).
type ScheduleInput struct {
	IdempotencyKey string
	Text           string
	MediaIDs       []string
	MediaAltTexts  []string
	// ReplyPolicy is the raw postsv1.ReplyPolicy number; the service validates it (validateReplyPolicy).
	ReplyPolicy     int32
	PaidPartnership bool
	MadeWithAI      bool
	// PublishAt is the requested time; the zero value means the request carried none (or an invalid timestamp).
	PublishAt time.Time

	// MediaEnabled, ReplyAudienceEnabled and DisclosureEnabled are FEATURE_MEDIA, FEATURE_REPLY_AUDIENCE and
	// FEATURE_CONTENT_DISCLOSURE for the caller, exactly as in CreateInput.
	MediaEnabled, ReplyAudienceEnabled, DisclosureEnabled bool
}

// Scheduler is the service the scheduled-post handlers call. The concrete service returned by New implements it;
// server.go gets it through WithScheduler, so Service and its fakes stay unchanged.
type Scheduler interface {
	// Schedule stores a root post to publish at in.PublishAt (truncated to the minute) and returns the stored item,
	// or, for a replayed idempotency key, the stored item of the first call.
	//
	// Firestore, worst case (keep the SchedulePost proto comment and the integration budget assertions in sync):
	//
	//	reads : interceptor 1 (caller users, cached) + scheduled doc 1 + pending count() 1 + quotas 1 + window count() 1
	//	        (both inside the transaction) + media <= 4 = 9. A create that loses a race (AlreadyExists) adds 1 read of
	//	        the winner's doc, and a transaction retry under contention re-reads quotas, the window count and the
	//	        media (up to 6 more per retry)
	//	typical (no media): 5 with a cold interceptor read, 4 of them the service's own; replay 2; at the pending cap 3;
	//	        at the window cap 6 (+ the document of this key: a full window that holds it is a concurrent duplicate,
	//	        answered as a replay); at the daily cap 5 (checked after the window, before the media read)
	//	writes: scheduled doc + quotas.schedules = 2 (replay and every cap: 0); + 1 TTL delete when it reaches a
	//	        terminal state. The posts daily quota is charged at publish, not here.
	//
	// Exact and soft: the window cap (WindowCap items within +/-4 min) and the daily quota are exact, both decided
	// inside the transaction after the quotas read. Every schedule by one user reads and writes quotas/{uid}, so of two
	// racing calls only one commits; the loser is rejected at commit (ABORTED under the OPTIMISTIC mode of dev and prod,
	// a lock wait on the emulator), retries, and counts the winner's committed document. The pending cap is soft: its
	// count() runs outside the transaction (reading up to MaxPending+1 documents inside it would blow the read budget),
	// so concurrent calls can overshoot it by the number in flight, bounded by the daily quota and the rate bucket's
	// burst of 10.
	//
	// Both count() calls are charged to the request's budget.Counter by hand (the store wrappers do not see
	// aggregations). The service's own reads exclude the interceptor's, so a unit budget is one less than above.
	Schedule(ctx context.Context, uid string, in ScheduleInput) (*ScheduledPost, error)
	// ListScheduled returns one page of uid's PENDING and FAILED items, publish_at ascending (page size rule:
	// ScheduledPageSize). Reads 1 + page (minimum 1); writes 0.
	ListScheduled(ctx context.Context, uid string, pageSize int, pageToken string) (ScheduledPage, error)
	// CancelScheduled cancels a PENDING item or dismisses a FAILED one and returns its current state without text or
	// media. An item already PUBLISHED or CANCELLED is returned unchanged with 0 writes. Reads 1 (the interceptor's
	// profile read is extra); writes 1 (0 when already terminal) + 1 TTL delete after SCHEDULED_TERMINAL_TTL.
	CancelScheduled(ctx context.Context, uid, idempotencyKey, scheduledID string) (*ScheduledPost, error)
}

var _ Scheduler = (*service)(nil)

var errNoScheduledRepo = errors.New("posts: scheduled posts are not configured")

// Schedule implements Scheduler. The order is ADR-0021 D4 "SchedulePost order" (security review L-6): flags, shape,
// normalise, replay lookup, THEN the time checks and caps, so a retry that arrives after the lead time has passed or
// after a cap filled still gets its stored item and the client never re-schedules under a new key.
func (s *service) Schedule(ctx context.Context, uid string, in ScheduleInput) (_ *ScheduledPost, err error) {
	logger.SetRequestField(ctx, fieldOp, opSchedule)
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if s.scheduled == nil {
		return nil, errNoScheduledRepo
	}

	// 1. Sub-features, before any validation or read (the CreatePost order: media, reply_audience, disclosure).
	hasMedia := len(in.MediaIDs) > 0 || len(in.MediaAltTexts) > 0
	if hasMedia && !in.MediaEnabled {
		return nil, featureDisabled("media")
	}
	if in.ReplyPolicy != 0 && !in.ReplyAudienceEnabled {
		return nil, featureDisabled("reply_audience")
	}
	if (in.PaidPartnership || in.MadeWithAI) && !in.DisclosureEnabled {
		return nil, featureDisabled("content_disclosure")
	}

	// 2. Shape, 0 reads. A root post only: SchedulePostRequest has no reply, quote or poll field.
	if !idempotency.KeyFormatValid(in.IdempotencyKey) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	policy, err := validateReplyPolicy(CreateInput{ReplyPolicy: in.ReplyPolicy})
	if err != nil {
		return nil, err
	}
	if err := validateMedia(in.MediaIDs, in.MediaAltTexts); err != nil {
		return nil, err
	}
	if in.PublishAt.IsZero() {
		return nil, apierr.Validation("publish_at", "publish_at must be a valid time")
	}
	parse := text.Parse
	if len(in.MediaIDs) > 0 {
		parse = text.ParseOptional // an image-only post is valid
	}
	parsed, err := parse(in.Text)
	if err != nil {
		return nil, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.allowAnonymous, "posting"); err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldTextLen, len([]rune(parsed.Text)))

	// 3. Normalise (pure): publish_at to the whole minute in UTC, the policy to absent for EVERYONE (validateReplyPolicy),
	// the doc id and the request hash from these effective values. Mentions are NOT resolved here: they resolve at
	// publish (handle reads would break the 9-read budget).
	publishAt := in.PublishAt.UTC().Truncate(time.Minute)
	id, err := ScheduledID(uid, in.IdempotencyKey)
	if err != nil {
		return nil, logger.ScrubErr(fmt.Errorf("posts: schedule id: %w", err), uid)
	}
	hash := scheduledRequestHash(parsed.Text, in.MediaIDs, in.MediaAltTexts, policy, in.PaidPartnership, in.MadeWithAI, publishAt)

	// 4. The replay lookup (1 read): the stored item answers a repeat of the key whatever the clock or the caps say.
	stored, err := s.scheduled.GetScheduled(ctx, uid, id)
	switch {
	case err == nil:
		return s.answerStored(ctx, stored, hash)
	case !errors.Is(err, ErrScheduledNotFound):
		return nil, logger.ScrubErr(fmt.Errorf("posts: schedule replay lookup: %w", err), uid)
	}

	// 5. The time bounds, on the stored (truncated) time: that is the minute the item will be published.
	now := s.now()
	if publishAt.Before(now.Add(s.schedule.MinLead)) {
		return nil, apierr.Validation("publish_at", "publish_at is too soon")
	}
	if publishAt.After(now.Add(s.schedule.Horizon)) {
		return nil, apierr.Validation("publish_at", "publish_at is too far ahead")
	}

	// 6. The caps. What is exact and what is soft (ADR-0021 D4, pending.md 2.16):
	//   - The pending cap is SOFT. Its count() runs here, outside the transaction (1 read, charged by the repository),
	//     because reading up to MaxPending+1 documents inside it would blow the read budget. Concurrent calls can overshoot
	//     it by the number in flight, which the exact daily quota (SchedulesPerDay, a transactional counter) and the
	//     CreatePost-shared rate bucket's burst of 10 per instance bound.
	//   - The window cap (WindowCap items within +/-ScheduledWindowRadius) is EXACT. It is not checked here: step 8's
	//     transaction counts the window after reading quotas/{uid}, which every schedule by one user reads and writes, so
	//     of two racing calls only one commits and the rejected one's retry counts the winner's committed document. It
	//     answers ErrScheduledWindowFull.
	pending, err := s.scheduled.CountPending(ctx, uid, s.schedule.MaxPending+1)
	if err != nil {
		return nil, logger.ScrubErr(fmt.Errorf("posts: schedule pending count: %w", err), uid)
	}
	if pending >= int64(s.schedule.MaxPending) {
		return nil, limitReached(ctx, limitScheduledPending, "you have too many scheduled posts; cancel one first")
	}

	// 7. The account age picks the daily quota tier. The profile is the interceptor's cached read (0 extra reads).
	profiles, err := s.directory.GetProfiles(ctx, []string{uid})
	if err != nil {
		return nil, logger.ScrubErr(fmt.Errorf("posts: schedule load author: %w", err), uid)
	}
	author, ok := profiles[uid]
	if !ok {
		return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_PROFILE_REQUIRED, "create a profile first")
	}
	quotaLimit := s.schedule.SchedulesPerDay
	if s.isNewAccount(author, now) {
		quotaLimit = s.schedule.NewAccountSchedulesPerDay
	}

	// 8. The transaction: quotas (1 read), the window count (1 read, the exact window cap), media (<= 4 reads), then
	// Create + quotas.schedules (2 writes).
	created, err := s.scheduled.CreateScheduled(ctx, ScheduledCreateParams{
		UID: uid, ID: id, PublishAt: publishAt, RequestHash: hash, Now: now, QuotaLimit: quotaLimit, WindowCap: s.schedule.WindowCap,
		Draft:    ScheduledDraft{Text: parsed.Text, ReplyPolicy: policy, PaidPartnership: in.PaidPartnership, MadeWithAI: in.MadeWithAI},
		MediaIDs: in.MediaIDs, MediaAlts: in.MediaAltTexts,
	})
	switch {
	case err == nil:
		logger.SetRequestField(ctx, fieldOutcome, outcomeScheduled)
		return created, nil
	case errors.Is(err, ErrScheduledExists):
		// A concurrent first call of the same key won the create: answer from its document (1 read), as in step 4.
		winner, gerr := s.scheduled.GetScheduled(ctx, uid, id)
		if gerr != nil {
			return nil, logger.ScrubErr(fmt.Errorf("posts: schedule concurrent duplicate lookup: %w", gerr), uid)
		}
		return s.answerStored(ctx, winner, hash)
	case errors.Is(err, ErrScheduledWindowFull):
		return nil, limitReached(ctx, limitScheduledWindow, "too many posts are scheduled around that time; pick another time")
	case errors.Is(err, ErrMediaNotReady):
		return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
			"one of the images is not ready; upload it again")
	}
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return nil, err // QUOTA_EXCEEDED quota=schedules and other already-shaped errors
	}
	return nil, logger.ScrubErr(fmt.Errorf("posts: schedule: %w", err), uid)
}

// answerStored answers a repeat of a key from the stored item: the same effective request is a replay (0 writes), a
// different one is IDEMPOTENCY_KEY_REUSED.
func (s *service) answerStored(ctx context.Context, stored *ScheduledPost, hash string) (*ScheduledPost, error) {
	if stored.RequestHash != hash {
		return nil, apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	return stored, nil
}

// scheduledRequestHash is the requestHash of a SchedulePost: the CreatePost canonical body (text, media ids, alt
// texts, policy absent for EVERYONE, both labels) plus the truncated publish time, so the same key with another
// time is IDEMPOTENCY_KEY_REUSED while 10:00:59 and 10:00:00 are the same request. The "sched" prefix keeps it apart
// from a CreatePost hash of the same body.
func scheduledRequestHash(normalisedText string, mediaIDs, alts []string, policy ReplyPolicy, paidPartnership, madeWithAI bool, publishAt time.Time) string {
	base := requestHashBase(normalisedText, "", "", mediaIDs, alts, policy, paidPartnership, madeWithAI)
	return idempotency.HashRequest(fmt.Sprintf("sched|%s|at=%d", base, publishAt.Unix()))
}

// limitReached is FAILED_PRECONDITION + LIMIT_REACHED with metadata["limit"] (the graph module's shape), and notes the
// limit on the request line.
func limitReached(ctx context.Context, limit, message string) error {
	logger.SetRequestField(ctx, fieldLimit, limit)
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED, message).WithMeta("limit", limit)
}

// ListScheduled implements Scheduler: ListScheduledPage with the token bound to uid (HMAC), mapping a bad token to
// VALIDATION field "page_token".
func (s *service) ListScheduled(ctx context.Context, uid string, pageSize int, pageToken string) (ScheduledPage, error) {
	logger.SetRequestField(ctx, fieldOp, opScheduleList)
	if s.scheduled == nil {
		return ScheduledPage{}, errNoScheduledRepo
	}
	page, err := ListScheduledPage(ctx, s.scheduled, s.cursorKey, uid, pageSize, pageToken, s.now())
	if errors.Is(err, ErrInvalidScheduledToken) {
		err = apierr.Validation("page_token", "page_token is invalid or expired")
		noteRejected(ctx, err)
		return ScheduledPage{}, err
	}
	if err != nil {
		noteRejected(ctx, err)
		return ScheduledPage{}, logger.ScrubErr(fmt.Errorf("posts: list scheduled: %w", err), uid)
	}
	return page, nil
}

// CancelScheduled implements Scheduler. Idempotent by state: nothing is stored for the idempotency_key, which is
// only format-checked (ADR-0021 D4, founder-approved rule-4 bend).
func (s *service) CancelScheduled(ctx context.Context, uid, idempotencyKey, scheduledID string) (_ *ScheduledPost, err error) {
	logger.SetRequestField(ctx, fieldOp, opScheduleCancel)
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if s.scheduled == nil {
		return nil, errNoScheduledRepo
	}
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return nil, apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !ValidScheduledID(scheduledID) {
		return nil, apierr.Validation("scheduled_id", "scheduled_id must be 32 lowercase hex characters")
	}
	p, changed, err := s.scheduled.CancelScheduled(ctx, uid, scheduledID, s.now(), s.schedule.TerminalTTL)
	if errors.Is(err, ErrScheduledNotFound) {
		return nil, apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "scheduled post not found")
	}
	if err != nil {
		return nil, logger.ScrubErr(fmt.Errorf("posts: cancel scheduled: %w", err), uid)
	}
	if changed {
		logger.SetRequestField(ctx, fieldOutcome, outcomeCancelled)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeUnchanged)
	}
	p.Draft = nil // the response never carries text or media (the repository already cleared it on a transition)
	return p, nil
}
