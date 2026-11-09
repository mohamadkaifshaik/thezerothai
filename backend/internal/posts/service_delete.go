package posts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/outbox"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

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
	if !ids.ValidPostID(id) {
		return apierr.Validation("post_id", "post_id must be a 19-digit post id")
	}
	return nil
}

// postNotFound is the one NOT_FOUND answer GetPost gives for a missing, deleted or hidden post: the same code,
// reason and message bytes in every case, so a caller cannot tell the causes apart.
func postNotFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, postNotFoundText)
}

// Delete implements Service.
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

	var stage []func(store.Batch)
	if p.Kind == KindRepost && p.RepostOfID != "" && s.links != nil {
		// Deleting a REPOST is an undo: its reposts doc goes in the same batch (blind; the post's own Exists
		// precondition is the batch's only guard).
		stage = append(stage, func(b store.Batch) { s.links.StageRelease(b, p.RepostOfID, uid) })
	}
	// The post_delete outbox item rides the same batch, so it exists exactly when the delete committed.
	work, durable, err := s.postDeleteEntry(uid, p)
	if err != nil {
		// Never fails the delete: it falls back to the best-effort publish (ERROR on a lost publish, as before).
		slog.ErrorContext(ctx, "post_delete_outbox_entry_invalid", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, uid))}, logger.TraceAttrs(ctx)...)...)
		durable = false
	}
	var stageErr error
	if durable {
		stage = append(stage, func(b store.Batch) { stageErr = s.outbox.Stage(b, work) })
	}
	deleted, err := s.repo.DeleteOwn(ctx, postID, uid, stage...)
	if err == nil && stageErr != nil {
		// Unreachable (the entry was validated above and Stage's only error is validation); logged, never silent.
		slog.ErrorContext(ctx, "post_delete_outbox_stage_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(stageErr, uid))}, logger.TraceAttrs(ctx)...)...)
		durable = false
	}
	if err != nil {
		return logger.RedactErr(fmt.Errorf("posts: delete: %w", err), uid)
	}
	// The post is gone either way (a concurrent delete won when !deleted): drop it from this instance's caches.
	s.cache.RemoveOwn(uid, postID)
	if !deleted {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
		return nil
	}
	s.directory.Forget(uid) // users.postsCount changed by a blind increment
	s.releaseParent(ctx, p)
	s.releaseEngagement(ctx, p)
	s.events.Deleted(ctx, postID, uid)
	s.publishPostDelete(ctx, uid, p, work, durable)
	logger.SetRequestField(ctx, fieldOutcome, outcomeDeleted)
	return nil
}

// postDeleteEntry is the outbox entry of p's post_delete job, and whether DeletePost stages one (only when both the
// outbox and the publisher are wired: an item nobody can publish would only wait for its TTL).
func (s *service) postDeleteEntry(uid string, p *Post) (outbox.Entry, bool, error) {
	if s.outbox == nil || s.jobs == nil {
		return outbox.Entry{}, false, nil
	}
	e, err := PostDeleteEntry(uid, p.ID, mediaIDsOf(p))
	if err != nil {
		return outbox.Entry{}, false, err
	}
	return e, true, nil
}

func mediaIDsOf(p *Post) []string {
	ids := make([]string, len(p.Media))
	for i, m := range p.Media {
		ids[i] = m.ID
	}
	return ids
}

// publishPostDelete hands a deleted post to the post_delete job (after the commit, never inside it): its images
// and its likes, reposts and quotes, so every deleted post publishes. A failure does not fail the delete: the post is
// gone. With the outbox wired (durable) the staged item stays and the outbox sweep republishes it, so a failure is a
// WARN; without it the dependants wait for the account purge, so it is an ERROR. One Pub/Sub publish, then (durable and
// published) one delete of the outbox item.
func (s *service) publishPostDelete(ctx context.Context, uid string, p *Post, work outbox.Entry, durable bool) {
	if s.jobs == nil {
		return
	}
	if err := s.jobs.PostDeleted(ctx, uid, p.ID, mediaIDsOf(p)); err != nil {
		logger.SetRequestField(ctx, fieldMediaJob, "publish_failed")
		attrs := append([]any{"error", logger.CauseChain(logger.ScrubErr(err, uid))}, logger.TraceAttrs(ctx)...)
		if durable {
			slog.WarnContext(ctx, "post_delete_job_publish_deferred", attrs...)
			return
		}
		slog.ErrorContext(ctx, "post_delete_job_publish_failed", attrs...)
		return
	}
	logger.SetRequestField(ctx, fieldMediaJob, "published")
	if !durable {
		return
	}
	if err := s.outbox.Done(ctx, work); err != nil {
		// The job was published; a sweep publishes it again, and every post_delete step is idempotent.
		slog.WarnContext(ctx, "post_delete_outbox_done_failed", append([]any{"error", logger.CauseChain(logger.ScrubErr(err, uid))}, logger.TraceAttrs(ctx)...)...)
	}
}

