//go:build integration

// Run via `make test-int` (firebase emulators:exec --only firestore 'go test -tags=integration ./...').
// Requires FIRESTORE_EMULATOR_HOST to be set (the Makefile/emulator harness does this); skips otherwise
// so `go test ./...` (no tag) never needs the emulator.
package identity_test

import (
	"context"
	"errors"
	"fmt"
	"math/rand"
	"os"
	"sync"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func newTestClient(t *testing.T) *firestore.Client {
	t.Helper()
	if os.Getenv("FIRESTORE_EMULATOR_HOST") == "" {
		t.Skip("FIRESTORE_EMULATOR_HOST not set; run via `make test-int`")
	}
	// A fresh demo-* project per test run avoids collisions between test runs (testing-strategy skill).
	projectID := fmt.Sprintf("demo-test-%d", rand.Int63())
	client, err := firestore.NewClient(context.Background(), projectID)
	if err != nil {
		t.Fatalf("firestore.NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Close() })
	return client
}

func TestCreateProfile_Integration_BudgetAndReplay(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)

	ctx, counter := budget.WithCounter(context.Background())
	now := time.Now().UTC()

	profile, replay, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil)
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if replay {
		t.Fatal("first call should not be a replay")
	}
	if profile.Handle != "Alice" || profile.HandleLower != "alice" {
		t.Fatalf("unexpected profile: %+v", profile)
	}
	// ADR-0003 / proto doc comment: worst case reads 2, writes 3.
	budgettest.Assert(t, "CreateProfile (first call)", counter, budgettest.Budget{Reads: 2, Writes: 3})

	// Verify the graph doc was created (identity.GraphInitializer seam).
	if _, err := client.Collection("graph").Doc("uid-1").Get(ctx); err != nil {
		t.Errorf("expected graph/uid-1 to exist: %v", err)
	}

	// Replay: same uid, any handle/displayName -> returns the existing profile, no new writes. A replay
	// only reads users/{uid} (it never gets to the handle check), so its budget is tighter than the
	// documented worst case.
	ctx2, counter2 := budget.WithCounter(context.Background())
	replayed, isReplay, err := repo.CreateProfile(ctx2, "uid-1", "Bob", "bob", "Bob B.", now, nil)
	if err != nil {
		t.Fatalf("CreateProfile() replay error = %v", err)
	}
	if !isReplay {
		t.Fatal("second call for the same uid should be a replay")
	}
	if replayed.Handle != "Alice" {
		t.Fatalf("replay should return the original profile, got handle %q", replayed.Handle)
	}
	budgettest.Assert(t, "CreateProfile (replay)", counter2, budgettest.Budget{Reads: 1, Writes: 0})
}

// TestCreateProfile_Integration_HandleRace: two goroutines race to create a profile with the same handle
// but different uids (double-submit / concurrent sign-up, testing-strategy skill: "double-submit with
// same idempotency key" analog for a natural-key create). Firestore transactions retry on contention, so
// exactly one must win the handle and the other must see ErrHandleTaken — never two winners, never zero.
func TestCreateProfile_Integration_HandleRace(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	const attempts = 8
	var wg sync.WaitGroup
	results := make([]error, attempts)
	profiles := make([]identity.Profile, attempts)
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ctx, _ := budget.WithCounter(context.Background())
			p, _, err := repo.CreateProfile(ctx, fmt.Sprintf("uid-race-%d", i), "Racer", "racer", fmt.Sprintf("Racer %d", i), now, nil)
			results[i] = err
			profiles[i] = p
		}(i)
	}
	wg.Wait()

	var wins, losses int
	for i, err := range results {
		switch {
		case err == nil:
			wins++
			if profiles[i].HandleLower != "racer" {
				t.Errorf("winner uid-race-%d got unexpected profile: %+v", i, profiles[i])
			}
		case err == identity.ErrHandleTaken:
			losses++
		default:
			t.Fatalf("uid-race-%d: unexpected error %v", i, err)
		}
	}
	if wins != 1 {
		t.Errorf("wins = %d, want exactly 1 (handle uniqueness must hold under contention)", wins)
	}
	if losses != attempts-1 {
		t.Errorf("losses = %d, want %d", losses, attempts-1)
	}
}

