//go:build integration

package articles

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/quota"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
	"google.golang.org/api/option"
)

func TestFirestoreRevisionPublicationAndLifecycle(t *testing.T) {
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
	id := fmt.Sprintf("article-test-%d", time.Now().UnixNano())
	uid := id + "-owner"
	defer func() { _, _ = client.Collection("articles").Doc(id).Delete(context.Background()) }()
	repo := &firestoreRepo{client}
	now := time.Now().UTC()
	_, err = repo.change(ctx, id, func(a *record) (*record, error) {
		if a != nil {
			return nil, errorsTest("collision")
		}
		return &record{ID: id, AuthorID: uid, Revision: 1, Title: "Title", Body: testBody, UpdatedAt: now}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	saved, err := repo.get(ctx, id)
	if err != nil || saved.ID != id || saved.Revision != 1 {
		t.Fatalf("stored roundtrip: %#v %v", saved, err)
	}
	pending, err := repo.change(ctx, id, func(a *record) (*record, error) { a.PendingKey = "stable-replay-key"; a.PendingAt = now; return a, nil })
	if err != nil {
		t.Fatal(err)
	}
	if pending.PendingKey == "" {
		t.Fatal("publication intent not durable")
	}
	// A fresh repository instance observes the frozen record after a lost reply.
	fresh := &firestoreRepo{client}
	loaded, err := fresh.get(ctx, id)
	if err != nil || loaded.PendingKey != pending.PendingKey {
		t.Fatalf("recovery roundtrip: %v", err)
	}
	rows, err := fresh.list(ctx, uid, false, 20, "")
	if err != nil || len(rows) != 1 {
		t.Fatalf("draft query: %d %v", len(rows), err)
	}
	lifecycle := NewLifecycle(client)
	var out strings.Builder
	if err = lifecycle.WriteSection(ctx, uid, &out); err != nil {
		t.Fatal(err)
	}
	var exported []map[string]any
	if err = json.Unmarshal([]byte(out.String()), &exported); err != nil || len(exported) != 1 {
		t.Fatalf("export: %s %v", out.String(), err)
	}
	if strings.Contains(out.String(), "stable-replay-key") {
		t.Fatal("export disclosed replay key")
	}
	_, done, err := lifecycle.Run(ctx, uid, nil)
	if err != nil || !done {
		t.Fatalf("erase: %t %v", done, err)
	}
	if _, err = fresh.get(ctx, id); err == nil {
		t.Fatal("body retained after account erasure")
	}
}

type errorsTest string

func (e errorsTest) Error() string { return string(e) }

func TestFirestoreRootAndArticleCommitAtomically(t *testing.T) {
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
	id := fmt.Sprintf("atomic-article-%d", time.Now().UnixNano())
	uid := id + "-owner"
	_, err = client.Collection("users").Doc(uid).Set(ctx, map[string]any{"postsCount": int64(0)})
	if err != nil {
		t.Fatal(err)
	}
	r := &firestoreRepo{client}
	a := &record{ID: id, AuthorID: uid, Revision: 1, Title: "Atomic title", Body: testBody, PendingKey: "publication-key-1", PendingAt: time.Now(), UpdatedAt: time.Now()}
	if _, err = r.change(ctx, id, func(*record) (*record, error) { return a, nil }); err != nil {
		t.Fatal(err)
	}
	node, err := snowflake.NewNode()
	if err != nil {
		t.Fatal(err)
	}
	coverID := node.Generate()
	coverDoc := &media.Doc{OwnerID: uid, Purpose: string(media.PurposePost), Status: string(media.StatusReady), ContentType: media.ContentTypeJPEG, PublicPath: "article-cover.jpg", ThumbPath: "article-cover-thumb.jpg", Width: 1280, Height: 720}
	if _, err = client.Collection("media").Doc(coverID).Set(ctx, coverDoc); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = client.Collection("media").Doc(coverID).Delete(context.Background()) }()
	lib := media.NewLibrary(media.NewFirestoreRepo(client, media.WriteDeps{}), "https://media.example")
	if _, err = lib.ResolvePostCover(ctx, uid, coverID); err != nil {
		t.Fatalf("draft cover resolver: %v", err)
	}
	pr := posts.NewFirestoreRepo(client)
	pr.SetWriters(posts.WriteDeps{Idempotency: idempotency.New(client), Quotas: quota.New(client), Counters: identity.NewFirestoreRepo(client, nil), IDs: node, Media: testMediaAttacher{lib}})
	key := idempotency.Key(uid, "CreatePost", "publication-key-1")
	defer func() {
		docs, _ := client.Collection("posts").Where("authorId", "==", uid).Documents(context.Background()).GetAll()
		for _, d := range docs {
			_, _ = d.Ref.Delete(context.Background())
		}
		for _, ref := range []*firestore.DocumentRef{client.Collection("articles").Doc(id), client.Collection("users").Doc(uid), client.Collection("quotas").Doc(uid), client.Collection("idempotency").Doc(key)} {
			_, _ = ref.Delete(context.Background())
		}
	}()
	in := posts.CreateParams{AuthorID: uid, IdemKey: key, RequestHash: "article-hash", QuotaLimit: 0, ArticlePublication: &publicationIntent{repo: r, expected: a, now: time.Now()}, Draft: posts.Post{AuthorID: uid, Kind: posts.KindPost, Text: "Title", Article: &posts.ArticlePreview{ArticleID: id, Title: a.Title}}}
	in.MediaIDs = []string{coverID}
	if _, err = pr.Create(ctx, in); err == nil {
		t.Fatal("quota-zero transaction unexpectedly committed")
	}
	loaded, err := r.get(ctx, id)
	if err != nil || loaded.Published {
		t.Fatalf("article finalized without root: %v", err)
	}
	in.QuotaLimit = 100
	result, err := pr.Create(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if result.Post == nil {
		t.Fatal("missing root")
	}
	articleRows, err := pr.ByAuthorArticles(ctx, uid, posts.Window{}, 20)
	if err != nil || len(articleRows) != 1 || articleRows[0].ID != result.Post.ID {
		t.Fatalf("profile article query: %d %v", len(articleRows), err)
	}
	position := &posts.Position{ID: result.Post.ID, CreatedAt: result.Post.CreatedAt}
	older, err := pr.ByAuthorArticles(ctx, uid, posts.Window{Before: position}, 20)
	if err != nil || len(older) != 0 {
		t.Fatalf("article paging repeats boundary: %d %v", len(older), err)
	}
	newer, err := pr.ByAuthorArticles(ctx, uid, posts.Window{After: position}, 20)
	if err != nil || len(newer) != 0 {
		t.Fatalf("article refresh repeats boundary: %d %v", len(newer), err)
	}
	if result.Post.Article.CoverURL != "https://media.example/article-cover.jpg" {
		t.Fatal("immediate root preview lacks validated cover")
	}
	stored, err := pr.GetAll(ctx, []string{result.Post.ID})
	if err != nil || stored[result.Post.ID].Article.CoverURL != result.Post.Article.CoverURL {
		t.Fatalf("persisted cover mismatch: %v", err)
	}
	if _, err = lib.ResolvePostCover(ctx, uid, coverID); !media.IsNotReady(err) {
		t.Fatalf("claimed cover still available to drafts: %v", err)
	}
	loaded, err = r.get(ctx, id)
	if err != nil || !loaded.Published || loaded.PostID != result.Post.ID {
		t.Fatalf("root committed without article: %#v %v", loaded, err)
	}
	replay, err := pr.Create(ctx, in)
	if err != nil || replay.ReplayID != result.Post.ID {
		t.Fatalf("root replay: %#v %v", replay, err)
	}
	// Simulate expiry of the post idempotency record. The article claim still
	// prevents any stale publisher from creating a second timeline root.
	if _, err = client.Collection("idempotency").Doc(key).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = pr.Create(ctx, in); err == nil {
		t.Fatal("stale publisher recreated article root after expiry")
	}
	docs, err := client.Collection("posts").Where("authorId", "==", uid).Documents(ctx).GetAll()
	if err != nil || len(docs) != 1 {
		t.Fatalf("root count %d %v", len(docs), err)
	}
}

type testMediaAttacher struct{ lib *media.Library }

func (a testMediaAttacher) LoadForPost(ctx context.Context, tx *firestore.Transaction, uid string, ids []string) (posts.MediaClaim, error) {
	c, err := a.lib.LoadForPost(ctx, tx, uid, ids)
	if err != nil {
		return nil, err
	}
	return testMediaClaim{c}, nil
}

type testMediaClaim struct{ claim *media.Claim }

func (c testMediaClaim) Refs() []posts.MediaRef {
	out := make([]posts.MediaRef, 0, len(c.claim.Refs))
	for _, r := range c.claim.Refs {
		out = append(out, posts.MediaRef{ID: r.ID, URL: r.URL, ThumbURL: r.ThumbURL, Width: r.Width, Height: r.Height, ContentType: r.ContentType})
	}
	return out
}
func (c testMediaClaim) HasGIF() bool                    { return false }
func (c testMediaClaim) Attach(b store.Batch, id string) { c.claim.Attach(b, id) }
