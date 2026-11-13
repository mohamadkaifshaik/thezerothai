package articles

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"connectrpc.com/connect"
	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
)

const testID = "12345678-1234-1234-1234-123456789012"
const testBody = `[{"kind":"paragraph","runs":[{"text":"Hello world","marks":["bold"],"link":"https://example.com"}]}]`

type testFlags bool

func (f testFlags) Enabled(string, string) bool { return bool(f) }

type memoryRepo struct {
	mu           sync.Mutex
	rows         map[string]*record
	failFinalize bool
	beforeChange func(*record)
	countErr     error
}

func clone(a *record) *record {
	if a == nil {
		return nil
	}
	out := *a
	return &out
}
func (r *memoryRepo) get(_ context.Context, id string) (*record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if a := r.rows[id]; a != nil {
		return clone(a), nil
	}
	return nil, missing()
}
func (r *memoryRepo) change(_ context.Context, id string, fn func(*record) (*record, error)) (*record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.beforeChange != nil {
		hook := r.beforeChange
		r.beforeChange = nil
		hook(r.rows[id])
	}
	a, err := fn(clone(r.rows[id]))
	if err != nil {
		return nil, err
	}
	if a != nil && a.Published && r.failFinalize {
		r.failFinalize = false
		return nil, errors.New("connection lost")
	}
	if a == nil {
		delete(r.rows, id)
	} else {
		r.rows[id] = clone(a)
	}
	return clone(a), nil
}
func (r *memoryRepo) saveDraft(ctx context.Context, id, uid string, fn func(*record, func() (int, error)) (*record, error)) (*record, error) {
	drafts := func() (int, error) {
		// Called under r.mu (inside change), like a read of the same transaction.
		if r.countErr != nil {
			return 0, r.countErr
		}
		n := 0
		for _, a := range r.rows {
			if a.AuthorID == uid && !a.Published && n <= maxDraftsPerAuthor {
				n++
			}
		}
		return n, nil
	}
	return r.change(ctx, id, func(current *record) (*record, error) { return fn(current, drafts) })
}
func (r *memoryRepo) list(_ context.Context, uid string, p bool, n int, _ string) ([]*record, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []*record
	for _, a := range r.rows {
		if a.AuthorID == uid && a.Published == p && len(out) < n {
			out = append(out, clone(a))
		}
	}
	return out, nil
}

type fakePosts struct {
	posts.Service
	created   map[string]*posts.Post
	calls     int
	hidden    bool
	fail      error
	loseReply bool
	viewErr   error
}

// postNotFound mirrors the one NOT_FOUND posts.Service.GetForViewer returns for every visibility refusal.
func postNotFound() error {
	return apierr.New(connect.CodeNotFound, commonv1.ErrorReason_ERROR_REASON_UNSPECIFIED, "post not found")
}

