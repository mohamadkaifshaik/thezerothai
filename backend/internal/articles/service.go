package articles

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	"google.golang.org/protobuf/types/known/timestamppb"

	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	"github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1/articlesv1connect"
	pv "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/limits"
)

// Server uses the existing posts capability and protected Connect interceptor
// chain. Publication freezes the draft, then atomically finalizes it with the
// root post through a trusted claim. Root creation reuses normal post
// ownership/media validation and timeline events.
type Server struct {
	articlesv1connect.UnimplementedArticleServiceHandler
	repo         repository
	posts        posts.Service
	audience     Audience
	flags        posts.FlagChecker
	now          func() time.Time
	resolveCover func(context.Context, string, string) (string, error)
}

// Audience is the authorized-read seam: posts.Service.GetForViewer delegates
// to the canonical posts.Audience predicate, including blocks and moderation.
// Article bodies are never returned to another viewer without this check.
type Audience interface {
	GetForViewer(context.Context, string, string) (*posts.Post, error)
}

var _ Audience = (posts.Service)(nil)

func NewServer(client *firestore.Client, p posts.Service, f posts.FlagChecker, coverResolver ...func(context.Context, string, string) (string, error)) *Server {
	s := &Server{repo: &firestoreRepo{client}, posts: p, audience: p, flags: f, now: time.Now}
	if len(coverResolver) > 0 {
		s.resolveCover = coverResolver[0]
	}
	return s
}
func (s *Server) draftWire(ctx context.Context, a *record) *av.Article {
	out := wire(a)
	if a.CoverMediaID != "" && s.resolveCover != nil && s.flags != nil && s.flags.Enabled(a.AuthorID, "media") {
		if url, err := s.resolveCover(ctx, a.AuthorID, a.CoverMediaID); err == nil {
			out.CoverUrl = url
		}
	}
	return out
}
func (s *Server) guard(ctx context.Context) (string, error) {
	if err := posts.GuardFeature(ctx, s.flags); err != nil {
		return "", err
	}
	uid, _ := authn.UIDFromContext(ctx)
	return uid, nil
}
func validArticleID(id string) error {
	if !validID.MatchString(id) {
		return apierr.Validation("article_id", "invalid article id")
	}
	return nil
}
func own(a *record, uid string) error {
	if a == nil || a.AuthorID != uid {
		return missing()
	}
	return nil
}
func wire(a *record) *av.Article {
	return &av.Article{ArticleId: a.ID, AuthorId: a.AuthorID, Revision: a.Revision, Title: a.Title, BodyJson: a.Body, CoverMediaId: a.CoverMediaID, PostId: a.PostID, UpdatedAt: timestamppb.New(a.UpdatedAt), PublicationPending: a.PendingKey != "" && !a.Published, PublicationCaption: a.Caption, PublicationReplyPolicy: pv.ReplyPolicy(a.ReplyPolicy), Excerpt: excerptOf(a.Body)}
}

// audienceErr maps an Audience refusal. Every visibility refusal (missing, deleted, hidden, blocked or
// non-ACTIVE author) arrives as the one posts NOT_FOUND and becomes the article's NOT_FOUND, so a reader
// cannot probe which one applied. Anything else (an outage, an internal failure, a cancelled or expired
// request) propagates: answering NOT_FOUND would tell the client a published article is gone.
func audienceErr(err error) error {
	if errors.Is(err, posts.ErrNotFound) || apierr.ToConnect(err).Code() == connect.CodeNotFound {
		return missing()
	}
	return fmt.Errorf("articles: authorize article read: %w", err)
}
func postWire(p *posts.Post, uid string) *pv.PostView {
	return posts.ToView(p, posts.ViewerSet{}, uid)
}
func cover(a *av.Article, p *posts.Post) {
	if a.CoverMediaId != "" && len(p.Media) > 0 {
		a.CoverUrl = p.Media[0].URL
	}
}

