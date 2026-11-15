package posts

import (
	"reflect"
	"testing"
	"time"

	postsv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/posts/v1"
)

func TestArticlePreviewRoundTripAndFrozenCopy(t *testing.T) {
	p := &Post{ID: "0000000000000000001", AuthorID: "a", Kind: KindPost, CreatedAt: time.Unix(1, 0),
		Article: &ArticlePreview{ArticleID: "article", Title: "Title", Excerpt: "Body", CoverURL: "https://example.com/image", ReadMinutes: 5}}
	got := toDoc(p).toPost(p.ID)
	if !toDoc(p).HasArticle || toDoc(&Post{Kind: KindPost}).HasArticle || toDoc(&Post{Kind: KindReply, Article: p.Article}).HasArticle || toDoc(&Post{Kind: KindRepost, Article: p.Article}).HasArticle {
		t.Fatal("hasArticle must identify original article roots only")
	}
	if !reflect.DeepEqual(got.Article, p.Article) {
		t.Fatal("article preview lost in Firestore roundtrip")
	}
	if got.Article == p.Article {
		t.Fatal("stored snapshot aliases input")
	}
	copy := snapshotOf(p)
	p.Article.Title = "Changed"
	if copy.Article.Title != "Title" {
		t.Fatal("embedded article preview was not frozen")
	}
	repost := &Post{ID: "2", Kind: KindRepost, Embedded: copy}
	restored := toDoc(repost).toPost(repost.ID)
	if !reflect.DeepEqual(restored.Embedded.Article, copy.Article) {
		t.Fatal("embedded preview lost in Firestore roundtrip")
	}
	wire := ToProto(restored)
	if wire.GetEmbedded().GetArticle().GetArticleId() != "article" {
		t.Fatal("embedded wire preview missing")
	}
	if ToProto(got).GetArticle().GetTitle() != "Title" {
		t.Fatal("root wire preview missing")
	}
	if got.Article.ReadMinutes != 5 || ToProto(got).GetArticle().GetReadMinutes() != 5 || wire.GetEmbedded().GetArticle().GetReadMinutes() != 5 {
		t.Fatal("read minutes lost in Firestore or wire roundtrip")
	}
}

// TestArticlePreviewReadMinutesSnapshot: the field is additive. A preview stored before it existed has no readMinutes
// key and reads (and goes on the wire) as 0 = unknown; a set value maps to and from the Firestore field by name.
func TestArticlePreviewReadMinutesSnapshot(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   *ArticlePreview
		want int32
	}{
		{"legacy preview is unknown", &ArticlePreview{ArticleID: "a", Title: "T", Excerpt: "E"}, 0},
		{"one minute", &ArticlePreview{ArticleID: "a", Title: "T", ReadMinutes: 1}, 1},
		{"long read", &ArticlePreview{ArticleID: "a", Title: "T", ReadMinutes: 44}, 44},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := &Post{ID: "0000000000000000001", AuthorID: "a", Kind: KindPost, CreatedAt: time.Unix(1, 0), Article: tc.in}
			got := toDoc(p).toPost(p.ID)
			if got.Article.ReadMinutes != tc.want || ToProto(got).GetArticle().GetReadMinutes() != tc.want {
				t.Fatalf("read minutes = %d / %d, want %d", got.Article.ReadMinutes, ToProto(got).GetArticle().GetReadMinutes(), tc.want)
			}
			field, ok := reflect.TypeOf(ArticlePreview{}).FieldByName("ReadMinutes")
			if !ok || field.Tag.Get("firestore") != "readMinutes,omitempty" {
				t.Fatalf("firestore tag = %q", field.Tag.Get("firestore"))
			}
		})
	}
	if articleToProto(nil) != nil || cloneArticle(nil) != nil {
		t.Fatal("nil preview must stay nil")
	}
}

func TestArticlePreviewTombstoneAndProtectedCopyHideContent(t *testing.T) {
	e := &Embedded{PostID: "1", Unavailable: true, Article: &ArticlePreview{ArticleID: "secret", Title: "Secret"}}
	p := &Post{ID: "2", Kind: KindRepost, Embedded: e}
	if toDoc(p).Embedded.Article != nil || ToProto(p).GetEmbedded().GetArticle() != nil {
		t.Fatal("tombstone leaked article metadata")
	}
	e.Unavailable = false
	v := &postsv1.PostView{Post: ToProto(p)}
	ApplyEmbedState(v, postsv1.EmbedViewerState_EMBED_VIEWER_STATE_PROTECTED)
	if v.Post.Embedded.Article != nil {
		t.Fatal("protected embed leaked article metadata")
	}
	v = &postsv1.PostView{Post: ToProto(&Post{Article: e.Article})}
	ApplyWithheld(v)
	if v.Post.Article != nil {
		t.Fatal("withheld post leaked article metadata")
	}
}

func TestArticlePreviewRequestHash(t *testing.T) {
	if articleRequestHash("legacy", nil) != "legacy" {
		t.Fatal("legacy request hash changed")
	}
	a := &ArticlePreview{ArticleID: "1", Title: "title", Excerpt: "body", CoverURL: "https://a"}
	base := articleRequestHash("base", a)
	for _, changed := range []*ArticlePreview{
		{ArticleID: "2", Title: a.Title, Excerpt: a.Excerpt, CoverURL: a.CoverURL},
		{ArticleID: a.ArticleID, Title: "other", Excerpt: a.Excerpt, CoverURL: a.CoverURL},
		{ArticleID: a.ArticleID, Title: a.Title, Excerpt: "other", CoverURL: a.CoverURL},
		{ArticleID: a.ArticleID, Title: a.Title, Excerpt: a.Excerpt, CoverURL: "https://b"},
	} {
		if articleRequestHash("base", changed) == base {
			t.Fatal("changed preview reused request hash")
		}
	}
}
