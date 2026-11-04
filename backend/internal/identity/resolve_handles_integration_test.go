//go:build integration

package identity_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

// TestResolveHandles_Integration (acceptance, on the real repo): 10 handles with 6 resolved before are answered with only the
// other 4 fetched; a repeat fetches nothing; an unknown handle is remembered as free for 10 s. Fetching is proved by deleting the
// handle documents behind the cache: whatever is still answered came from the cache.
func TestResolveHandles_Integration(t *testing.T) {
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

	ctx := context.Background()
	for _, h := range warm {
		if _, err := client.Collection("handles").Doc(h).Delete(ctx); err != nil {
			t.Fatal(err)
		}
	}
	got, err := dir2.ResolveHandles(ctx, handles)
	if err != nil || len(got) != 10 {
		t.Fatalf("ResolveHandles: len=%d err=%v", len(got), err)
	}
	for i, h := range handles {
		if got[h] != fmt.Sprintf("uid-%d", i) {
			t.Fatalf("handle %s -> %q", h, got[h])
		}
	}

	// Now every handle is cached: deleting all the documents changes nothing.
	for _, h := range handles {
		if _, err := client.Collection("handles").Doc(h).Delete(ctx); err != nil {
			t.Fatal(err)
		}
	}
	if again, err := dir2.ResolveHandles(ctx, handles); err != nil || len(again) != 10 {
		t.Fatalf("repeat: len=%d err=%v, want all 10 from the cache", len(again), err)
	}

	// svc cached mention0 at CreateProfile, so it still answers; the unknown handle is absent.
	got, err = dir.ResolveHandles(ctx, []string{"nosuchperson", handles[0]})
	if err != nil || len(got) != 1 {
		t.Fatalf("unknown handle: got=%v err=%v", got, err)
	}
	// The handle gets claimed behind this instance's back: for 10 s the negative entry still answers "free".
	if _, _, err := repo.CreateProfile(ctx, "uid-new", "NoSuchPerson", "nosuchperson", "New", time.Now().UTC(), nil); err != nil {
		t.Fatal(err)
	}
	if got, err = dir.ResolveHandles(ctx, []string{"nosuchperson"}); err != nil || len(got) != 0 {
		t.Fatalf("remembered-free handle: got=%v err=%v, want none from the negative cache", got, err)
	}
}
