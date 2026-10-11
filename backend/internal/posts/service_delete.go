package posts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// postIDPattern is the post id shape (19-digit zero-padded Snowflake decimal, ADR-0010 D18).
var postIDPattern = regexp.MustCompile(`^[0-9]{19}$`)

// outcomes of DeletePost (posts_op=delete) and GetPost (posts_op=get).
const (
	outcomeDeleted    = "deleted"
	outcomeNoop       = "noop"
	outcomeNoopNotOwn = "noop:not_owner"
	outcomeFound      = "found"
	outcomeNotFound   = "not_found"
	postNotFoundText  = "post not found"
)

func validatePostID(id string) error {
	if !postIDPattern.MatchString(id) {
		return apierr.Validation("post_id", "post_id must be a 19-digit post id")
	}
	return nil
}

// postNotFound is the one NOT_FOUND answer GetPost gives for a missing, deleted or hidden post: the same code,
// reason and message bytes in every case, so a caller cannot tell the causes apart (ADR-0010 D6).
func postNotFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, postNotFoundText)
}

// Delete implements Service (ADR-0010 D4, plan T9).
//
// Firestore, worst case: reads 1 (the post; 0 when cached; the interceptor's profile read is extra), writes 1
// (users.postsCount -1) + 1 delete (Exists precondition) and, for a post with images, one Pub/Sub publish of the
// post_delete job (the objects and media/* docs are removed there: len(media) reads + 1 post read, len(media)
// deletes, asynchronously). Every other case, including another user's post, an
// unknown id and an already-deleted one, is success with 1 read at most and 0 writes.
func (s *service) Delete(ctx context.Context, uid, idempotencyKey, postID string) (err error) {
	logger.SetRequestField(ctx, fieldOp, "delete")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validatePostID(postID); err != nil {
		return err
	}
	// The key is validated for format only: the operation is state-setting, so a replay needs no stored record.
	if !idempotency.KeyFormatValid(idempotencyKey) {
		return apierr.Validation("idempotency_key", "idempotency_key must be 16-64 characters of [A-Za-z0-9_-]")
	}

	p, err := s.Get(ctx, postID)
	switch {
	case errors.Is(err, ErrNotFound):
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
		return nil
	case err != nil:
		return logger.RedactErr(fmt.Errorf("posts: delete: load post: %w", err), uid)
	}
	if p.AuthorID != uid {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoopNotOwn)
		return nil
	}

	deleted, err := s.repo.DeleteOwn(ctx, postID, uid)
	if err != nil {
		return logger.RedactErr(fmt.Errorf("posts: delete: %w", err), uid)
	}
	// The post is gone either way (a concurrent delete won when !deleted): drop it from this instance's caches.
	s.cache.RemoveOwn(uid, postID)
	if !deleted {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
		return nil
	}
	s.directory.Forget(uid) // users.postsCount changed by a blind increment (ADR-0008 B2)
	s.events.Deleted(ctx, postID, uid)
	s.publishPostDelete(ctx, uid, p)
	logger.SetRequestField(ctx, fieldOutcome, outcomeDeleted)
	return nil
}

// publishPostDelete hands a deleted post's images to the post_delete job (after the commit, never inside it). A failure
// is logged for Error Reporting and does not fail the delete: the post is gone and the objects are removed by the
// account purge at the latest. One Pub/Sub publish, no Firestore access.
func (s *service) publishPostDelete(ctx context.Context, uid string, p *Post) {
	if s.jobs == nil || len(p.Media) == 0 {
		return
	}
	ids := make([]string, len(p.Media))
	for i, m := range p.Media {
		ids[i] = m.ID
	}
	if err := s.jobs.PostDeleted(ctx, uid, p.ID, ids); err != nil {
		logger.SetRequestField(ctx, fieldMediaJob, "publish_failed")
		slog.ErrorContext(ctx, "post_delete_job_publish_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, uid))}, logger.TraceAttrs(ctx)...)...)
		return
	}
	logger.SetRequestField(ctx, fieldMediaJob, "published")
}

// GetForViewer implements Service (ADR-0010 D6 GetPost column, plan T9).
//
// Firestore, worst case: post 1 + author users 1 + caller graph 1 cold (the caller's own users read belongs to
// the account-status interceptor) = 3 here, 4 per request; +1 author graph when the caller's blockedBy
// overflowed; 0 warm; writes 0. Filters use graph.Reader.Snapshot only (ADR-0008 D9).
func (s *service) GetForViewer(ctx context.Context, callerUID, postID string) (_ *Post, err error) {
	logger.SetRequestField(ctx, fieldOp, "get")
	defer func() {
		// not_found already set its own outcome (s.notFound); everything else is rejected:<reason>.
		if err != nil && !isPostNotFound(err) {
			noteRejected(ctx, err)
		}
	}()
	if err := validatePostID(postID); err != nil {
		return nil, err
	}
	p, err := s.Get(ctx, postID)
	if errors.Is(err, ErrNotFound) {
		return nil, s.notFound(ctx)
	}
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: get: load post: %w", err), callerUID)
	}

	profiles, err := s.directory.GetProfiles(ctx, []string{p.AuthorID})
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: get: load author: %w", err), callerUID, p.AuthorID)
	}
	// GetProfiles omits SUSPENDED, DELETING and missing authors alike.
	if _, ok := profiles[p.AuthorID]; !ok {
		return nil, s.notFound(ctx)
	}

	if p.AuthorID != callerUID {
		snap, err := s.graph.Snapshot(ctx, callerUID)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("posts: get: load caller graph: %w", err), callerUID, p.AuthorID)
		}
		if snap.BlockedBy[p.AuthorID] {
			return nil, s.notFound(ctx)
		}
		if snap.BlockedByOverflow {
			// The caller's blockedBy stopped growing at its cap, so also ask the author's own graph.
			as, err := s.graph.Snapshot(ctx, p.AuthorID)
			if err != nil {
				return nil, logger.RedactErr(fmt.Errorf("posts: get: load author graph: %w", err), callerUID, p.AuthorID)
			}
			if as.Blocked[callerUID] {
				return nil, s.notFound(ctx)
			}
		}
		// Follower-only posts need an accepted follow; P1 writes only public posts, so this fails closed.
		if p.Visibility != VisibilityPublic && !snap.Following[p.AuthorID] {
			return nil, s.notFound(ctx)
		}
	}
	// A caller who blocked or muted the author still gets the post (the client shows the banner).
	logger.SetRequestField(ctx, fieldOutcome, outcomeFound)
	return p, nil
}

func isPostNotFound(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Code == connect.CodeNotFound && ae.Message == postNotFoundText
}

func (s *service) notFound(ctx context.Context) error {
	logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
	return postNotFound()
}