func (p *fakePosts) Create(ctx context.Context, uid string, in posts.CreateInput) (*posts.Post, error) {
	p.calls++
	if p.fail != nil {
		return nil, p.fail
	}
	if v := p.created[in.IdempotencyKey]; v != nil {
		return v, nil
	}
	v := &posts.Post{ID: "1000000000000000001", AuthorID: uid, Text: in.Text, Article: in.Article, CreatedAt: time.Now()}
	intent := in.ArticlePublication.(*publicationIntent)
	_, err := intent.repo.change(ctx, intent.expected.ID, func(a *record) (*record, error) {
		if a == nil || a.Published || a.PendingKey != intent.expected.PendingKey {
			return nil, conflict()
		}
		a.Published = true
		a.PostID = v.ID
		a.UpdatedAt = intent.now
		return a, nil
	})
	if err != nil {
		return nil, err
	}
	p.created[in.IdempotencyKey] = v
	if p.loseReply {
		p.loseReply = false
		return nil, errors.New("connection lost after commit")
	}
	return v, nil
}
func (p *fakePosts) GetForViewer(_ context.Context, _, id string) (*posts.Post, error) {
	if p.viewErr != nil {
		return nil, p.viewErr
	}
	if p.hidden {
		return nil, postNotFound()
	}
	for _, v := range p.created {
		if v.ID == id {
			return v, nil
		}
	}
	return nil, postNotFound()
}
func (p *fakePosts) Delete(context.Context, string, string, string) error {
	p.hidden = true
	return nil
}
func setup() (*Server, *memoryRepo, *fakePosts, context.Context) {
	r := &memoryRepo{rows: map[string]*record{}}
	p := &fakePosts{created: map[string]*posts.Post{}}
	// The standard fixture represents a verified publisher. Missing/denied
	// verification is exercised explicitly by the subscription regressions.
	s := &Server{repo: r, posts: p, audience: p, flags: testFlags(true), now: func() time.Time { return time.Unix(1800000000, 0) }, publishingAccess: func(context.Context, string) error { return nil }}
	return s, r, p, authn.WithClaims(context.Background(), authn.Claims{UID: "alice"})
}
func save(t *testing.T, s *Server, ctx context.Context) *av.Article {
	t.Helper()
	res, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: testID, Title: "Title", BodyJson: testBody, AuthorId: "forged", PostId: "forged"}}))
	if err != nil {
		t.Fatal(err)
	}
	return res.Msg.Article
}
func publication() *connect.Request[av.PublishArticleRequest] {
	return connect.NewRequest(&av.PublishArticleRequest{ArticleId: testID, ExpectedRevision: 1, IdempotencyKey: "publication-key-1", Caption: "Read my article"})
}

