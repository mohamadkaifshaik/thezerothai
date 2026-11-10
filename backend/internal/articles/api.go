package articles

import (
	"context"
	"errors"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
)

// PostGone reports, from a fresh read that bypasses every cache, whether the post no longer exists. It is the same
// shape as media.PostGone and identity.PostGone; apiserver's postGone adapter over the posts repo implements all of
// them, so the post_delete step never acts on a message's word alone.
type PostGone interface {
	PostGone(ctx context.Context, postID string) (bool, error)
}

// CoverHolds is the read the media orphan sweep uses (media.ArticleCoverHolds, through media.NewDraftHolds in apiserver
// and opsctl): which of uid's image ids an unpublished article of uid names as its cover. Fresh reads, one query per 30
// ids; a full page reports the whole chunk held (it cannot tell, so never "free"). Implemented in repo_media_holds.go.
type CoverHolds interface {
	DraftCoverHolds(ctx context.Context, uid string, ids []string) (map[string]bool, error)
}

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
	return Evidence{ArticleID: a.ID, Title: a.Title, Revision: a.Revision, Body: body, Truncated: len(body) < len(text)}, nil
}
