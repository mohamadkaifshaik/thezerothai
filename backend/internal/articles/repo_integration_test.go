//go:build integration

package articles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/media"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/snowflake"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
	"google.golang.org/api/option"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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
	checkAt := time.Now().Add(media.OrphanAfter).UTC()
	coverDoc := &media.Doc{OwnerID: uid, Purpose: string(media.PurposePost), Status: string(media.StatusReady), ContentType: media.ContentTypeJPEG, PublicPath: "article-cover.jpg", ThumbPath: "article-cover-thumb.jpg", Width: 1280, Height: 720, OrphanCheckAt: &checkAt}
	if _, err = client.Collection("media").Doc(coverID).Set(ctx, coverDoc); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = client.Collection("media").Doc(coverID).Delete(context.Background()) }()
	lib := media.NewLibrary(media.NewFirestoreRepo(client, media.WriteDeps{}), "https://media.example")
	if _, err = lib.ResolvePostCover(ctx, uid, coverID); err != nil {
		t.Fatalf("draft cover resolver: %v", err)
	}
	pr := posts.NewFirestoreRepo(client)
	pr.SetWriters(posts.WriteDeps{Idempotency: idempotency.New(client), Counters: identity.NewFirestoreRepo(client, nil), IDs: node, Media: testMediaAttacher{lib}})
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
	in := posts.CreateParams{AuthorID: uid, IdemKey: key, RequestHash: "article-hash", ArticlePublication: &publicationIntent{repo: r, expected: a, now: time.Now()}, Draft: posts.Post{AuthorID: uid, Kind: posts.KindPost, Text: "Title", Article: &posts.ArticlePreview{ArticleID: id, Title: a.Title}}}
	// A media id that does not exist fails the transaction after the article claim was read, so nothing may be finalized.
	in.MediaIDs = []string{node.Generate()}
	if _, err = pr.Create(ctx, in); err == nil {
		t.Fatal("a transaction with a missing image unexpectedly committed")
	}
	loaded, err := r.get(ctx, id)
	if err != nil || loaded.Published {
		t.Fatalf("article finalized without root: %v", err)
	}
	in.MediaIDs = []string{coverID}
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
	// The article publication attaches the cover through Claim.Attach, which removes the orphan sweep's check.
	if covers, err := media.NewFirestoreRepo(client, media.WriteDeps{}).GetMany(ctx, []string{coverID}); err != nil || covers[coverID].PostID != result.Post.ID || covers[coverID].OrphanCheckAt != nil {
		t.Fatalf("published cover = %+v, %v: want attached with no orphanCheckAt", covers[coverID], err)
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

// TestFirestoreDeleteByRoot: the post_delete articles step removes only the author's published article rooted at the
// deleted post (single-field postId equality; no composite index), and a replay is a noop.
func TestFirestoreDeleteByRoot(t *testing.T) {
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
	n := time.Now().UnixNano()
	uid := fmt.Sprintf("root-owner-%d", n)
	postID := fmt.Sprintf("%019d", n)
	otherPost := fmt.Sprintf("%019d", n+1)
	rows := map[string]record{
		fmt.Sprintf("root-%d-published", n): {AuthorID: uid, Revision: 1, Title: "T", Body: testBody, PostID: postID, Published: true},
		fmt.Sprintf("root-%d-foreign", n):   {AuthorID: uid + "-other", Revision: 1, Title: "T", Body: testBody, PostID: postID, Published: true},
		fmt.Sprintf("root-%d-elsewhere", n): {AuthorID: uid, Revision: 1, Title: "T", Body: testBody, PostID: otherPost, Published: true},
	}
	for id, r := range rows {
		if _, err = client.Collection("articles").Doc(id).Set(ctx, r); err != nil {
			t.Fatal(err)
		}
		defer func(id string) { _, _ = client.Collection("articles").Doc(id).Delete(context.Background()) }(id)
	}
	repo := &firestoreRepo{client}
	deleted, err := repo.deleteByRoot(ctx, uid, postID)
	if err != nil || !deleted {
		t.Fatalf("deleteByRoot = %v, %v", deleted, err)
	}
	for id := range rows {
		_, err := client.Collection("articles").Doc(id).Get(ctx)
		gone := status.Code(err) == codes.NotFound
		if want := strings.HasSuffix(id, "-published"); gone != want {
			t.Fatalf("%s gone = %v, want %v (%v)", id, gone, want, err)
		}
	}
	if deleted, err = repo.deleteByRoot(ctx, uid, postID); err != nil || deleted {
		t.Fatalf("replay = %v, %v", deleted, err)
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

// TestFirestoreDraftCap runs the transactional draft count against Firestore: only the caller's unpublished
// drafts count (published articles and another author's drafts never do), the read stops at cap+1, a new id
// is refused at the cap, and an existing draft is still saved there.
func TestFirestoreDraftCap(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires Firestore emulator")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	client, err := firestore.NewClient(ctx, "demo-articles-integration", option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	prefix := fmt.Sprintf("draft-cap-%d", time.Now().UnixNano())
	uid, other := prefix+"-owner", prefix+"-other"
	var ids []string
	put := func(id string, a *record) {
		t.Helper()
		ids = append(ids, id)
		if _, err := client.Collection("articles").Doc(id).Set(ctx, a); err != nil {
			t.Fatal(err)
		}
	}
	defer func() {
		for _, id := range ids {
			_, _ = client.Collection("articles").Doc(id).Delete(context.Background())
		}
	}()
	now := time.Now().UTC()
	for i := range maxDraftsPerAuthor - 1 {
		put(fmt.Sprintf("%s-d%03d", prefix, i), &record{AuthorID: uid, Revision: 1, Title: "Draft", Body: testBody, UpdatedAt: now})
	}
	for i := range 3 {
		put(fmt.Sprintf("%s-p%03d", prefix, i), &record{AuthorID: uid, Revision: 1, Title: "Published", Body: testBody, PostID: "1000000000000000009", Published: true, UpdatedAt: now})
		put(fmt.Sprintf("%s-o%03d", prefix, i), &record{AuthorID: other, Revision: 1, Title: "Other", Body: testBody, UpdatedAt: now})
	}
	s := &Server{repo: &firestoreRepo{client}, flags: testFlags(true), now: time.Now}
	actx := authn.WithClaims(ctx, authn.Claims{UID: uid})
	saveNew := func(id string) error {
		ids = append(ids, id)
		_, err := s.SaveArticle(actx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: id, Title: "Title", BodyJson: testBody}}))
		return err
	}
	// 49 drafts: the 50th is allowed.
	if err = saveNew(prefix + "-new050"); err != nil {
		t.Fatalf("50th draft: %v", err)
	}
	// 50 drafts: the 51st is refused and not stored.
	err = saveNew(prefix + "-new051")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Reason != commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED || ae.Metadata["limit"] != draftLimitName {
		t.Fatalf("51st draft: %v", err)
	}
	if _, err = client.Collection("articles").Doc(prefix + "-new051").Get(ctx); status.Code(err) != codes.NotFound {
		t.Fatalf("refused draft stored: %v", err)
	}
	// An existing draft is still saved at the cap.
	if _, err = s.SaveArticle(actx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: prefix + "-d000", Title: "Edited", BodyJson: testBody}, ExpectedRevision: 1})); err != nil {
		t.Fatalf("edit at cap: %v", err)
	}
	// Over the cap the read stops at cap+1 documents.
	put(prefix+"-d900", &record{AuthorID: uid, Revision: 1, UpdatedAt: now})
	put(prefix+"-d901", &record{AuthorID: uid, Revision: 1, UpdatedAt: now})
	repo := &firestoreRepo{client}
	var counted int
	if _, err = repo.saveDraft(ctx, prefix+"-probe", uid, func(_ *record, drafts func() (int, error)) (*record, error) {
		var e error
		counted, e = drafts()
		return nil, e
	}); err != nil {
		t.Fatal(err)
	}
	if counted != maxDraftsPerAuthor+1 {
		t.Fatalf("counted %d drafts, want the read bounded at %d", counted, maxDraftsPerAuthor+1)
	}
}
