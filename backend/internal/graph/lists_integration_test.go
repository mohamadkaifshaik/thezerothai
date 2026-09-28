//go:build integration

// lists_integration_test.go exercises GetRelationships and the own-list RPCs against the Firestore emulator
// (ADR-0008 T9 acceptance criteria and budgets).
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestGetRelationships_Integration_BudgetAndBlockedByInvisible(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	mustCreateProfile(t, w.identity, "uid-c", "userc")
	// b blocks a: a must see b exactly as it sees an unrelated user c.
	if _, err := w.graph.Block(context.Background(), "uid-b", key1, "uid-a"); err != nil {
		t.Fatal(err)
	}

	ctx, counter := budget.WithCounter(context.Background())
	rels, err := w.graph.GetRelationships(ctx, "uid-a", []string{"uid-b", "uid-c"})
	if err != nil {
		t.Fatal(err)
	}
	if rels[0].FollowState != rels[1].FollowState || rels[0].Blocking != rels[1].Blocking || rels[0].Muting != rels[1].Muting {
		t.Errorf("blocked-by user %+v distinguishable from stranger %+v", rels[0], rels[1])
	}
	budgettest.Assert(t, "GraphService.GetRelationships (cold)", counter, budgettest.Budget{Reads: 1})

	ctx2, c2 := budget.WithCounter(context.Background())
	if _, err := w.graph.GetRelationships(ctx2, "uid-a", []string{"uid-b", "uid-c"}); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "GraphService.GetRelationships (warm)", c2, budgettest.Budget{Reads: 0})
}

func TestListBlockedUsers_Integration_PagesAndBudget(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	const n = 45
	for i := 0; i < n; i++ {
		uid := fmt.Sprintf("uid-t%02d", i)
		mustCreateProfile(t, w.identity, uid, fmt.Sprintf("target%02d", i))
	}
	// Seed blocked[] directly (45 real Block calls would trip nothing but cost minutes of emulator time).
	blocked := make([]string, n)
	for i := range blocked {
		blocked[i] = fmt.Sprintf("uid-t%02d", i)
	}
	seedGraphArrays(t, w.client, "uid-a", map[string]interface{}{"blocked": blocked})

	var seen []string
	token := ""
	var sizes []int
	for {
		ctx, counter := budget.WithCounter(context.Background())
		page, err := w.graph.ListBlockedUsers(ctx, "uid-a", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "GraphService.ListBlockedUsers", counter, budgettest.Budget{Reads: 1 + 20})
		sizes = append(sizes, len(page.Items))
		for _, it := range page.Items {
			seen = append(seen, it.User.UserID)
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
	}
	if fmt.Sprint(sizes) != "[20 20 5]" {
		t.Errorf("sizes = %v, want [20 20 5]", sizes)
	}
	if len(seen) != n || seen[0] != "uid-t44" || seen[n-1] != "uid-t00" {
		t.Errorf("order wrong: first=%s last=%s len=%d", seen[0], seen[len(seen)-1], len(seen))
	}

	_, err := w.graph.ListBlockedUsers(context.Background(), "uid-a", 20, "tampered")
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Code.String() != "invalid_argument" {
		t.Errorf("tampered token err = %v", err)
	}
}

func TestListMutedUsers_Integration_RelationshipFilled(t *testing.T) {
	w := newWired(t)
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	if _, err := w.graph.Mute(context.Background(), "uid-a", key1, "uid-b"); err != nil {
		t.Fatal(err)
	}
	page, err := w.graph.ListMutedUsers(context.Background(), "uid-a", 0, "")
	if err != nil || len(page.Items) != 1 {
		t.Fatalf("page = %+v, %v", page, err)
	}
	if got := page.Items[0].Relationship; !got.Muting || got.Blocking || got.FollowState != graph.FollowStateNone {
		t.Errorf("relationship = %+v", got)
	}
}
