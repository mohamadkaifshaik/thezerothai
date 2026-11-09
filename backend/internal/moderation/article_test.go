package moderation

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

type fakeArticleLookup struct {
	got           ReportedArticle
	err           error
	n             int
	article, post string
}

func (f *fakeArticleLookup) ReportedArticle(_ context.Context, articleID, postID string) (ReportedArticle, error) {
	f.n++
	f.article, f.post = articleID, postID
	return f.got, f.err
}

func (f *fixture) articleSvc(a ArticleLookup) Service {
	return New(Deps{
		Repo: f.repo, Posts: f.posts, Accounts: f.accounts, Directory: f.dir, Articles: a,
		ReportsPerDay: 20, NewAccountReportsPerDay: 5, NewAccountWindow: 24 * time.Hour,
		AllowAnonymous: true, Now: func() time.Time { return f.now },
	})
}

const okArticleID = "article-0000000000000001"

// TestReport_ArticleRootEvidence: a POST report of an article root keeps the article snapshot (id, title, revision,
// bounded body) taken at report time; a gone article keeps the post's frozen preview; a transient failure fails the
// report rather than filing it without the body; a plain post or a repost never asks.
func TestReport_ArticleRootEvidence(t *testing.T) {
	t.Parallel()
	snapshot := ReportedArticle{ArticleID: okArticleID, Title: "Live title", Revision: 7, Body: "Full body text", Truncated: true}
	tests := []struct {
		name      string
		article   *posts.ArticlePreview
		kind      posts.Kind
		lookup    *fakeArticleLookup
		nilLookup bool
		wantCalls int
		want      Evidence
		wantCode  connect.Code
	}{
		{name: "snapshot kept", article: &posts.ArticlePreview{ArticleID: okArticleID, Title: "Preview", Excerpt: "Excerpt"},
			lookup: &fakeArticleLookup{got: snapshot}, wantCalls: 1,
			want: Evidence{ArticleID: okArticleID, ArticleTitle: "Live title", ArticleRevision: 7, ArticleBody: "Full body text", ArticleBodyTruncated: true}},
		{name: "gone article keeps the preview", article: &posts.ArticlePreview{ArticleID: okArticleID, Title: "Preview", Excerpt: "Excerpt"},
			lookup: &fakeArticleLookup{err: fmt.Errorf("adapter: %w", ErrArticleNotFound)}, wantCalls: 1,
			want: Evidence{ArticleID: okArticleID, ArticleTitle: "Preview", ArticleBody: "Excerpt"}},
		{name: "unwired lookup keeps the preview", article: &posts.ArticlePreview{ArticleID: okArticleID, Title: "Preview", Excerpt: "Excerpt"},
			nilLookup: true, want: Evidence{ArticleID: okArticleID, ArticleTitle: "Preview", ArticleBody: "Excerpt"}},
		{name: "transient failure fails the report", article: &posts.ArticlePreview{ArticleID: okArticleID},
			lookup: &fakeArticleLookup{err: errors.New("unavailable")}, wantCalls: 1, wantCode: connect.CodeInternal},
		{name: "plain post never asks", lookup: &fakeArticleLookup{got: snapshot}},
		{name: "a repost never asks", article: &posts.ArticlePreview{ArticleID: okArticleID}, kind: posts.KindRepost,
			lookup: &fakeArticleLookup{got: snapshot}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			f := newFixture()
			f.posts.post.Article = tt.article
			if tt.kind != "" {
				f.posts.post.Kind = tt.kind
			}
			var lookup ArticleLookup = tt.lookup
			if tt.nilLookup {
				lookup = nil
			}
			_, err := f.articleSvc(lookup).Report(gctx(), reporter, okInput())
			if tt.lookup != nil && tt.lookup.n != tt.wantCalls {
				t.Fatalf("lookup calls = %d, want %d", tt.lookup.n, tt.wantCalls)
			}
			if tt.wantCalls > 0 && (tt.lookup.article != okArticleID || tt.lookup.post != okPostID) {
				t.Fatalf("lookup(%q, %q)", tt.lookup.article, tt.lookup.post)
			}
			if tt.wantCode != 0 {
				if got := apierr.ToConnect(err).Code(); got != tt.wantCode {
					t.Fatalf("code = %v, want %v (%v)", got, tt.wantCode, err)
				}
				if len(f.repo.calls) != 0 {
					t.Fatal("report filed without its article evidence")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			ev := f.repo.calls[0].Report.Evidence
			if tt.kind == posts.KindRepost || tt.article == nil {
				if ev.ArticleID != "" || ev.ArticleBody != "" {
					t.Fatalf("article fields on a non-article report: %#v", ev)
				}
				return
			}
			got := Evidence{ArticleID: ev.ArticleID, ArticleTitle: ev.ArticleTitle, ArticleRevision: ev.ArticleRevision, ArticleBody: ev.ArticleBody, ArticleBodyTruncated: ev.ArticleBodyTruncated}
			if fmt.Sprint(got) != fmt.Sprint(tt.want) {
				t.Fatalf("evidence = %#v, want %#v", got, tt.want)
			}
			if ev.Text != "hello" {
				t.Fatalf("post evidence lost: %q", ev.Text)
			}
		})
	}
}