func TestSaveOwnershipRevisionAndUntrustedFields(t *testing.T) {
	s, _, _, ctx := setup()
	a := save(t, s, ctx)
	if a.AuthorId != "alice" || a.PostId != "" || a.Revision != 1 {
		t.Fatalf("untrusted fields accepted: %v", a)
	}
	_, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: a, ExpectedRevision: 0}))
	if connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("stale save: %v", err)
	}
	bob := authn.WithClaims(ctx, authn.Claims{UID: "bob"})
	_, err = s.GetArticle(bob, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatalf("draft leaked: %v", err)
	}
	_, err = s.SaveArticle(bob, connect.NewRequest(&av.SaveArticleRequest{Article: a, ExpectedRevision: 1}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatalf("foreign edit: %v", err)
	}
}
func TestPublishReplayAndAuthorizedBody(t *testing.T) {
	s, _, p, ctx := setup()
	save(t, s, ctx)
	first, err := s.PublishArticle(ctx, publication())
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.PublishArticle(ctx, publication())
	if err != nil {
		t.Fatal(err)
	}
	if first.Msg.Article.PostId != second.Msg.Article.PostId || p.calls != 1 || len(p.created) != 1 {
		t.Fatal("publication duplicated")
	}
	for _, post := range p.created {
		if post.Article.Title != "Title" || post.Text != "Read my article" {
			t.Fatal("missing atomic preview or caption")
		}
	}
	bob := authn.WithClaims(ctx, authn.Claims{UID: "bob"})
	if _, err = s.GetArticle(bob, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID})); err != nil {
		t.Fatal(err)
	}
	p.hidden = true
	_, err = s.GetArticle(bob, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatalf("hidden article disclosed: %v", err)
	}
}
func TestPublicationRecoversAfterRootCommittedButFinalizationLost(t *testing.T) {
	s, _, p, ctx := setup()
	save(t, s, ctx)
	p.loseReply = true
	if _, err := s.PublishArticle(ctx, publication()); err == nil {
		t.Fatal("expected connection failure")
	}
	if len(p.created) != 1 {
		t.Fatal("root missing")
	}
	if _, err := s.PublishArticle(ctx, publication()); err != nil {
		t.Fatal(err)
	}
	if len(p.created) != 1 {
		t.Fatal("duplicate root during recovery")
	}
}
func TestLostReplyRecoversBeyondIdempotencyWindow(t *testing.T) {
	s, _, p, ctx := setup()
	save(t, s, ctx)
	p.loseReply = true
	_, _ = s.PublishArticle(ctx, publication())
	s.now = func() time.Time { return time.Unix(1800000000, 0).Add(24 * time.Hour) }
	_, err := s.PublishArticle(ctx, publication())
	if err != nil || p.calls != 1 {
		t.Fatalf("expired replay recreated root: %v", err)
	}
}
func TestDefinitivePublishRejectionUnlocksDraft(t *testing.T) {
	s, _, p, ctx := setup()
	a := save(t, s, ctx)
	p.fail = apierr.Validation("caption", "invalid caption")
	_, _ = s.PublishArticle(ctx, publication())
	_, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: a, ExpectedRevision: 1}))
	if err != nil {
		t.Fatalf("rejected publication left draft frozen: %v", err)
	}
}
func TestGuardRejectsWithoutReads(t *testing.T) {
	s, _, _, ctx := setup()
	s.flags = testFlags(false)
	_, err := s.GetArticle(ctx, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if apierr.ToConnect(err).Code() != connect.CodeFailedPrecondition {
		t.Fatal(err)
	}
	_, err = s.GetArticle(context.Background(), connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if apierr.ToConnect(err).Code() != connect.CodeUnauthenticated {
		t.Fatal(err)
	}
}
func TestStructuredContentValidation(t *testing.T) {
	if excerpt, err := validateContent("Title", testBody, true); err != nil || excerpt != "Hello world" {
		t.Fatalf("valid body: %q %v", excerpt, err)
	}
	cases := []string{`null`, `[] {}`, `[{"kind":"unknown","runs":[]}]`, `[{"kind":"image","runs":[],"mediaId":"foreign"}]`, `[{"kind":"paragraph","runs":[{"text":"x","marks":["unknown"]}]}]`, `[{"kind":"paragraph","runs":[{"text":"x","marks":[],"link":"javascript:evil()"}]}]`, `[{"kind":"paragraph","runs":[{"text":"x","marks":[],"link":"https://user:pass@example.com"}]}]`}
	for _, body := range cases {
		if _, err := validateContent("Title", body, true); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
}

func TestDeleteRechecksConcurrentPublicationFreeze(t *testing.T) {
	s, r, _, ctx := setup()
	save(t, s, ctx)
	r.beforeChange = func(a *record) { a.PendingKey = "concurrent-publish" }
	_, err := s.DeleteArticle(ctx, connect.NewRequest(&av.DeleteArticleRequest{ArticleId: testID, ExpectedRevision: 1}))
	if connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("delete crossed publication freeze: %v", err)
	}
	a, err := r.get(ctx, testID)
	if err != nil || a.PendingKey == "" {
		t.Fatalf("frozen draft deleted: %v", err)
	}
}

func TestDraftCoverReloadOnlyResolvesForOwner(t *testing.T) {
	s, _, _, ctx := setup()
	a := save(t, s, ctx)
	a.CoverMediaId = "1000000000000000001"
	calls := 0
	s.resolveCover = func(_ context.Context, uid, id string) (string, error) {
		calls++
		if uid != "alice" || id != a.CoverMediaId {
			t.Fatal("untrusted cover lookup")
		}
		return "https://media.example/cover.jpg", nil
	}
	res, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: a, ExpectedRevision: 1}))
	if err != nil || res.Msg.Article.CoverUrl == "" {
		t.Fatalf("save cover: %v", err)
	}
	got, err := s.GetArticle(ctx, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if err != nil || got.Msg.Article.CoverUrl == "" {
		t.Fatalf("reload cover: %v", err)
	}
	bob := authn.WithClaims(ctx, authn.Claims{UID: "bob"})
	_, _ = s.GetArticle(bob, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if calls != 2 {
		t.Fatalf("foreign viewer triggered cover resolution: %d", calls)
	}
}

// TestDeletePublishedArticleRacingPostDeleteStep: the post_delete job may remove the published record between
// DeleteArticle's posts.Delete and its own transaction; the author's delete still succeeds.
func TestDeletePublishedArticleRacingPostDeleteStep(t *testing.T) {
	s, r, _, ctx := setup()
	save(t, s, ctx)
	if _, err := s.PublishArticle(ctx, publication()); err != nil {
		t.Fatal(err)
	}
	r.beforeChange = func(*record) { delete(r.rows, testID) }
	if _, err := s.DeleteArticle(ctx, connect.NewRequest(&av.DeleteArticleRequest{ArticleId: testID, ExpectedRevision: 1})); err != nil {
		t.Fatalf("delete after the job removed the record: %v", err)
	}
	// A draft that vanished is still NOT_FOUND (nothing was published, so nothing else removes drafts).
	s2, r2, _, ctx2 := setup()
	save(t, s2, ctx2)
	r2.beforeChange = func(*record) { delete(r2.rows, testID) }
	_, err := s2.DeleteArticle(ctx2, connect.NewRequest(&av.DeleteArticleRequest{ArticleId: testID, ExpectedRevision: 1}))
	if connect.CodeOf(err) != connect.CodeNotFound {
		t.Fatalf("vanished draft: %v", err)
	}
}

// TestPostDeleteJobs covers the articles step of the post_delete chain.
func TestPostDeleteJobs(t *testing.T) {
	const uid = "alice0000000000000000000000a"
	const postID = "1000000000000000001"
	msg := func(kind, u, p string) []byte {
		b, _ := json.Marshal(postDeleteMessage{Kind: kind, UID: u, PostID: p})
		return b
	}
	cases := []struct {
		name      string
		data      []byte
		gone      bool
		goneErr   error
		deleted   bool
		deleteErr error
		want      string
		wantErr   bool
		wantCalls int
	}{
		{name: "malformed", data: []byte(`{`), want: "dropped:malformed_message"},
		{name: "wrong kind", data: msg("other", uid, postID), want: "dropped:invalid_message"},
		{name: "bad post id", data: msg(postDeleteJobKind, uid, "x"), want: "dropped:invalid_message"},
		{name: "post still live", data: msg(postDeleteJobKind, uid, postID), gone: false, want: "refused"},
		{name: "existence check fails", data: msg(postDeleteJobKind, uid, postID), goneErr: errors.New("down"), wantErr: true},
		{name: "no article", data: msg(postDeleteJobKind, uid, postID), gone: true, want: "noop", wantCalls: 1},
		{name: "article deleted", data: msg(postDeleteJobKind, uid, postID), gone: true, deleted: true, want: "article_deleted", wantCalls: 1},
		{name: "delete fails", data: msg(postDeleteJobKind, uid, postID), gone: true, deleteErr: errors.New("down"), wantErr: true, wantCalls: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rm := &fakeRemover{deleted: tc.deleted, err: tc.deleteErr}
			j := &PostDeleteJobs{repo: rm, gone: fakeGone{gone: tc.gone, err: tc.goneErr}}
			got, err := j.Handle(context.Background(), tc.data)
			if (err != nil) != tc.wantErr || got != tc.want {
				t.Fatalf("Handle = %q, %v; want %q, err %v", got, err, tc.want, tc.wantErr)
			}
			if rm.calls != tc.wantCalls {
				t.Fatalf("deleteByRoot calls = %d, want %d", rm.calls, tc.wantCalls)
			}
			if tc.wantCalls > 0 && (rm.uid != uid || rm.postID != postID) {
				t.Fatalf("deleteByRoot(%q, %q)", rm.uid, rm.postID)
			}
		})
	}
}

