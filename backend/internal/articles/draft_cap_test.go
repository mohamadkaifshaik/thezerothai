package articles

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"connectrpc.com/connect"
	av "github.com/dzeroth/dzeroth/backend/gen/dzeroth/articles/v1"
	commonv1 "github.com/dzeroth/dzeroth/backend/gen/dzeroth/common/v1"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

func draftID(i int) string { return fmt.Sprintf("draft-cap-%012d", i) }

// seed stores n unpublished drafts for uid (ids draftID(0..n-1)) and published articles for uid.
func seed(r *memoryRepo, uid string, drafts, published int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range drafts {
		id := draftID(i)
		r.rows[id] = &record{ID: id, AuthorID: uid, Revision: 1, Title: "Draft", Body: testBody, UpdatedAt: time.Unix(1700000000, 0)}
	}
	for i := range published {
		id := fmt.Sprintf("published-cap-%012d", i)
		r.rows[id] = &record{ID: id, AuthorID: uid, Revision: 1, Title: "Published", Body: testBody, PostID: "1000000000000000009", Published: true}
	}
}

func saveID(s *Server, ctx context.Context, id string, expected int64) error {
	_, err := s.SaveArticle(ctx, connect.NewRequest(&av.SaveArticleRequest{Article: &av.Article{ArticleId: id, Title: "Title", BodyJson: testBody}, ExpectedRevision: expected}))
	return err
}

func isDraftLimit(err error) bool {
	var ae *apierr.Error
	return errors.As(err, &ae) && ae.Code == connect.CodeFailedPrecondition &&
		ae.Reason == commonv1.ErrorReason_ERROR_REASON_LIMIT_REACHED && ae.Metadata["limit"] == draftLimitName
}

func TestDraftCapOnNewDrafts(t *testing.T) {
	cases := []struct {
		name            string
		drafts, publish int
		otherDrafts     int
		wantRefused     bool
	}{
		{name: "49 drafts: a new one is allowed", drafts: 49},
		{name: "50 drafts: a new one is refused", drafts: 50, wantRefused: true},
		{name: "60 drafts (already over): a new one is refused", drafts: 60, wantRefused: true},
		{name: "published articles never count", drafts: 49, publish: 20},
		{name: "another author's drafts never count", drafts: 10, otherDrafts: 60},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, r, _, ctx := setup()
			seed(r, "alice", tc.drafts, tc.publish)
			for i := range tc.otherDrafts {
				id := fmt.Sprintf("other-cap-%012d", i)
				r.rows[id] = &record{ID: id, AuthorID: "bob", Revision: 1}
			}
			err := saveID(s, ctx, testID, 0)
			if tc.wantRefused {
				if !isDraftLimit(err) {
					t.Fatalf("err = %v, want LIMIT_REACHED limit=%s", err, draftLimitName)
				}
				if _, ok := r.rows[testID]; ok {
					t.Fatal("a refused draft was stored")
				}
				return
			}
			if err != nil {
				t.Fatalf("new draft refused: %v", err)
			}
		})
	}
}

func TestDraftCapNeverLocksOutExistingDrafts(t *testing.T) {
	for _, n := range []int{50, 60} {
		t.Run(fmt.Sprintf("%d drafts", n), func(t *testing.T) {
			s, r, _, ctx := setup()
			seed(r, "alice", n, 0)
			// Editing an existing draft at or over the cap.
			if err := saveID(s, ctx, draftID(0), 1); err != nil {
				t.Fatalf("edit at cap: %v", err)
			}
			// A stale revision on a missing id is still a conflict, not the cap.
			if err := saveID(s, ctx, testID, 3); connect.CodeOf(err) != connect.CodeAborted {
				t.Fatalf("stale save of a missing id: %v", err)
			}
			// Deleting at or over the cap.
			if _, err := s.DeleteArticle(ctx, connect.NewRequest(&av.DeleteArticleRequest{ArticleId: draftID(1), ExpectedRevision: 1})); err != nil {
				t.Fatalf("delete at cap: %v", err)
			}
			if _, ok := r.rows[draftID(1)]; ok {
				t.Fatal("draft not deleted")
			}
		})
	}
}

func TestDraftCapPublishAtCapFreesASlot(t *testing.T) {
	s, r, _, ctx := setup()
	seed(r, "alice", 50, 0)
	if err := saveID(s, ctx, testID, 0); !isDraftLimit(err) {
		t.Fatalf("51st draft: %v", err)
	}
	_, err := s.PublishArticle(ctx, connect.NewRequest(&av.PublishArticleRequest{ArticleId: draftID(0), ExpectedRevision: 1, IdempotencyKey: "publication-key-cap"}))
	if err != nil {
		t.Fatalf("publish at cap: %v", err)
	}
	if !r.rows[draftID(0)].Published {
		t.Fatal("article not published")
	}
	if err := saveID(s, ctx, testID, 0); err != nil {
		t.Fatalf("new draft after publishing one: %v", err)
	}
	// Back at 50: refused again.
	if err := saveID(s, ctx, draftID(99), 0); !isDraftLimit(err) {
		t.Fatalf("draft over the cap again: %v", err)
	}
}

func TestDraftCapDeleteAtCapFreesASlot(t *testing.T) {
	s, r, _, ctx := setup()
	seed(r, "alice", 50, 0)
	if _, err := s.DeleteArticle(ctx, connect.NewRequest(&av.DeleteArticleRequest{ArticleId: draftID(3), ExpectedRevision: 1})); err != nil {
		t.Fatal(err)
	}
	if err := saveID(s, ctx, testID, 0); err != nil {
		t.Fatalf("new draft after deleting one: %v", err)
	}
}

func TestDraftCapCountErrorPropagates(t *testing.T) {
	s, r, _, ctx := setup()
	r.countErr = errors.New("firestore unavailable")
	err := saveID(s, ctx, testID, 0)
	if err == nil || isDraftLimit(err) || !errors.Is(err, r.countErr) {
		t.Fatalf("count failure: %v", err)
	}
	// Edits never count, so they do not depend on the count query.
	seed(r, "alice", 1, 0)
	if err := saveID(s, ctx, draftID(0), 1); err != nil {
		t.Fatalf("edit with a failing count: %v", err)
	}
}
