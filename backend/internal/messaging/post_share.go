// post_share.go is messaging's side of sharing a post in a direct message (shares design 2026-11-13, D1-D3, D6): the
// shared_post_id rules of SendMessage, the per-reader card of ListMessages and the after-commit share record. messaging
// imports neither posts nor engagement: the three seams below are adapted in apiserver.
package messaging

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"connectrpc.com/connect"

	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

// PostShareFlagName is the wire name of FEATURE_DM_POST_SHARE: SendMessageRequest.shared_post_id needs it on for the caller;
// while it is globally off every Message.shared_post is the unavailable form.
const PostShareFlagName = "dm_post_share"

// postsFlagName is the wire name of FEATURE_POSTS (posts.FlagName; messaging does not import posts): a share needs it on
// for the caller too.
const postsFlagName = "posts"

// shareRecordTimeout bounds the after-commit share record, which runs on a context detached from the request.
const shareRecordTimeout = 3 * time.Second

// postNotFoundText is GetPost's NOT_FOUND message: a share of a post the caller may not see answers the same bytes.
const postNotFoundText = "post not found"

// fieldSharedPost is the request-line boolean of a send that shares a post (never the post id).
const fieldSharedPost = "shared_post"

// ErrPostNotVisible is PostShareCheck's answer for every reason the caller may not see the post (the GetPost rules).
var ErrPostNotVisible = errors.New("messaging: shared post not visible")

// SharedPost is the post a send shares, as PostShareCheck resolved it: the original (a REPOST id resolves to it) and its
// author.
type SharedPost struct {
	ID, AuthorID string
}

// PostShareCheck decides whether uid may send postID (posts.Engagement.Viewable then RefuseShare, adapted in apiserver).
// It returns ErrPostNotVisible for every GetPost refusal (a REPOST id is checked on itself and on its original), an
// *apierr.Error with PROTECTED_ACCOUNT when uid may see a protected author's post but is not that author, and any other
// error as is.
type PostShareCheck interface {
	CheckShare(ctx context.Context, uid, postID string) (SharedPost, error)
}

// PostCards renders the shared posts of one page for its reader (posts.Engagement.ViewableMany + posts.CardOf, adapted
// in apiserver): the live card of every id the reader may see by the GetPost rules; an id the reader may not see is
// absent (messaging answers the unavailable form). One batched, cache-first read; at most 50 ids.
type PostCards interface {
	Cards(ctx context.Context, readerUID string, postIDs []string) (map[string]*postsv1.EmbeddedPost, error)
}

// ShareRecorder records a committed direct-message share for Post.share_count (engagement.Shares, adapted in apiserver).
// Best effort: an error is logged and never fails the send.
type ShareRecorder interface {
	Record(ctx context.Context, uid, postID string) (counted bool, err error)
}

// postNotFound is GetPost's NOT_FOUND answer, byte for byte.
func postNotFound() *apierr.Error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, postNotFoundText)
}

// guardPostShare is the flag gate of a send that sets shared_post_id: FEATURE_POSTS and FEATURE_DM_POST_SHARE on for the
// caller, before any lookup (FAILED_PRECONDITION + FEATURE_DISABLED, metadata feature=posts | dm_post_share), then the
// id shape (VALIDATION shared_post_id). The recipient needs messaging only: the URL text covers an older client.
func (s *service) guardPostShare(ctx context.Context, uid, postID string) error {
	for _, name := range []string{postsFlagName, PostShareFlagName} {
		if s.flags == nil || !s.flags.Enabled(uid, name) {
			logger.SetRequestField(ctx, "feature_disabled", true)
			logger.SetRequestField(ctx, "feature", name)
			return flags.DisabledError().WithMeta("feature", name)
		}
	}
	if !ids.ValidPostID(postID) {
		return apierr.Validation("shared_post_id", "shared_post_id must be a 19-digit post id")
	}
	return nil
}

// checkPostShare runs the visibility and protected-author rules for a send (after the recipient checks, before the
// transaction). Every visibility refusal is GetPost's NOT_FOUND; a protected author's post sent by anyone else is
// PROTECTED_ACCOUNT. Both write nothing.
func (s *service) checkPostShare(ctx context.Context, uid, postID string) (SharedPost, error) {
	if s.d.PostShare == nil {
		return SharedPost{}, errors.New("messaging: post share is not configured")
	}
	sp, err := s.d.PostShare.CheckShare(ctx, uid, postID)
	if errors.Is(err, ErrPostNotVisible) {
		logger.SetRequestField(ctx, fieldRefused, "post_not_visible")
		return SharedPost{}, postNotFound()
	}
	if err != nil {
		return SharedPost{}, err
	}
	return sp, nil
}

// recordShare is the after-commit share record (D6): never for a replay or a refusal (the caller only reaches it after a
// written send), never for the post's author, outside the send transaction and on a context detached from the request.
// A failure is one WARN share_record_failed with the keyed post hash, no uid; opsctl recount-shares repairs the count.
func (s *service) recordShare(ctx context.Context, uid string, sp SharedPost) {
	if s.d.Shares == nil || sp.ID == "" || sp.AuthorID == uid {
		return
	}
	rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), shareRecordTimeout)
	defer cancel()
	if _, err := s.d.Shares.Record(rctx, uid, sp.ID); err != nil {
		s.d.Log.WarnContext(ctx, "share_record_failed", slog.String("post_hash", logger.HashPost(sp.ID)),
			slog.String("error", redactErr(fmt.Errorf("messaging: record share: %w", err), uid).Error()))
	}
}

// unavailableCard is the one form of a shared post the reader may not see, whatever the cause.
func unavailableCard(postID string) *postsv1.EmbeddedPost {
	return &postsv1.EmbeddedPost{PostId: postID, Unavailable: true}
}

// sharedCards decides the card of every VISIBLE message in rows that shares a post, for reader: one PostCards batch over the
// page's distinct ids, and nothing at all (no read) when the page shares no post. While FEATURE_DM_POST_SHARE is globally
// off, or when the batch fails (logged), every card is the unavailable form: a failure never shows more than the rules
// allow. A tombstone carries no card.
func (s *service) sharedCards(ctx context.Context, reader string, rows []MessageRow) map[string]*postsv1.EmbeddedPost {
	var idsOnPage []string
	seen := map[string]bool{}
	for _, r := range rows {
		if r.State != msgVisible || r.SharedPostID == "" || seen[r.SharedPostID] {
			continue
		}
		seen[r.SharedPostID] = true
		idsOnPage = append(idsOnPage, r.SharedPostID)
	}
	if len(idsOnPage) == 0 {
		return nil
	}
	logger.SetRequestField(ctx, "shared_posts", len(idsOnPage))
	live := map[string]*postsv1.EmbeddedPost{}
	if s.flags != nil && !s.flags.GloballyOff(PostShareFlagName) && s.d.Cards != nil {
		got, err := s.d.Cards.Cards(ctx, reader, idsOnPage)
		if err != nil {
			s.d.Log.WarnContext(ctx, "messaging_post_cards_degraded", slog.String("error", redactErr(fmt.Errorf("messaging: post cards: %w", err), reader).Error()))
		} else {
			live = got
		}
	}
	out := make(map[string]*postsv1.EmbeddedPost, len(idsOnPage))
	for _, id := range idsOnPage {
		if c, ok := live[id]; ok && c != nil && !c.GetUnavailable() {
			out[id] = c
			continue
		}
		out[id] = unavailableCard(id)
	}
	return out
}
