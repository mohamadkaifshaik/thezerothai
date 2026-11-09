//go:build integration

package moderation

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
)

// A POST report of an article root keeps the article snapshot inside the index-exempt evidence map of the report
// document: no new collection, no evidence child document.
func TestRepo_ArticleEvidenceRoundTrip(t *testing.T) {
	client := newTestClient(t)
	repo := NewFirestoreRepo(client, quota.New(client))
	t0 := time.Date(2026, 11, 8, 0, 0, 0, 0, time.UTC)
	rep := sampleReport("u-rep-article", TargetPost, pidN(89), "u-author", t0)
	rep.Evidence = &Evidence{Text: "caption", AuthorHandle: "alice", PostCreatedAt: t0.Add(-time.Hour),
		ArticleID: "article-0000000000000001", ArticleTitle: "Title", ArticleRevision: 4, ArticleBody: "Body text", ArticleBodyTruncated: true}
	ctx := context.Background()
	if _, err := repo.Create(ctx, CreateParams{Report: rep, QuotaLimit: 5}); err != nil {
		t.Fatal(err)
	}
	got, err := repo.Get(ctx, rep.ID)
	if err != nil || got.Evidence == nil {
		t.Fatalf("stored = %+v err=%v", got, err)
	}
	e := got.Evidence
	if e.Text != "caption" || e.ArticleID != "article-0000000000000001" || e.ArticleTitle != "Title" || e.ArticleRevision != 4 || e.ArticleBody != "Body text" || !e.ArticleBodyTruncated {
		t.Fatalf("evidence = %+v", e)
	}
	kids, err := client.Collection("reports").Doc(rep.ID).Collection("evidence").Documents(ctx).GetAll()
	if err != nil || len(kids) != 0 {
		t.Fatalf("evidence children = %d err=%v, want 0", len(kids), err)
	}
}