func TestCreateProfile_Integration_HandleTaken(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("first CreateProfile: %v", err)
	}

	ctx2, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx2, "uid-2", "Alice", "alice", "Someone Else", now, nil); err != identity.ErrHandleTaken {
		t.Fatalf("expected ErrHandleTaken, got %v", err)
	}
}

const changeHandleCooldown = 7 * 24 * time.Hour

func TestChangeHandle_Integration_BudgetAndFreesOldHandle(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	updated, oldLower, err := repo.ChangeHandle(ctx2, "uid-1", "Alicia", "alicia", now.Add(8*24*time.Hour), changeHandleCooldown)
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if updated.HandleLower != "alicia" {
		t.Fatalf("HandleLower = %q, want alicia", updated.HandleLower)
	}
	if oldLower != "alice" {
		t.Fatalf("invalidateOldHandleLower = %q, want alice", oldLower)
	}
	// ADR-0003 / proto doc comment: reads 2, writes 2, deletes 1.
	budgettest.Assert(t, "ChangeHandle", counter, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})
	if got := counter.Deletes(); got != 1 {
		t.Errorf("Deletes() = %d, want exactly 1 (must free the old handle)", got)
	}

	// The old handle must be free again.
	ctx3, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx3, "uid-2", "Alice", "alice", "New Alice", now, nil); err != nil {
		t.Fatalf("expected old handle 'alice' to be free after rename: %v", err)
	}
}

// TestChangeHandle_Integration_TrueNoOp (M4): requesting the caller's exact current handle is a pure read,
// 0 writes, 0 deletes — and never touches the cooldown, so it can be repeated freely.
func TestChangeHandle_Integration_TrueNoOp(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	updated, oldLower, err := repo.ChangeHandle(ctx2, "uid-1", "Alice", "alice", now, changeHandleCooldown)
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if updated.Handle != "Alice" || oldLower != "" {
		t.Fatalf("got (profile=%+v, oldLower=%q), want unchanged profile and oldLower=\"\"", updated, oldLower)
	}
	budgettest.Assert(t, "ChangeHandle (true no-op)", counter, budgettest.Budget{Reads: 1, Writes: 0, Deletes: 0})
}

// TestChangeHandle_Integration_CaseOnlyRename (M4): same handleLower, different case — updates the
// display form (1 write to users only), never touches handles/{} or the cooldown.
func TestChangeHandle_Integration_CaseOnlyRename(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	updated, oldLower, err := repo.ChangeHandle(ctx2, "uid-1", "Alice", "alice", now, changeHandleCooldown)
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if updated.Handle != "Alice" || updated.HandleLower != "alice" || oldLower != "" {
		t.Fatalf("got (profile=%+v, oldLower=%q)", updated, oldLower)
	}
	budgettest.Assert(t, "ChangeHandle (case-only rename)", counter, budgettest.Budget{Reads: 1, Writes: 1, Deletes: 0})

	// The uniqueness key never moved, so it must still resolve immediately (no free-then-reclaim window).
	ctx3, _ := budget.WithCounter(context.Background())
	if uid, err := repo.ResolveHandle(ctx3, "alice"); err != nil || uid != "uid-1" {
		t.Fatalf("ResolveHandle(alice) = (%q, %v), want (uid-1, nil)", uid, err)
	}
}