// GetForViewer implements Service.
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
	p, err := s.viewable(ctx, callerUID, postID)
	if errors.Is(err, ErrNotFound) {
		return nil, s.notFound(ctx)
	}
	if err != nil {
		return nil, err
	}
	logger.SetRequestField(ctx, fieldOutcome, outcomeFound)
	return p, nil
}

// viewable is the GetPost visibility rule set shared by GetPost, GetThread's focal post and CreatePost's reply
// parent: it returns the post, or ErrNotFound for a missing, deleted, hidden, blocked-author or
// non-ACTIVE-author post (callers map that to the one NOT_FOUND answer), or a redacted internal error. It sets
// no request-log fields. A caller who blocked or muted the author still gets the post.
func (s *service) viewable(ctx context.Context, callerUID, postID string) (*Post, error) {
	p, err := s.Get(ctx, postID)
	if errors.Is(err, ErrNotFound) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: get: load post: %w", err), callerUID)
	}

	// A post a moderator hid (takedown or suspension) is NOT_FOUND for everyone, the author included.
	// Checked first: it is free (the field arrived with the document).
	if p.Hidden() {
		return nil, ErrNotFound
	}

	profiles, err := s.directory.GetProfiles(ctx, []string{p.AuthorID})
	if err != nil {
		return nil, logger.RedactErr(fmt.Errorf("posts: get: load author: %w", err), callerUID, p.AuthorID)
	}
	// GetProfiles omits SUSPENDED, DELETING and missing authors alike.
	if _, ok := profiles[p.AuthorID]; !ok {
		return nil, ErrNotFound
	}

	// A QUOTE or REPOST also carries a frozen copy of another user's post: when that author blocks the caller
	// the copy must not leak their content, so the whole post is NOT_FOUND; when that author is
	// protected and the caller may not see them a REPOST is NOT_FOUND and a QUOTE is shown with its
	// copy stripped (ApplyEmbedState). The block check exempts the caller's own copies and tombstones (no author);
	// the protected check exempts neither the caller's own copy nor anything else, but costs a graph read only for
	// a caller's own REPOST/QUOTE of someone else's post while a protected-set loader is wired.
	embAuthor := p.EmbeddedAuthor()
	needSnap := p.AuthorID != callerUID || (s.aud.Enabled() && embAuthor != "" && embAuthor != callerUID)

	var snap graph.Snapshot
	if needSnap {
		snap, err = s.graph.Snapshot(ctx, callerUID)
		if err != nil {
			return nil, logger.RedactErr(fmt.Errorf("posts: get: load caller graph: %w", err), callerUID, p.AuthorID)
		}
	}
	// Block, then the one visibility predicate. Never the stored visibility, which is always PUBLIC.
	d, err := s.aud.Decide(ctx, callerUID, snap, p, SurfaceDirect)
	if err != nil {
		return nil, s.audienceErr(err, callerUID, p.AuthorID)
	}
	if d.Verdict != Show {
		return nil, ErrNotFound
	}
	return p, nil
}

// audienceErr passes an apierr (UNAVAILABLE from the protected set, or a graph error already redacted) through.
func (s *service) audienceErr(err error, uids ...string) error {
	var ae *apierr.Error
	if errors.As(err, &ae) {
		return err
	}
	return logger.RedactErr(err, uids...)
}

// blockedBy reports whether other blocks the caller: the caller's blockedBy set, or, once that set overflowed its
// cap, other's own graph doc.
func (s *service) blockedBy(ctx context.Context, snap graph.Snapshot, callerUID, other string) (bool, error) {
	if snap.BlockedBy[other] {
		return true, nil
	}
	if !snap.BlockedByOverflow {
		return false, nil
	}
	os, err := s.graph.Snapshot(ctx, other)
	if err != nil {
		return false, logger.RedactErr(fmt.Errorf("posts: get: load author graph: %w", err), callerUID, other)
	}
	return os.Blocked[callerUID], nil
}

func isPostNotFound(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Code == connect.CodeNotFound && ae.Message == postNotFoundText
}

func (s *service) notFound(ctx context.Context) error {
	logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
	return postNotFound()
}
