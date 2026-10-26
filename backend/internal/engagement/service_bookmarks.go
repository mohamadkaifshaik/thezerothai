// service_bookmarks.go is the business logic of AddBookmark and RemoveBookmark (ADR-0023, ticket W2-3): the
// engagement.Bookmarks seam. Posts are read only through posts.Engagement.Viewable (the GetPost rules, a REPOST id
// resolving to its original); the writes are one BookmarkRepo transaction. No Events: a bookmark is private, nothing
// is published and nobody (least of all the post's author) learns of it.
package engagement

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

var _ Bookmarks = (*Module)(nil)

// AddBookmark implements Bookmarks.
func (m *Module) AddBookmark(ctx context.Context, uid, key, postID string) (BookmarkState, error) {
	return m.s.addBookmark(ctx, uid, key, postID)
}

// RemoveBookmark implements Bookmarks.
func (m *Module) RemoveBookmark(ctx context.Context, uid, key, postID string) (BookmarkState, error) {
	return m.s.removeBookmark(ctx, uid, key, postID)
}

// bookmarkLimitName is the LIMIT_REACHED metadata["limit"] value of the per-user cap.
const bookmarkLimitName = "bookmarks"

// requestHash is the canonical hash of a bookmark request body for IDEMPOTENCY_KEY_REUSED: the post_id as sent
// (never the resolved original, so a REPOST id retried after its original changed visibility is still one request).
func bookmarkRequestHash(postID string) string { return idempotency.HashRequest("post_id=" + postID) }

func (s *service) bookmarkRepoOrErr(uid string) (BookmarkRepo, error) {
	if s.d.BookmarkRepo == nil {
		return nil, logger.RedactErr(errors.New("engagement: bookmarks are not wired (no BookmarkRepo)"), uid)
	}
	return s.d.BookmarkRepo, nil
}

// outcomeContention is the request-line outcome of a bookmark write that kept losing lock races or ran out of its
// transaction time: a retryable UNAVAILABLE, not a server fault (noteRejected maps every UNAVAILABLE of this module to it).
const outcomeContention = "contention"

// bookmarkBusyErr is the retryable answer for a write that exhausted its transaction retries or its 5 s txTimeout
// (W2-14 L-3): UNAVAILABLE, never INTERNAL, so it neither reaches Error Reporting nor counts toward the rollback trigger,
// and clients retry it like graph's contentionErr.
func bookmarkBusyErr() error {
	return apierr.New(connect.CodeUnavailable, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "temporarily busy, please retry").
		WithRetryAfter(time.Second)
}

// mapBookmarkErr turns a BookmarkRepo error into the handler's answer: the cap, the reused key, an already shaped
// apierr (the daily quota) as they are; exhausted contention (Aborted after the bounded re-runs) or the transaction's own
// 5 s timeout as a retryable UNAVAILABLE logged at WARN; a client that left as CANCELED / DEADLINE_EXCEEDED (no server
// fault); anything else a redacted internal error that reaches Error Reporting. The raw uid and post id are redacted from
// that chain (a Firestore error embeds document paths), so a log line cannot link a uid hash to a private bookmark id.
func mapBookmarkErr(ctx context.Context, op, uid, postID string, err error) error {
	var ae *apierr.Error
	switch {
	case errors.Is(err, ErrBookmarkLimit):
		logger.SetRequestField(ctx, "limit", bookmarkLimitName)
		return apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED,
			"bookmark limit reached").WithMeta("limit", bookmarkLimitName)
	case errors.Is(err, ErrIdempotencyKeyReused):
		return apierr.New(connect.CodeInvalidArgument, commonv1.ErrorReason_ERROR_REASON_IDEMPOTENCY_KEY_REUSED,
			"this idempotency_key was already used for a different request")
	case errors.As(err, &ae):
		return err
	}
	// The caller's own context ended (the client left or the RPC deadline passed): not a server fault. Checked before the
	// timeout case, because the transaction's txTimeout is a child context and leaves ctx itself alive.
	switch {
	case errors.Is(ctx.Err(), context.Canceled):
		return apierr.New(connect.CodeCanceled, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "request canceled")
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return apierr.New(connect.CodeDeadlineExceeded, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "deadline exceeded")
	case store.IsContention(err) || errors.Is(err, context.DeadlineExceeded) || status.Code(err) == codes.DeadlineExceeded:
		logger.SetRequestField(ctx, fieldOutcome, outcomeContention)
		slog.WarnContext(ctx, "engagement_bookmark_contention", "op", op, "uid_hash", logger.HashUID(uid))
		return bookmarkBusyErr()
	}
	return logger.RedactErr(fmt.Errorf("engagement: %s: %w", op, err), uid, postID)
}

