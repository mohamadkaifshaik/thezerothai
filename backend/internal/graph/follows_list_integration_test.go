//go:build integration

// follows_list_integration_test.go exercises ListFollowers/ListFollowing against the Firestore emulator
// (ADR-0008 T10 acceptance criteria and budgets).
package graph_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestListFollowers_Integration_PagesAndBudget(t *testing.T) {
	w := newWired(t)
	w.SkipInvariantSweep("edge-only seeding (seedEdge) for read-path paging")
	mustCreateProfile(t, w.identity, "uid-a", "usera")
	mustCreateProfile(t, w.identity, "uid-b", "userb")
	const n = 45
	base := time.Now().Add(-time.Hour).UTC()
	for i := 0; i < n; i++ {
		f := fmt.Sprintf("uid-f%02d", i)
		mustCreateProfile(t, w.identity, f, fmt.Sprintf("follower%02d", i))
		seedEdge(t, w, f, "uid-b", base.Add(time.Duration(i)*time.Second))
	}

	var seen []string
	var sizes []int
	token := ""
	for pageNo := 0; ; pageNo++ {
		ctx, counter := budget.WithCounter(context.Background())
		page, err := w.graph.ListFollowers(ctx, "uid-a", "uid-b", 20, token)
		if err != nil {
			t.Fatal(err)
		}
		budgettest.Assert(t, "GraphService.ListFollowers (page 20)", counter, budgettest.Budget{Reads: 2 + 20 + 20})
		sizes = append(sizes, len(page.Items))
		for _, it := range page.Items {
			seen = append(seen, it.User.UserID)
			if it.Since.IsZero() {
				t.Error("since not filled")
			}
		}
		if page.NextPageToken == "" {
			break
		}
		token = page.NextPageToken
		if pageNo == 0 {
			// A new follow after page 1 must not shift the older pages.
			seedEdge(t, w, "uid-a", "uid-b", time.Now().UTC())
		}
	}
	if fmt.Sprint(sizes) != "[20 20 5]" {
		t.Errorf("sizes = %v, want [20 20 5]", sizes)
	}
	if len(seen) != n || seen[0] != "uid-f44" || seen[n-1] != "uid-f00" {
		t.Errorf("first=%s last=%s len=%d", seen[0], seen[len(seen)-1], len(seen))
	}
	uniq := map[string]bool{}
	for _, s := range seen {
		uniq[s] = true
	}
	if len(uniq) != n {
		t.Errorf("duplicates across pages: %d unique of %d", len(uniq), len(seen))
	}
}

func TestListFollowing_Integration_BlockMatrix(t *testing.T) {
	w := newWired(t)
	for _, u := range []string{"a", "b", "c", "d"} {
		mustCreateProfile(t, w.identity, "uid-"+u, "user"+u)
	}
	ctx := context.Background()
	// b follows c and d; c blocks a (a.blockedBy has c); a blocks d.
	for _, target := range []string{"uid-c", "uid-d"} {
		if _, err := w.graph.Follow(ctx, "uid-b", key1, target); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := w.graph.Block(ctx, "uid-c", key2, "uid-a"); err != nil {
		t.Fatal(err)
	}
	if _, err := w.graph.Block(ctx, "uid-a", key2, "uid-d"); err != nil {
		t.Fatal(err)
	}

	page, err := w.graph.ListFollowing(ctx, "uid-a", "uid-b", 20, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 0 {
		t.Errorf("rows = %d, want blocked-by and blocked users filtered out", len(page.Items))
	}

	// b blocks a: a gets NOT_FOUND on b's lists, indistinguishable from a missing user.
	if _, err := w.graph.Block(ctx, "uid-b", key3, "uid-a"); err != nil {
		t.Fatal(err)
	}
	for name, call := range map[string]func() error{
		"followers": func() error { _, err := w.graph.ListFollowers(ctx, "uid-a", "uid-b", 20, ""); return err },
		"following": func() error { _, err := w.graph.ListFollowing(ctx, "uid-a", "uid-b", 20, ""); return err },
		"missing":   func() error { _, err := w.graph.ListFollowers(ctx, "uid-a", "ghost", 20, ""); return err },
	} {
		var ae *apierr.Error
		if err := call(); !errors.As(err, &ae) || ae.Code.String() != "not_found" {
			t.Errorf("%s err = %v, want not_found", name, err)
		}
	}
}
