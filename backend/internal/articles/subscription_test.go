package articles

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"
)

func TestPaidPublicationRejectionDoesNotFreezeDraft(t *testing.T) {
	s, repo, p, ctx := setup()
	save(t, s, ctx)
	s.WithPublishingAccess(func(_ context.Context, uid string) error {
		if uid != "alice" {
			t.Fatal("wrong publishing owner")
		}
		return connect.NewError(connect.CodePermissionDenied, errors.New("Premium required"))
	})
	_, err := s.PublishArticle(ctx, publication())
	if connect.CodeOf(err) != connect.CodePermissionDenied {
		t.Fatalf("error=%v", err)
	}
	a, err := repo.get(ctx, testID)
	if err != nil || a.Published || a.PendingKey != "" || len(p.created) != 0 {
		t.Fatal("paid rejection changed draft/publication")
	}
}

func TestCompletedPublicationReplaySurvivesSubscriptionExpiry(t *testing.T) {
	s, _, _, ctx := setup()
	save(t, s, ctx)
	s.WithPublishingAccess(func(context.Context, string) error { return nil })
	first, err := s.PublishArticle(ctx, publication())
	if err != nil {
		t.Fatal(err)
	}
	s.WithPublishingAccess(func(context.Context, string) error {
		t.Fatal("completed replay attempted a new paid mutation")
		return errors.New("expired")
	})
	replay, err := s.PublishArticle(ctx, publication())
	if err != nil || replay.Msg.Article.PostId != first.Msg.Article.PostId {
		t.Fatalf("replay=%v error=%v", replay, err)
	}
}

func TestUnconfiguredPublishingAccessFailsClosed(t *testing.T) {
	s, repo, p, ctx := setup()
	save(t, s, ctx)
	s.WithPublishingAccess(nil)
	_, err := s.PublishArticle(ctx, publication())
	if connect.CodeOf(err) != connect.CodeUnavailable {
		t.Fatalf("unconfigured verifier accepted publication: %v", err)
	}
	a, err := repo.get(ctx, testID)
	if err != nil || a.Published || a.PendingKey != "" || p.calls != 0 {
		t.Fatal("unconfigured publication changed the draft or created a post")
	}
}

func TestReplayCannotPublishReplacementDraft(t *testing.T) {
	s, repo, p, ctx := setup()
	save(t, s, ctx)
	draft, _ := repo.get(ctx, testID)
	s.WithPublishingAccess(func(context.Context, string) error { return nil })
	if _, err := s.PublishArticle(ctx, publication()); err != nil {
		t.Fatal(err)
	}
	s.WithPublishingAccess(func(context.Context, string) error {
		return connect.NewError(connect.CodePermissionDenied, errors.New("Premium expired"))
	})
	// Model delete/recreate after the replay pre-read, with the same author,
	// client-selected ID and revision. No root replay record remains.
	clear(p.created)
	p.calls = 0
	repo.beforeChange = func(*record) {
		replacement := clone(draft)
		replacement.Title = "Replacement article"
		repo.rows[testID] = replacement
	}
	_, err := s.PublishArticle(ctx, publication())
	if connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("replacement passed the old article's replay exemption: %v", err)
	}
	a, err := repo.get(ctx, testID)
	if err != nil || a.Published || a.PendingKey != "" || p.calls != 0 {
		t.Fatal("replacement draft was published or frozen without payment verification")
	}
}