type fakeGone struct {
	gone bool
	err  error
}

func (g fakeGone) PostGone(context.Context, string) (bool, error) { return g.gone, g.err }

type fakeRemover struct {
	deleted     bool
	err         error
	calls       int
	uid, postID string
}

func (f *fakeRemover) deleteByRoot(_ context.Context, uid, postID string) (bool, error) {
	f.calls++
	f.uid, f.postID = uid, postID
	return f.deleted, f.err
}

// TestListArticlesCarriesExcerptsNotBodies: a list page never ships bodies; every row has the bounded plain-text
// excerpt, and GetArticle still returns the full body.
func TestListArticlesCarriesExcerptsNotBodies(t *testing.T) {
	s, r, _, ctx := setup()
	save(t, s, ctx)
	long := strings.Repeat("語", 300) + " tail"
	r.rows["abcdefghijklmnop0002"] = &record{ID: "abcdefghijklmnop0002", AuthorID: "alice", Revision: 1, Title: "Long",
		Body: `[{"kind":"heading1","runs":[{"text":"Head","marks":[]}]},{"kind":"paragraph","runs":[{"text":"` + long + `","marks":[]}]}]`}
	r.rows["abcdefghijklmnop0003"] = &record{ID: "abcdefghijklmnop0003", AuthorID: "alice", Revision: 1, Title: "Legacy", Body: `not json`}
	res, err := s.ListArticles(ctx, connect.NewRequest(&av.ListArticlesRequest{PageSize: 50}))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]*av.Article{}
	for _, a := range res.Msg.Articles {
		if a.BodyJson != "" {
			t.Fatalf("list shipped a body for %s", a.ArticleId)
		}
		got[a.ArticleId] = a
	}
	if len(got) != 3 {
		t.Fatalf("rows = %d, want 3", len(got))
	}
	if e := got[testID].Excerpt; e != "Hello world" {
		t.Fatalf("excerpt = %q", e)
	}
	e := got["abcdefghijklmnop0002"].Excerpt
	if n := utf8.RuneCountInString(e); n != maxExcerptRunes || !strings.HasPrefix(e, "Head 語") {
		t.Fatalf("long excerpt: %d runes, %q", n, e)
	}
	if e := got["abcdefghijklmnop0003"].Excerpt; e != "" {
		t.Fatalf("undecodable body excerpt = %q", e)
	}
	full, err := s.GetArticle(ctx, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
	if err != nil || full.Msg.Article.BodyJson != testBody || full.Msg.Article.Excerpt != "Hello world" {
		t.Fatalf("get lost the body: %v", err)
	}
}

