//go:build integration

package articles

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
	"connectrpc.com/connect"
	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/authn"
	"google.golang.org/api/option"
)

type replacementOnReadRepo struct {
	repository
	afterGet func(context.Context) error
}

func (r *replacementOnReadRepo) get(ctx context.Context, id string) (*record, error) {
	a, err := r.repository.get(ctx, id)
	if err == nil && r.afterGet != nil {
		hook := r.afterGet
		r.afterGet = nil
		if err := hook(ctx); err != nil {
			return nil, err
		}
	}
	return a, err
}

func TestFirestoreSubscriptionGateAndReplacedReplay(t *testing.T) {
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("requires isolated demo-dzeroth-local emulator")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	client, err := firestore.NewClient(ctx, "demo-dzeroth-local", option.WithoutAuthentication())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	id := fmt.Sprintf("11111111-1111-4111-8111-%012x", uint64(time.Now().UnixNano())&0xffffffffffff)
	defer func() { _, _ = client.Collection("articles").Doc(id).Delete(context.Background()) }()
	base := &firestoreRepo{client}
	repo := &replacementOnReadRepo{repository: base}
	p := &fakePosts{created: map[string]*posts.Post{}}
	s := &Server{repo: repo, posts: p, audience: p, flags: testFlags(true), now: time.Now}
	actx := authn.WithClaims(ctx, authn.Claims{UID: "subscription-emulator-publisher"})
	_, err = s.SaveArticle(actx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: id, Title: "Title", BodyJson: testBody}}))
	if err != nil {
		t.Fatal(err)
	}
	request := connect.NewRequest(&av.PublishArticleRequest{ArticleId: id, ExpectedRevision: 1, IdempotencyKey: "subscription-test-key"})
	if _, err = s.PublishArticle(actx, request); connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("missing verifier: %v", err)
	}
	draft, err := base.get(ctx, id)
	if err != nil || draft.Published || draft.PendingKey != "" || p.calls != 0 {
		t.Fatal("missing verification wrote publication state")
	}
	s.WithPublishingAccess(func(context.Context, string) error { return nil })
	if _, err = s.PublishArticle(actx, request); err != nil {
		t.Fatal(err)
	}
	s.WithPublishingAccess(nil)
	// A completed replay is still readable with billing disabled.
	if _, err = s.PublishArticle(actx, request); err != nil {
		t.Fatalf("completed replay: %v", err)
	}
	clear(p.created) // the old root idempotency record has expired
	p.calls = 0
	repo.afterGet = func(ctx context.Context) error {
		if _, err := base.change(ctx, id, func(*record) (*record, error) { return nil, nil }); err != nil {
			return err
		}
		_, err := base.change(ctx, id, func(*record) (*record, error) { return clone(draft), nil })
		return err
	}
	if _, err = s.PublishArticle(actx, request); connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("replacement replay: %v", err)
	}
	a, err := base.get(ctx, id)
	if err != nil || a.Published || a.PendingKey != "" || p.calls != 0 {
		t.Fatal("replacement inherited the old publication's paid exemption")
	}
}
