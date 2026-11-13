// service_scheduled_edit.go is "Post now" (PublishScheduledPostNow) and "Edit" (UpdateScheduledPost) of scheduled
// posts. Both are idempotent by state, like CancelScheduledPost: the idempotency_key is format-checked, not stored, and
// a repeat finds the state its first call left. Neither adds a stored field, so no index or TTL change.
package posts

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// Request-log values of the two RPCs.
const (
	opSchedulePublishNow = "schedule_publish_now"
	opScheduleUpdate     = "schedule_update"

	outcomePublished = "published"
	outcomeUpdated   = "updated"
)

// UpdateScheduledInput is the UpdateScheduledPost request at the domain layer. A nil pointer means "unchanged".
type UpdateScheduledInput struct {
	IdempotencyKey string
	ScheduledID    string
	Text           *string
	// ReplyPolicy is the raw postsv1.ReplyPolicy number.
	ReplyPolicy *int32
	// PublishAt is the requested time, truncated to the minute. HasPublishAt tells a request that carried publish_at
	// (possibly an invalid timestamp, which leaves PublishAt zero) from one that did not.
	PublishAt    time.Time
	HasPublishAt bool

	// ReplyAudienceEnabled is FEATURE_REPLY_AUDIENCE for the caller.
	ReplyAudienceEnabled bool
}

// ScheduledEditor is the service behind PublishScheduledPostNow and UpdateScheduledPost. The concrete service
// implements it; server.go reaches it through WithScheduledEditor.
type ScheduledEditor interface {
	// PublishScheduledNow publishes uid's PENDING item through the sweep's publish transaction and returns the item as
	// stored afterwards (PUBLISHED, or FAILED when the transaction retired it). An item already PUBLISHED is returned
	// unchanged. mediaEnabled is FEATURE_MEDIA for the caller: an item with images is refused without it, as CreatePost.
	PublishScheduledNow(ctx context.Context, uid, idempotencyKey, scheduledID string, mediaEnabled bool) (*ScheduledPost, error)
	// UpdateScheduled edits a PENDING item. See the proto comment for the rules.
	UpdateScheduled(ctx context.Context, uid string, in UpdateScheduledInput) (*ScheduledPost, error)
}

var _ ScheduledEditor = (*service)(nil)

func notPending(what string) error {
	return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, what).WithMeta("state", "not_pending")
}

func scheduledNotFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "scheduled post not found")
}

func validateKeyAndID(key, id string) error {
	if !idempotency.KeyFormatValid(key) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}
	if !ValidScheduledID(id) {
		return apierr.Validation("scheduled_id", "scheduled_id must be 32 lowercase hex characters")
	}
	return nil
}

// PublishScheduledNow implements ScheduledEditor.
func (s *service) PublishScheduledNow(ctx context.Context, uid, idempotencyKey, scheduledID string, mediaEnabled bool) (_ *ScheduledPost, err error) {
	logger.SetRequestField(ctx, fieldOp, opSchedulePublishNow)
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if s.scheduled == nil || s.sweep.Repo == nil {
		return nil, errNoScheduledRepo
	}
	if err := validateKeyAndID(idempotencyKey, scheduledID); err != nil {
		return nil, err
	}
	if err := authn.RequireVerifiedEmail(ctx, s.allowAnonymous, "posting"); err != nil {
		return nil, err
	}
	// An edit can land between reading the draft and the publish transaction; the transaction then publishes nothing
	// (ExpectUpdateTime) and the draft is read again, once.
	for try := 0; ; try++ {
		cur, err := s.scheduled.GetScheduled(ctx, uid, scheduledID)
		if errors.Is(err, ErrScheduledNotFound) {
			return nil, scheduledNotFound()
		}
		if err != nil {
			return nil, logger.ScrubErr(fmt.Errorf("posts: publish now lookup: %w", err), uid)
		}
		switch cur.Status {
		case ScheduledPublished:
			logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
			return cur, nil
		case ScheduledPending:
		default:
			return nil, notPending("this scheduled post can no longer be published")
		}
		if cur.Draft != nil && len(cur.Draft.Media) > 0 && !mediaEnabled {
			return nil, featureDisabled("media")
		}
		// The sweep's own parse of the draft, minus its lateness bound (an overdue item may still be posted by hand).
		params, ok := s.publishParams(cur)
		if !ok || cur.SchemaVersion > ScheduledSchemaVersion {
			return nil, notPending("this scheduled post cannot be published")
		}
		if err := s.authorizePostText(ctx, uid, params.Draft.Text); err != nil {
			return nil, err
		}
		params.ExpectUpdateTime = cur.UpdateTime
		res, err := s.sweep.Repo.PublishScheduled(ctx, params)
		if err != nil {
			return nil, logger.ScrubErr(fmt.Errorf("posts: publish now: %w", err), uid)
		}
		tally := &sweepTally{res: SweepResult{Failed: map[ScheduledFailure]int{}}}
		s.settle(ctx, cur, res, tally)
		// The stored state is the answer: PUBLISHED (ours, or the sweep's when it won the race), FAILED (the
		// transaction retired it) or anything else, which is a refusal.
		after, err := s.scheduled.GetScheduled(ctx, uid, scheduledID)
		if errors.Is(err, ErrScheduledNotFound) {
			return nil, scheduledNotFound()
		}
		if err != nil {
			return nil, logger.ScrubErr(fmt.Errorf("posts: publish now reload: %w", err), uid)
		}
		switch after.Status {
		case ScheduledPublished:
			if res.Outcome == PublishPublished {
				logger.SetRequestField(ctx, fieldOutcome, outcomePublished)
			} else {
				logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
			}
			return after, nil
		case ScheduledFailed:
			return after, nil
		case ScheduledPending:
			if res.Outcome == PublishNoop && try == 0 {
				continue // edited in between: publish the new draft
			}
		}
		return nil, notPending("this scheduled post can no longer be published")
	}
}