// TestGetPublishedArticleAudienceErrors: only a genuine visibility refusal (NOT_FOUND) is the article's NOT_FOUND;
// an outage, an internal failure or a cancelled/expired request propagates so the client retries instead of
// treating a published article as gone.
func TestGetPublishedArticleAudienceErrors(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want connect.Code
		is   error
	}{
		{"not found", postNotFound(), connect.CodeNotFound, nil},
		{"posts sentinel", posts.ErrNotFound, connect.CodeNotFound, nil},
		{"unavailable", connect.NewError(connect.CodeUnavailable, errors.New("firestore down")), connect.CodeUnavailable, nil},
		{"internal", errors.New("posts: get: load post: boom"), connect.CodeInternal, nil},
		{"canceled", context.Canceled, connect.CodeInternal, context.Canceled},
		{"deadline", context.DeadlineExceeded, connect.CodeInternal, context.DeadlineExceeded},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, _, p, ctx := setup()
			save(t, s, ctx)
			if _, err := s.PublishArticle(ctx, publication()); err != nil {
				t.Fatal(err)
			}
			p.viewErr = tc.err
			bob := authn.WithClaims(ctx, authn.Claims{UID: "bob"})
			_, err := s.GetArticle(bob, connect.NewRequest(&av.GetArticleRequest{ArticleId: testID}))
			if got := apierr.ToConnect(err).Code(); got != tc.want {
				t.Fatalf("code = %v, want %v (err %v)", got, tc.want, err)
			}
			if tc.is != nil && !errors.Is(err, tc.is) {
				t.Fatalf("cause lost: %v", err)
			}
		})
	}
}