// TestChangeHandle_Integration_CooldownBlocksBeforeSecondRead (M4): cooldown is enforced against the doc
// read fresh inside the transaction; when it blocks, the new handle is never even read (1 read, not 2).
func TestChangeHandle_Integration_CooldownBlocksBeforeSecondRead(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	if _, _, err := repo.ChangeHandle(ctx, "uid-1", "Alicia", "alicia", now, changeHandleCooldown); err != nil {
		t.Fatalf("first ChangeHandle: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	_, _, err := repo.ChangeHandle(ctx2, "uid-1", "Bob", "bob", now.Add(time.Hour), changeHandleCooldown)
	var cooldownErr *identity.ErrHandleChangeCooldown
	if !errors.As(err, &cooldownErr) {
		t.Fatalf("expected ErrHandleChangeCooldown, got %v", err)
	}
	if cooldownErr.RetryAfter <= 0 {
		t.Error("expected a positive RetryAfter")
	}
	budgettest.Assert(t, "ChangeHandle (cooldown blocked)", counter, budgettest.Budget{Reads: 1, Writes: 0, Deletes: 0})
}

// TestChangeHandle_Integration_IdempotentRetryOwnedHandle (M4): handles/{new} already existing and owned
// by the caller must succeed (not ErrHandleTaken) and still finish the rename (update users, free the old
// handle) — the same 2 writes + 1 delete as the common path.
func TestChangeHandle_Integration_IdempotentRetryOwnedHandle(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// Simulate a prior attempt that reserved handles/bob for uid-1 without users/uid-1 reflecting it yet.
	if _, err := client.Collection("handles").Doc("bob").Create(ctx, map[string]any{"uid": "uid-1", "createdAt": now}); err != nil {
		t.Fatalf("seed handles/bob: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	updated, oldLower, err := repo.ChangeHandle(ctx2, "uid-1", "Bob", "bob", now, changeHandleCooldown)
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v, want success (idempotent retry)", err)
	}
	if updated.HandleLower != "bob" || oldLower != "alice" {
		t.Fatalf("got (profile=%+v, oldLower=%q), want (HandleLower=bob, oldLower=alice)", updated, oldLower)
	}
	budgettest.Assert(t, "ChangeHandle (idempotent retry, owned handle)", counter, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})

	ctx3, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx3, "uid-2", "Alice", "alice", "New Alice", now, nil); err != nil {
		t.Fatalf("expected old handle 'alice' to be free after rename: %v", err)
	}
}

func TestGetProfile_Integration_Budget(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	got, err := repo.GetProfile(ctx2, "uid-1")
	if err != nil {
		t.Fatalf("GetProfile() error = %v", err)
	}
	if got.Handle != "Alice" {
		t.Fatalf("unexpected profile: %+v", got)
	}
	budgettest.Assert(t, "GetProfile", counter, budgettest.Budget{Reads: 1})

	ctx3, _ := budget.WithCounter(context.Background())
	if _, err := repo.GetProfile(ctx3, "ghost"); err != identity.ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestResolveHandle_Integration_Budget(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	uid, err := repo.ResolveHandle(ctx2, "alice")
	if err != nil {
		t.Fatalf("ResolveHandle() error = %v", err)
	}
	if uid != "uid-1" {
		t.Fatalf("ResolveHandle() = %q, want uid-1", uid)
	}
	budgettest.Assert(t, "ResolveHandle", counter, budgettest.Budget{Reads: 1})

	ctx3, counter3 := budget.WithCounter(context.Background())
	if _, err := repo.ResolveHandle(ctx3, "ghost"); err != identity.ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
	budgettest.Assert(t, "ResolveHandle (miss)", counter3, budgettest.Budget{Reads: 1})
}

func TestUpdateProfile_Integration_Budget(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	ctx2, counter := budget.WithCounter(context.Background())
	updated, err := repo.UpdateProfile(ctx2, "uid-1", func(p *identity.Profile) {
		p.Bio = "hello world"
	})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if updated.Bio != "hello world" {
		t.Fatalf("unexpected profile: %+v", updated)
	}
	// service.go / repo_firestore.go doc comment: 1 read, 1 write (Phase 0; proto's "2 reads" includes
	// the avatar-media read, not implemented until the media module exists).
	budgettest.Assert(t, "UpdateProfile", counter, budgettest.Budget{Reads: 1, Writes: 1})

	ctx3, _ := budget.WithCounter(context.Background())
	if _, err := repo.UpdateProfile(ctx3, "ghost", func(*identity.Profile) {}); err != identity.ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestUnreadNotificationCount_Integration_Budget(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	now := time.Now().UTC()

	ctx, _ := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx, "uid-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// No notifications yet: the count() aggregation still costs exactly 1 read.
	ctx2, counter := budget.WithCounter(context.Background())
	n, err := repo.UnreadNotificationCount(ctx2, "uid-1", time.Time{})
	if err != nil {
		t.Fatalf("UnreadNotificationCount() error = %v", err)
	}
	if n != 0 {
		t.Fatalf("UnreadNotificationCount() = %d, want 0", n)
	}
	budgettest.Assert(t, "UnreadNotificationCount (empty)", counter, budgettest.Budget{Reads: 1})

	// Seed two notifications after `since` and one before; only the two after should count, still 1 read
	// regardless of how many match (aggregation query, not a per-doc read).
	notifs := client.Collection("users").Doc("uid-1").Collection("notifications")
	if _, err := notifs.Doc("n1").Set(ctx, map[string]any{"createdAt": now.Add(time.Hour)}); err != nil {
		t.Fatalf("seed notification: %v", err)
	}
	if _, err := notifs.Doc("n2").Set(ctx, map[string]any{"createdAt": now.Add(2 * time.Hour)}); err != nil {
		t.Fatalf("seed notification: %v", err)
	}
	if _, err := notifs.Doc("n0").Set(ctx, map[string]any{"createdAt": now.Add(-time.Hour)}); err != nil {
		t.Fatalf("seed notification: %v", err)
	}

	ctx3, counter3 := budget.WithCounter(context.Background())
	n, err = repo.UnreadNotificationCount(ctx3, "uid-1", now)
	if err != nil {
		t.Fatalf("UnreadNotificationCount() error = %v", err)
	}
	if n != 2 {
		t.Fatalf("UnreadNotificationCount() = %d, want 2", n)
	}
	budgettest.Assert(t, "UnreadNotificationCount (2 matches)", counter3, budgettest.Budget{Reads: 1})
}

// TestCreateProfile_Integration_AuthorizeSeam (ADR-0011 amendment M2): authorize runs once on the not-found path, its
// error aborts the transaction with nothing written, it adds no Firestore ops, and it never runs on a replay.
func TestCreateProfile_Integration_AuthorizeSeam(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()
	refuse := errors.New("refused by authorize")

	calls := 0
	ctx, counter := budget.WithCounter(context.Background())
	_, _, err := repo.CreateProfile(ctx, "uid-m2", "Zed", "zed", "Zed", now, func(context.Context) error { calls++; return refuse })
	if !errors.Is(err, refuse) {
		t.Fatalf("err = %v, want the authorize error", err)
	}
	if calls != 1 {
		t.Fatalf("authorize calls = %d, want 1", calls)
	}
	budgettest.Assert(t, "CreateProfile (refused)", counter, budgettest.Budget{Reads: 1, Writes: 0})
	for _, path := range []string{"users/uid-m2", "handles/zed", "graph/uid-m2"} {
		if snap, gerr := client.Doc(path).Get(context.Background()); gerr == nil && snap.Exists() {
			t.Errorf("%s exists after a refused CreateProfile", path)
		}
	}

	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, _, err := repo.CreateProfile(ctx2, "uid-m2", "Zed", "zed", "Zed", now, func(context.Context) error { calls++; return nil }); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("authorize calls = %d, want 2 (once per not-found attempt)", calls)
	}
	budgettest.Assert(t, "CreateProfile (authorized)", counter2, budgettest.Budget{Reads: 2, Writes: 3})

	_, isReplay, err := repo.CreateProfile(context.Background(), "uid-m2", "Zed", "zed", "Zed", now, func(context.Context) error { calls++; return refuse })
	if err != nil || !isReplay {
		t.Fatalf("replay err = %v replay = %v", err, isReplay)
	}
	if calls != 2 {
		t.Fatalf("authorize ran on a replay (calls = %d)", calls)
	}
}