// UpdateScheduled implements ScheduledEditor.
func (s *service) UpdateScheduled(ctx context.Context, uid string, in UpdateScheduledInput) (_ *ScheduledPost, err error) {
	logger.SetRequestField(ctx, fieldOp, opScheduleUpdate)
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if s.scheduled == nil {
		return nil, errNoScheduledRepo
	}
	// 1. Sub-feature, before validation (the CreatePost order).
	if in.ReplyPolicy != nil && *in.ReplyPolicy != 0 && !in.ReplyAudienceEnabled {
		return nil, featureDisabled("reply_audience")
	}
	// 2. Shape.
	if err := validateKeyAndID(in.IdempotencyKey, in.ScheduledID); err != nil {
		return nil, err
	}
	if in.Text == nil && in.ReplyPolicy == nil && !in.HasPublishAt {
		return nil, apierr.Validation("scheduled_id", "set at least one of text, publish_at and reply_policy")
	}
	var policy *ReplyPolicy
	if in.ReplyPolicy != nil {
		p, perr := validateReplyPolicy(CreateInput{ReplyPolicy: *in.ReplyPolicy})
		if perr != nil {
			return nil, perr
		}
		policy = &p
	}
	var publishAt *time.Time
	if in.HasPublishAt {
		if in.PublishAt.IsZero() {
			return nil, apierr.Validation("publish_at", "publish_at must be a valid time")
		}
		t := in.PublishAt.UTC().Truncate(time.Minute)
		publishAt = &t
	}
	if err := authn.RequireVerifiedEmail(ctx, s.allowAnonymous, "posting"); err != nil {
		return nil, err
	}
	// 3. The stored item decides how the text is parsed (an image-only post may have empty text).
	cur, err := s.scheduled.GetScheduled(ctx, uid, in.ScheduledID)
	if errors.Is(err, ErrScheduledNotFound) {
		return nil, scheduledNotFound()
	}
	if err != nil {
		return nil, logger.ScrubErr(fmt.Errorf("posts: update scheduled lookup: %w", err), uid)
	}
	// The time bounds apply to a real move only: an edit that repeats the stored minute is a replay and must still answer
	// from state after the lead time has passed (the SchedulePost order, review L-6).
	if publishAt != nil && !publishAt.Equal(cur.PublishAt) {
		now := s.now()
		if publishAt.Before(now.Add(s.schedule.MinLead)) {
			return nil, apierr.Validation("publish_at", "publish_at is too soon")
		}
		if publishAt.After(now.Add(s.schedule.Horizon)) {
			return nil, apierr.Validation("publish_at", "publish_at is too far ahead")
		}
	}
	var newText *string
	if in.Text != nil {
		parsed, perr := s.parsePostText(*in.Text, cur.Draft != nil && len(cur.Draft.Media) > 0)
		if perr != nil {
			return nil, perr
		}
		logger.SetRequestField(ctx, fieldTextLen, len([]rune(parsed.Text)))
		if cur.Draft == nil || parsed.Text != cur.Draft.Text {
			if err := s.authorizePostText(ctx, uid, parsed.Text); err != nil {
				return nil, err
			}
		}
		newText = &parsed.Text
	}
	// 4. The transaction re-reads the item: state, the 60 s lockout, the window cap, then the write.
	out, changed, err := s.scheduled.UpdateScheduled(ctx, ScheduledUpdateParams{
		UID: uid, ID: in.ScheduledID, Text: newText, ReplyPolicy: policy, PublishAt: publishAt,
		Now: s.now(), WindowCap: s.schedule.WindowCap,
	})
	switch {
	case err == nil:
	case errors.Is(err, ErrScheduledNotFound):
		return nil, scheduledNotFound()
	case errors.Is(err, ErrScheduledNotPending):
		return nil, notPending("only a pending scheduled post can be edited")
	case errors.Is(err, ErrScheduledLocked):
		return nil, apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED,
			"this post is about to be published and can no longer be edited").WithMeta("state", "locked")
	case errors.Is(err, ErrScheduledWindowFull):
		return nil, limitReached(ctx, limitScheduledWindow, "too many posts are scheduled around that time; pick another time")
	default:
		var ae *apierr.Error
		if errors.As(err, &ae) {
			return nil, err
		}
		return nil, logger.ScrubErr(fmt.Errorf("posts: update scheduled: %w", err), uid)
	}
	if changed {
		logger.SetRequestField(ctx, fieldOutcome, outcomeUpdated)
	} else {
		logger.SetRequestField(ctx, fieldOutcome, outcomeUnchanged)
	}
	return out, nil
}
