// service_shares.go is RecordPostShare and the Shares seam (shares design 2026-11-13, D4-D6): one postShares/{postId}_{uid}
// marker per account per post, for direct-message and outside shares together, and posts/{id}.shareCount moved by
// FieldValue.Increment in the same batch (the like pattern). The marker is the idempotency record (the like rule): the
// idempotency_key is validated but not stored. The author's own shares are never counted.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// Request-line values of record_share. Never a uid; the post is the keyed post_hash.
const (
	fieldShareChannel  = "share_channel"
	outcomeCounted     = "counted"
	outcomeShareExists = "exists"
	outcomeProtected   = "protected_author"
	outcomeOwnPost     = "own_post"
)

// shareRetryAfter is the retry_after of a share that kept losing the hot post's counter race: the client drops it.
const shareRetryAfter = time.Second

var (
	_ PostShares = (*Module)(nil)
	_ Shares     = (*Module)(nil)
)

// RecordShare implements PostShares.
func (m *Module) RecordShare(ctx context.Context, uid, key, postID, channel string) (ShareResult, error) {
	return m.s.recordShare(ctx, uid, key, postID, channel)
}

// Record implements Shares.
func (m *Module) Record(ctx context.Context, uid, postID string) (bool, error) {
	return m.s.recordDMShare(ctx, uid, postID)
}

// recordShare implements PostShares.RecordShare. The flag gate ran in the handler; every refusal writes nothing.
func (s *service) recordShare(ctx context.Context, uid, key, postID, channel string) (_ ShareResult, err error) {
	logger.SetRequestField(ctx, fieldOp, "record_share")
	logger.SetRequestField(ctx, fieldShareChannel, channel)
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	// Step 3: shape, before any lookup.
	if err := validate(key, postID); err != nil {
		return ShareResult{}, err
	}
	if channel == "" {
		return ShareResult{}, apierr.Validation("channel", "channel must be COPY_LINK or SHARE_SHEET")
	}
	if err := authn.RequireVerifiedEmail(ctx, s.d.AllowAnonymous, "sharing posts"); err != nil {
		return ShareResult{}, err
	}
	logger.SetRequestField(ctx, fieldPostHash, logger.HashPost(postID))
	// Step 4: the GetPost rules; a REPOST id records a share of its original.
	target, err := s.resolveViewable(ctx, uid, postID)
	if err != nil {
		return ShareResult{}, err
	}
	noop := func(outcome string) (ShareResult, error) {
		logger.SetRequestField(ctx, fieldOutcome, outcome)
		return ShareResult{Result: s.result(ctx, uid, target, 0, 0)}, nil
	}
	// Step 5: the author's own share is never counted. Checked before the protected rule: a protected author may share
	// their own post, and it is not counted either way.
	if target.AuthorID == uid {
		return noop(outcomeOwnPost)
	}
	// Step 4, protected authors: a follower who can see the post may copy its link (it opens only for followers), but the
	// share is not counted. RefuseShare answers PROTECTED_ACCOUNT for exactly that case; any other error is its own.
	if rerr := s.d.Posts.RefuseShare(ctx, uid, target); rerr != nil {
		var ae *apierr.Error
		if errors.As(rerr, &ae) && ae.Reason == commonv1.ErrorReason_ERROR_REASON_PROTECTED_ACCOUNT {
			return noop(outcomeProtected)
		}
		return ShareResult{}, rerr
	}
	if s.d.ShareRepo == nil {
		return ShareResult{}, errors.New("engagement: no share repo configured")
	}
	// Step 6: the marker read, then on a first share the batch.
	counted, err := s.writeShare(ctx, uid, target.ID)
	if err != nil {
		return ShareResult{}, s.mapShareErr(ctx, uid, target.ID, err)
	}
	if !counted {
		return noop(outcomeShareExists)
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeCounted)
	out := ShareResult{Result: s.result(ctx, uid, target, 0, 0), Counted: true}
	out.ShareCount++ // this call's own marker, on top of the post as read
	return out, nil
}

// errSharePostGone is writeShare's answer for a post deleted between the visibility check and the commit.
var errSharePostGone = errors.New("engagement: shared post no longer exists")

// writeShare is the marker read and, when absent, the batch. counted is true only when this call created the marker (a
// concurrent first share that loses the Create commits nothing, so the count moves once). The instance post cache follows a
// committed marker. The batch runs on a context detached from the caller's cancellation and bounded by txTimeout: a commit
// that lands must be reflected in the cache.
func (s *service) writeShare(ctx context.Context, uid, postID string) (bool, error) {
	exists, err := s.d.ShareRepo.HasShare(ctx, uid, postID)
	if err != nil {
		return false, err
	}
	if exists {
		return false, nil
	}
	wctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), txTimeout)
	defer cancel()
	out, err := s.d.ShareRepo.CreateShare(wctx, uid, postID)
	if err != nil {
		return false, err
	}
	switch out {
	case ShareCreated:
		s.d.Posts.SharesChanged(postID, 1)
		return true, nil
	case SharePostGone:
		return false, errSharePostGone
	default:
		return false, nil
	}
}

// mapShareErr turns a share write error into the wire answer: a post deleted mid-way is the one NOT_FOUND; a caller that
// left is a client outcome; exhausted contention on a hot post's counter or the batch's own timeout is UNAVAILABLE with
// retry_after (the client drops it); anything else is a redacted internal error.
func (s *service) mapShareErr(ctx context.Context, uid, postID string, err error) error {
	switch {
	case errors.Is(err, errSharePostGone):
		return notFound()
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case errors.Is(err, store.ErrContended) || store.IsContention(err) || errors.Is(err, context.DeadlineExceeded):
		logger.SetRequestField(ctx, fieldContention, true)
		slog.WarnContext(ctx, "share_record_contention", "post_hash", logger.HashPost(postID))
		return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "busy, please retry").WithRetryAfter(shareRetryAfter)
	}
	return logger.RedactErrPosts(fmt.Errorf("engagement: record share: %w", err), []string{postID}, uid)
}

// shareCountGloballyOff reports FEATURE_SHARE_COUNT as the kill switch. A checker without GloballyOff, or none, reads
// as off, so a wiring gap records nothing rather than everything.
func (s *service) shareCountGloballyOff() bool {
	g, ok := s.d.Flags.(posts.GloballyOffChecker)
	return !ok || g.GloballyOff(ShareFlagName)
}

// recordDMShare implements Shares.Record. The sender's visibility and the protected-author rule were decided by messaging
// before the send; this records the marker only. Every error is returned for the caller to log: the message is already
// committed.
func (s *service) recordDMShare(ctx context.Context, uid, postID string) (bool, error) {
	if s.d.ShareRepo == nil || s.shareCountGloballyOff() {
		return false, nil
	}
	if !ids.ValidPostID(postID) {
		return false, errors.New("engagement: record share: invalid post id")
	}
	p, err := s.d.Reader.Get(ctx, postID)
	if errors.Is(err, posts.ErrNotFound) {
		return false, nil // deleted since the send: nothing to count
	}
	if err != nil {
		return false, logger.RedactErrPosts(fmt.Errorf("engagement: record share: load post: %w", err), []string{postID}, uid)
	}
	if p.AuthorID == uid || p.Kind == posts.KindRepost {
		return false, nil // the author's own share is never counted; messaging always passes the original
	}
	counted, err := s.writeShare(ctx, uid, p.ID)
	if errors.Is(err, errSharePostGone) {
		return false, nil
	}
	if err != nil {
		return false, logger.RedactErrPosts(fmt.Errorf("engagement: record share: %w", err), []string{postID}, uid)
	}
	return counted, nil
}