func (s *Server) GetArticle(ctx context.Context, req *connect.Request[av.GetArticleRequest]) (*connect.Response[av.GetArticleResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	id := req.Msg.GetArticleId()
	if err = validArticleID(id); err != nil {
		return nil, err
	}
	a, err := s.repo.get(ctx, id)
	if err != nil {
		return nil, err
	}
	out := &av.GetArticleResponse{}
	if a.Published {
		p, e := s.audience.GetForViewer(ctx, uid, a.PostID)
		if e != nil {
			return nil, audienceErr(e)
		}
		out.Post = postWire(p, uid)
		out.Article = wire(a)
		cover(out.Article, p)
	} else {
		if err = own(a, uid); err != nil {
			return nil, err
		}
		out.Article = s.draftWire(ctx, a)
	}
	return connect.NewResponse(out), nil
}
func (s *Server) SaveArticle(ctx context.Context, req *connect.Request[av.SaveArticleRequest]) (*connect.Response[av.SaveArticleResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	in := req.Msg.GetArticle()
	if in == nil {
		return nil, apierr.Validation("article", "article is required")
	}
	if err = validArticleID(in.GetArticleId()); err != nil {
		return nil, err
	}
	if _, err = validateContent(in.GetTitle(), in.GetBodyJson(), false); err != nil {
		return nil, err
	}
	if in.GetCoverMediaId() != "" && !validID.MatchString(in.GetCoverMediaId()) {
		return nil, apierr.Validation("cover_media_id", "invalid media id")
	}
	a, err := s.repo.change(ctx, in.GetArticleId(), func(current *record) (*record, error) {
		if current == nil {
			if req.Msg.GetExpectedRevision() != 0 {
				return nil, conflict()
			}
			current = &record{ID: in.GetArticleId(), AuthorID: uid}
		}
		if e := own(current, uid); e != nil {
			return nil, e
		}
		if current.Published || current.PendingKey != "" {
			return nil, locked()
		}
		if current.Revision != req.Msg.GetExpectedRevision() {
			return nil, conflict()
		}
		next := *current
		next.Title = in.GetTitle()
		next.Body = in.GetBodyJson()
		next.CoverMediaID = in.GetCoverMediaId()
		next.Revision++
		next.UpdatedAt = s.now().UTC()
		return &next, nil
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&av.SaveArticleResponse{Article: s.draftWire(ctx, a)}), nil
}
func (s *Server) ListArticles(ctx context.Context, req *connect.Request[av.ListArticlesRequest]) (*connect.Response[av.ListArticlesResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	after := req.Msg.GetPageToken()
	if after != "" {
		if err = validArticleID(after); err != nil {
			return nil, apierr.Validation("page_token", "invalid article cursor")
		}
	}
	n := limits.ClampPageSize(req.Msg.GetPageSize())
	rows, err := s.repo.list(ctx, uid, req.Msg.GetPublished(), n, after)
	if err != nil {
		return nil, err
	}
	out := &av.ListArticlesResponse{}
	for _, a := range rows {
		// A page carries excerpts, never bodies (a full page of 180 KB bodies would be ~9 MB); readers and the
		// editor open an article with GetArticle.
		row := wire(a)
		row.BodyJson = ""
		out.Articles = append(out.Articles, row)
	}
	if len(rows) == n {
		out.NextPageToken = rows[len(rows)-1].ID
	}
	return connect.NewResponse(out), nil
}
func (s *Server) DeleteArticle(ctx context.Context, req *connect.Request[av.DeleteArticleRequest]) (*connect.Response[av.DeleteArticleResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	id := req.Msg.GetArticleId()
	if err = validArticleID(id); err != nil {
		return nil, err
	}
	// Published articles are deleted through their root post, then their body.
	a, err := s.repo.get(ctx, id)
	if err != nil {
		return nil, err
	}
	if err = own(a, uid); err != nil {
		return nil, err
	}
	if a.Revision != req.Msg.GetExpectedRevision() {
		return nil, conflict()
	}
	if a.PendingKey != "" && !a.Published {
		return nil, locked()
	}
	if a.Published {
		sum := sha256.Sum256([]byte("article-delete:" + uid + ":" + id))
		if err = s.posts.Delete(ctx, uid, hex.EncodeToString(sum[:16]), a.PostID); err != nil {
			return nil, err
		}
	}
	_, err = s.repo.change(ctx, id, func(current *record) (*record, error) {
		if e := own(current, uid); e != nil {
			return nil, e
		}
		if current.Revision != req.Msg.GetExpectedRevision() {
			return nil, conflict()
		}
		if (current.PendingKey != "" && !current.Published) || current.Published != a.Published {
			return nil, locked()
		}
		return nil, nil
	})
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&av.DeleteArticleResponse{}), nil
}
func (s *Server) PublishArticle(ctx context.Context, req *connect.Request[av.PublishArticleRequest]) (*connect.Response[av.PublishArticleResponse], error) {
	uid, err := s.guard(ctx)
	if err != nil {
		return nil, err
	}
	m := req.Msg
	id := m.GetArticleId()
	if err = validArticleID(id); err != nil {
		return nil, err
	}
	if !idempotency.KeyFormatValid(m.GetIdempotencyKey()) {
		return nil, apierr.Validation("idempotency_key", "invalid publication key")
	}
	// Validate caption before freezing. Create performs the authoritative text,
	// reply-policy and verified-account checks before committing a post.
	if len([]rune(m.GetCaption())) > 280 {
		return nil, apierr.Validation("caption", "caption is too long")
	}
	a, err := s.repo.change(ctx, id, func(current *record) (*record, error) {
		if e := own(current, uid); e != nil {
			return nil, e
		}
		if current.Revision != m.GetExpectedRevision() {
			return nil, conflict()
		}
		if current.PendingKey != "" {
			if current.PendingKey != m.GetIdempotencyKey() || current.Caption != m.GetCaption() || current.ReplyPolicy != int32(m.GetReplyPolicy()) {
				return nil, locked()
			}
			return current, nil
		}
		if current.Published {
			return nil, locked()
		}
		if _, e := validateContent(current.Title, current.Body, true); e != nil {
			return nil, e
		}
		next := *current
		next.PendingKey = m.GetIdempotencyKey()
		next.PendingAt = s.now().UTC()
		next.Caption = m.GetCaption()
		next.ReplyPolicy = int32(m.GetReplyPolicy())
		return &next, nil
	})
	if err != nil {
		return nil, err
	}
	if a.Published {
		p, e := s.audience.GetForViewer(ctx, uid, a.PostID)
		if e != nil {
			return nil, e
		}
		article := wire(a)
		cover(article, p)
		return connect.NewResponse(&av.PublishArticleResponse{Article: article, Post: postWire(p, uid)}), nil
	}
	excerpt, _ := validateContent(a.Title, a.Body, true)
	text := a.Caption
	if text == "" {
		text = a.Title
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("article:%s:%s:%d:%s", uid, id, a.Revision, a.PendingKey)))
	in := posts.CreateInput{IdempotencyKey: hex.EncodeToString(sum[:]), Text: text, ReplyPolicy: a.ReplyPolicy, ReplyAudienceEnabled: s.flags != nil && s.flags.Enabled(uid, "reply_audience"), Article: &posts.ArticlePreview{ArticleID: id, Title: a.Title, Excerpt: excerpt}}
	in.ArticlePublication = &publicationIntent{repo: s.repo, expected: a, now: s.now().UTC()}
	if a.CoverMediaID != "" {
		in.MediaIDs = []string{a.CoverMediaID}
		in.MediaEnabled = s.flags != nil && s.flags.Enabled(uid, "media")
	}
	p, err := s.posts.Create(ctx, uid, in)
	if err != nil {
		// Definitive rejections have no post commit; allow the author to fix drafts.
		switch apierr.ToConnect(err).Code() {
		case connect.CodeInvalidArgument, connect.CodePermissionDenied, connect.CodeFailedPrecondition, connect.CodeResourceExhausted:
			_, _ = s.repo.change(ctx, id, func(current *record) (*record, error) {
				if current == nil || current.Published || current.PendingKey != a.PendingKey {
					return current, nil
				}
				next := *current
				next.PendingKey = ""
				return &next, nil
			})
		}
		return nil, err
	}
	// The trusted claim finalized this record in the root post transaction.
	a.Published = true
	a.PostID = p.ID
	a.UpdatedAt = s.now().UTC()
	article := wire(a)
	cover(article, p)
	return connect.NewResponse(&av.PublishArticleResponse{Article: article, Post: postWire(p, uid)}), nil
}
