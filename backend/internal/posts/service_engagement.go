// service_engagement.go is posts' side of engagement (P5, ADR-0018): the quote path of CreatePost, the release of
// a deleted REPOST/QUOTE's counters, and the Engagement seam the engagement module consumes.
package posts

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/ids"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/logger"
)

var _ Engagement = (*service)(nil)

// SetRepostLinks binds engagement's RepostLinks after both modules are built (they depend on each other:
// engagement needs posts.Engagement, DeletePost needs RepostLinks). Call once, synchronously, before
// ListenAndServe. Dependants of Service reach it by type assertion, like identity's SetDirectory.
func (s *service) SetRepostLinks(l RepostLinks) { s.links = l }

// Viewable implements Engagement.
func (s *service) Viewable(ctx context.Context, callerUID, postID string) (*Post, error) {
	return s.viewable(ctx, callerUID, postID)
}

// CountsChanged implements Engagement.
func (s *service) CountsChanged(postID string, likeDelta, repostDelta int64) {
	s.cache.AdjustCounts(postID, likeDelta, repostDelta, 0)
}

// RepostCreated implements Engagement.
func (s *service) RepostCreated(p *Post) {
	s.cache.SetPost(p)
	s.cache.PrependOwn(p)
	s.directory.Forget(p.AuthorID) // users.postsCount changed by a blind increment (ADR-0008 B2)
}

// RepostRemoved implements Engagement.
func (s *service) RepostRemoved(authorID, repostID string) {
	s.cache.RemoveOwn(authorID, repostID)
	s.directory.Forget(authorID)
}

// quoteTarget resolves and validates a quote target for CreatePost: the id shape, then the GetPost visibility
// rules. A REPOST target resolves to the original (D4) and is checked with the same rules. Every refusal is the
// one NOT_FOUND "post not found" answer. Reads: target 1 + its author 1 + caller graph 1 cold (+2 for a REPOST).
func (s *service) quoteTarget(ctx context.Context, uid, id string) (*Post, error) {
	if !ids.ValidPostID(id) {
		return nil, apierr.Validation("quote_of_post_id", "quote_of_post_id must be a 19-digit post id")
	}
	p, err := s.viewable(ctx, uid, id)
	if errors.Is(err, ErrNotFound) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, postNotFound()
	}
	if err != nil {
		return nil, err
	}
	if p.Kind != KindRepost {
		return p, nil
	}
	if p.RepostOfID == "" {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, postNotFound()
	}
	orig, err := s.viewable(ctx, uid, p.RepostOfID)
	if errors.Is(err, ErrNotFound) {
		logger.SetRequestField(ctx, fieldOutcome, outcomeNotFound)
		return nil, postNotFound()
	}
	if err != nil {
		return nil, err
	}
	return orig, nil
}

// applyQuote turns a root-post draft into a QUOTE of q: kind, the quote link, the frozen snapshot of q and the
// top-level embedded author id. q's quoteCount increment rides in the CreatePost transaction.
func applyQuote(p *CreateParams, q *Post) {
	p.QuoteID = q.ID
	p.Draft.Kind = KindQuote
	p.Draft.QuoteOfID = q.ID
	p.Draft.EmbeddedAuthorID = q.Author.UserID
	p.Draft.Embedded = snapshotOf(q)
}

// snapshotOf is the one-level frozen copy of q a quote or repost embeds (ADR-0018 D12).
func snapshotOf(q *Post) *Embedded {
	media := make([]MediaRef, len(q.Media))
	copy(media, q.Media)
	if len(media) == 0 {
		media = nil
	}
	return &Embedded{PostID: q.ID, Author: q.Author, Text: q.Text, Media: media, CreatedAt: q.CreatedAt}
}

// NewRepostPost builds the REPOST post doc engagement writes for uid reposting original (D5): a root post
// (isReply=false) of kind REPOST with its own id and createdAt, an embedded snapshot and no text. The caller
// draws the id inside its transaction attempt.
func NewRepostPost(id string, createdAt time.Time, author AuthorSnapshot, version int64, original *Post) *Post {
	return &Post{
		ID: id, AuthorID: author.UserID, Author: author, Kind: KindRepost,
		ConversationID: id, RepostOfID: original.ID, Embedded: snapshotOf(original), EmbeddedAuthorID: original.Author.UserID,
		Hashtags: []string{}, Visibility: VisibilityPublic, SnapshotVersion: version, CreatedAt: createdAt,
	}
}

// releaseEngagement runs after a successful DeletePost: it releases the counters the deleted post held on the
// post it copied. A REPOST releases repostCount and userLikes through RepostLinks (the reposts doc was deleted in
// the same batch); a QUOTE releases the quoted post's quoteCount, like a reply releases replyCount. Best effort:
// a failure leaves a count one too high, which is cosmetic, and is logged (no ids).
func (s *service) releaseEngagement(ctx context.Context, p *Post) {
	switch {
	case p.Kind == KindRepost && p.RepostOfID != "":
		s.cache.AdjustCounts(p.RepostOfID, 0, -1, 0)
		if s.links == nil {
			return
		}
		if err := s.links.Released(ctx, p.RepostOfID, p.AuthorID); err != nil {
			slog.WarnContext(ctx, "posts_repost_release_failed", "error", logger.RedactErr(err, p.AuthorID).Error())
		}
	case p.Kind == KindQuote && p.QuoteOfID != "":
		if err := s.repo.AddQuoteCount(ctx, p.QuoteOfID, -1); err != nil {
			slog.WarnContext(ctx, "posts_quote_count_release_failed", "error", logger.RedactErr(err, p.AuthorID).Error())
		}
		s.cache.AdjustCounts(p.QuoteOfID, 0, 0, -1)
	}
}