// noteBookmarkOutcome records the request-line outcome of a BookmarkRepo result.
func noteBookmarkOutcome(ctx context.Context, o BookmarkOutcome) {
	switch o {
	case BookmarkWritten:
		logger.SetRequestField(ctx, fieldOutcome, outcomeDone)
	case BookmarkReplayed:
		logger.SetRequestField(ctx, fieldOutcome, outcomeReplay)
	default:
		logger.SetRequestField(ctx, fieldOutcome, outcomeNoop)
	}
}

// addBookmark implements Bookmarks.AddBookmark (ADR-0023 D4). Before the transaction: the visibility check (3 reads
// cold, 0 warm, +2 for a REPOST id) and the caller's profile for the new-account quota (cache first, 0 extra reads
// behind the account-status interceptor). In the transaction: idempotency, quotas, userLikes.
func (s *service) addBookmark(ctx context.Context, uid, key, postID string) (_ BookmarkState, err error) {
	logger.SetRequestField(ctx, fieldOp, "add_bookmark")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return BookmarkState{}, err
	}
	repo, err := s.bookmarkRepoOrErr(uid)
	if err != nil {
		return BookmarkState{}, err
	}
	target, err := s.resolveViewable(ctx, uid, postID)
	if err != nil {
		return BookmarkState{}, err
	}
	prof, err := s.profile(ctx, uid)
	if err != nil {
		return BookmarkState{}, err
	}
	limit := s.d.BookmarksPerDay
	if s.isNew(prof) {
		limit = s.d.NewAccountBookmarksPerDay
	}
	res, err := repo.Add(ctx, AddBookmarkParams{
		UID: uid, PostID: target.ID, IdemKey: idempotency.Key(uid, rpcAddBookmark, key),
		RequestHash: bookmarkRequestHash(postID), QuotaLimit: limit, MaxPerUser: s.d.BookmarksMaxPerUser,
	})
	if err != nil {
		return BookmarkState{}, mapBookmarkErr(ctx, "add bookmark", uid, postID, err)
	}
	noteBookmarkOutcome(ctx, res.Outcome)
	// A replay says nothing about the set now (the bookmark may have been removed since): the cache is left alone.
	if res.Outcome != BookmarkReplayed {
		id := res.State.PostID
		s.cache.updateBookmarks(uid, func(b []string) []string { return withID(b, id) })
	}
	return res.State, nil
}

// removeBookmark implements Bookmarks.RemoveBookmark: no visibility check and no quota, a user can always remove.
func (s *service) removeBookmark(ctx context.Context, uid, key, postID string) (_ BookmarkState, err error) {
	logger.SetRequestField(ctx, fieldOp, "remove_bookmark")
	defer func() {
		if err != nil {
			noteRejected(ctx, err)
		}
	}()
	if err := validate(key, postID); err != nil {
		return BookmarkState{}, err
	}
	repo, err := s.bookmarkRepoOrErr(uid)
	if err != nil {
		return BookmarkState{}, err
	}
	res, err := repo.Remove(ctx, RemoveBookmarkParams{
		UID: uid, PostID: postID, IdemKey: idempotency.Key(uid, rpcRemoveBookmark, key), RequestHash: bookmarkRequestHash(postID),
	})
	if err != nil {
		return BookmarkState{}, mapBookmarkErr(ctx, "remove bookmark", uid, postID, err)
	}
	noteBookmarkOutcome(ctx, res.Outcome)
	if res.Outcome != BookmarkReplayed {
		s.cache.updateBookmarks(uid, func(b []string) []string { return withoutID(b, postID) })
	}
	return res.State, nil
}
