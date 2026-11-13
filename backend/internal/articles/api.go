package articles

import (
	"context"
	"errors"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// PostGone reports, from a fresh read that bypasses every cache, whether the post no longer exists. It is the same
// shape as media.PostGone and identity.PostGone; apiserver's postGone adapter over the posts repo implements all of
// them, so the post_delete step never acts on a message's word alone.
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}

// CoverHolds is the read the media orphan sweep uses (media.ArticleCoverHolds, through media.NewDraftHolds in apiserver
// and opsctl): which of uid's image ids an unpublished article of uid names, as its cover or as an inline image block.
// Fresh reads, 30 ids per chunk and two queries per chunk; a full page reports the whole chunk held (it cannot tell, so
// never "free"). Implemented in repo_media_holds.go.
type CoverHolds interface {
	DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

// ImageResolver is the read behind article images (media.Library.ResolveArticleImages in apiserver). postID "" resolves an
// unpublished article's images; a published article passes its root post. Ids that are not usable are absent.
type ImageResolver interface {
	ResolveArticleImages(ctx context.Context, authorID, postID string, ids []string) (map[string]*commonv1.MediaRef, error)
}

// ImageAttacher claims an article's inline images for its root post inside the publication transaction (media.Library.
// LoadForArticle in apiserver). It must be called before the transaction's first write. Any refusal is ErrImageNotReady.
type ImageAttacher interface {
	LoadForArticle(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (ImageClaim, error)
}

// ImageClaim writes the claim (media postId) for the root post into the publication batch.
type ImageClaim interface {
	Attach(b store.Batch, postID string)
}

// ErrImageNotReady is what publication answers when an inline image is not usable (missing, not the author's, not
// ready, already attached, marked, a GIF). FAILED_PRECONDITION with MEDIA_NOT_READY, so the author's draft is unfrozen
// and can be fixed (remove or replace the image) and published again.
var ErrImageNotReady = apierr.New(connect.CodeFailedPrecondition, commonv1.ErrorReason_ERROR_REASON_MEDIA_NOT_READY,
	"an image in this article is not ready; remove it or upload it again")

// NewMediaHolds builds CoverHolds on the shared Firestore client.
func NewMediaHolds(client *firestore.Client) CoverHolds { return &mediaHolds{client: client} }

// ErrNotFound is EvidenceReader's answer when no published article is rooted at the given post.
var ErrNotFound = errors.New("articles: article not found")

// MaxEvidenceBodyBytes bounds Evidence.Body: the first 16 KiB of the article's plain text, cut on a code point.
const MaxEvidenceBodyBytes = 16 << 10

// Evidence is the bounded snapshot of a published article a moderation report keeps, so the author cannot rewrite
// it before triage. Plain text only (never the structured JSON); no other user's data.
type Evidence struct {
	ArticleID string
	Title     string
	Revision  int64
	// Body is the article's plain text, at most MaxEvidenceBodyBytes; Truncated says it was cut.
	Body      string
	Truncated bool
	// ImageMediaIDs are the article's inline image ids (the report keeps them as evidence, as it keeps the cover's).
	ImageMediaIDs []string
}

// EvidenceReader is the read moderation uses (through apiserver) when a reported post is an article root. It does
// no visibility check: the caller has already authorized the root post with posts.GetForViewer.
type EvidenceReader interface {
	// ReportEvidence returns the published article articleID if its root post is postID, else ErrNotFound.
	ReportEvidence(ctx context.Context, articleID, postID string) (Evidence, error)
}

// NewEvidenceReader builds the EvidenceReader over Firestore (one point read of articles/{articleId}).
func NewEvidenceReader(client *firestore.Client) EvidenceReader {
	return evidenceReader{repo: &firestoreRepo{client}}
}

type evidenceReader struct{ repo repository }

func (r evidenceReader) ReportEvidence(ctx context.Context, articleID, postID string) (Evidence, error) {
	if !validID.MatchString(articleID) {
		return Evidence{}, ErrNotFound
	}
	a, err := r.repo.get(ctx, articleID)
	if err != nil {
		if connect.CodeOf(err) == connect.CodeNotFound {
			return Evidence{}, ErrNotFound
		}
		return Evidence{}, err
	}
	if !a.Published || a.PostID == "" || a.PostID != postID {
		return Evidence{}, ErrNotFound
	}
	text := plainText(a.Body)
	body := truncateBytes(text, MaxEvidenceBodyBytes)
	return Evidence{ArticleID: a.ID, Title: a.Title, Revision: a.Revision, Body: body, Truncated: len(body) < len(text), ImageMediaIDs: imageIDsOf(a.Body)}, nil
}
