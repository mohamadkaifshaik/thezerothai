//go:build integration

package identity_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// TestResolveHandles_Integration_Budget (T7 acceptance, on the real repo): 10 handles with 6 resolved before
// cost exactly 4 reads in one GetAll; a repeat costs 0; an unknown handle costs 1 and is then free for 10 s.
func TestResolveHandles_Integration_Budget(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(repo)
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	dir := svc.(identity.Directory)

	var handles []string
	for i := 0; i < 10; i++ {
		h := fmt.Sprintf("mention%d", i)
		handles = append(handles, h)
		if _, err := svc.CreateProfile(context.Background(), fmt.Sprintf("uid-%d", i), "0123456789abcdef", h, "Name "+h); err != nil {
			t.Fatalf("CreateProfile(%s): %v", h, err)
		}
	}
	// CreateProfile caches its own handle: use a second instance (fresh cache) and warm 6 of the 10.
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	dir2 := svc2.(identity.Directory)
	warm := handles[:6]
	if _, err := dir2.ResolveHandles(context.Background(), warm); err != nil {
		t.Fatal(err)
	}

	ctx, c := budget.WithCounter(context.Background())
	got, err := dir2.ResolveHandles(ctx, handles)
	if err != nil || len(got) != 10 {
		t.Fatalf("ResolveHandles: len=%d err=%v", len(got), err)
	}
	for i, h := range handles {
		if got[h] != fmt.Sprintf("uid-%d", i) {
			t.Fatalf("handle %s -> %q", h, got[h])
		}
	}
	budgettest.Assert(t, "ResolveHandles 10 handles, 6 cached", c, budgettest.Budget{Reads: 4})
	if c.Reads() != 4 {
		t.Fatalf("reads = %d, want exactly 4", c.Reads())
	}

	ctx, c = budget.WithCounter(context.Background())
	if _, err := dir2.ResolveHandles(ctx, handles); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "ResolveHandles all cached", c, budgettest.Budget{Reads: 0})

	ctx, c = budget.WithCounter(context.Background())
	got, err = dir.ResolveHandles(ctx, []string{"nosuchperson", handles[0]})
	if err != nil || len(got) != 1 {
		t.Fatalf("unknown handle: got=%v err=%v", got, err)
	}
	budgettest.Assert(t, "ResolveHandles unknown + known (own cache holds the known one)", c, budgettest.Budget{Reads: 1})
	ctx, c = budget.WithCounter(context.Background())
	_, _ = dir.ResolveHandles(ctx, []string{"nosuchperson"})
	budgettest.Assert(t, "ResolveHandles unknown, negative cache", c, budgettest.Budget{Reads: 0})
}
