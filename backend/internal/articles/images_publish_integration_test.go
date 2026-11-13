//go:build integration

package articles

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"google.golang.org/api/option"

	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// testImageAttacher is the apiserver adapter over media.Library.LoadForArticle: a refusal becomes ErrImageNotReady.
type testImageAttacher struct{ lib *media.Library }

func (a testImageAttacher) LoadForArticle(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (ImageClaim, error) {
	c, err := a.lib.LoadForArticle(ctx, tx, uid, ids)
	switch {
	case media.IsNotReady(err):
		return nil, ErrImageNotReady
	case err != nil:
		return nil, err
	}
	return c, nil
}

type testImageClaim struct{ c *media.Claim }

func (c testImageClaim) Attach(b store.Batch, postID string) { c.c.Attach(b, postID) }

// TestFirestoreArticlePublishAttachesInlineImages: publication claims the body's inline images for the new root post in the
// same transaction as the root (postId set, orphanCheckAt removed, the images are not the post's own media). A body naming
// an image the author does not have leaves the article unpublished and returns ErrImageNotReady.
func TestFirestoreArticlePublishAttachesInlineImages(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires Firestore emulator")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := firestore.NewClient(ctx, "demo-articles-integration", option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	id := fmt.Sprintf("inline-publish-%d", time.Now().UnixNano())
	uid := id + "-owner"
	if _, err = client.Collection("users").Doc(uid).Set(ctx, map[string]any{"postsCount": int64(0)}); err != nil {
		t.Fatal(err)
	}
	imageID := node.Generate()
	missingID := node.Generate()
	checkAt := time.Now().Add(media.OrphanAfter).UTC()
	imageDoc := &media.Doc{OwnerID: uid, Purpose: string(media.PurposePost), Status: string(media.StatusReady), ContentType: media.ContentTypeJPEG, PublicPath: "inline.jpg", ThumbPath: "inline-thumb.jpg", Width: 800, Height: 600, OrphanCheckAt: &checkAt}
	if _, err = client.Collection("media").Doc(imageID).Set(ctx, imageDoc); err != nil {
		t.Fatal(err)
	}
	lib := media.NewLibrary(media.NewFirestoreRepo(client, media.WriteDeps{}), "https://media.example")
	pr := posts.NewFirestoreRepo(client)
	pr.SetWriters(posts.WriteDeps{Idempotency: idempotency.New(client), Counters: identity.NewFirestoreRepo(client, nil), IDs: node})
	r := &firestoreRepo{client}

	defer func() {
		docs, _ := client.Collection("posts").Where("authorId", "==", uid).Documents(context.Background()).GetAll()
		for _, d := range docs {
			_, _ = d.Ref.Delete(context.Background())
		}
		for _, ref := range []*firestore.DocumentRef{client.Collection("articles").Doc(id), client.Collection("users").Doc(uid), client.Collection("media").Doc(imageID)} {
			_, _ = ref.Delete(context.Background())
		}
	}()

	bodyWith := func(imageRef string) string {
		return `[{"kind":"image","runs":[],"mediaId":"` + imageRef + `","altText":"a test image","caption":"Sunday"}]`
	}
	article := &record{ID: id, AuthorID: uid, Revision: 1, Title: "Inline title", Body: bodyWith(missingID), ImageMediaIDs: []string{missingID}, PendingKey: "inline-key-1", PendingAt: time.Now(), UpdatedAt: time.Now()}
	if _, err = r.change(ctx, id, func(*record) (*record, error) { return article, nil }); err != nil {
		t.Fatal(err)
	}
	key := idempotency.Key(uid, "CreatePost", "inline-key-1")
	in := posts.CreateParams{AuthorID: uid, IdemKey: key, RequestHash: "inline-hash", ArticlePublication: &publicationIntent{repo: r, expected: article, now: time.Now(), uid: uid, images: testImageAttacher{lib}}, Draft: posts.Post{AuthorID: uid, Kind: posts.KindPost, Text: "Inline title", Article: &posts.ArticlePreview{ArticleID: id, Title: article.Title}}}

	// A body naming an image the author does not have: refused, nothing finalized.
	if _, err = pr.Create(ctx, in); !errors.Is(err, ErrImageNotReady) {
		t.Fatalf("publishing a missing inline image: err = %v, want ErrImageNotReady", err)
	}
	if loaded, err := r.get(ctx, id); err != nil || loaded.Published {
		t.Fatalf("article finalized with a missing image: %v", err)
	}

	// The image is the author's and ready: the publication attaches it to the root post.
	article.Body = bodyWith(imageID)
	article.ImageMediaIDs = []string{imageID}
	if _, err = r.change(ctx, id, func(*record) (*record, error) { return article, nil }); err != nil {
		t.Fatal(err)
	}
	result, err := pr.Create(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if result.Post == nil || len(result.Post.Media) != 0 {
		t.Fatalf("inline image became the post's own media: %+v", result.Post)
	}
	stored, err := media.NewFirestoreRepo(client, media.WriteDeps{}).GetMany(ctx, []string{imageID})
	if err != nil || stored[imageID] == nil || stored[imageID].PostID != result.Post.ID || stored[imageID].OrphanCheckAt != nil {
		t.Fatalf("inline image after publish = %+v, %v: want attached to the root with no orphanCheckAt", stored[imageID], err)
	}
	loaded, err := r.get(ctx, id)
	if err != nil || !loaded.Published || loaded.PostID != result.Post.ID {
		t.Fatalf("article not published with its root: %#v %v", loaded, err)
	}
	// Once attached, the image is no longer the author's draft image (ResolveArticleImages with postID "" refuses it).
	if drafts, err := lib.ResolveArticleImages(ctx, uid, "", []string{imageID}); err != nil || len(drafts) != 0 {
		t.Fatalf("attached image still resolves for a draft: %v %v", drafts, err)
	}
	if attached, err := lib.ResolveArticleImages(ctx, uid, result.Post.ID, []string{imageID}); err != nil || attached[imageID].ID == "" {
		t.Fatalf("attached image does not resolve for its article: %v %v", attached, err)
	}
}
