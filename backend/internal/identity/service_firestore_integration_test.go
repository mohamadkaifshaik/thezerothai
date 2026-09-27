//go:build integration

// Service-level RPC budget assertions (testing-strategy skill): these drive identity.Service — the exact
// interface server.go (the Connect handler) calls — over a real Firestore emulator client, so the
// instance cache (backend/internal/identity/cache.go) is exercised too, not just the repo. A repo-level
// call alone (repo_firestore_integration_test.go) can't see the extra read a fresh (cold) cache adds on
// the service's own read-through path (getProfileCached), which is the discrepancy flagged in
// TestChangeHandle_Integration_ServiceBudget below.
package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

func TestCreateProfile_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx, counter := budget.WithCounter(context.Background())
	profile, err := svc.CreateProfile(ctx, "uid-1", validKeyForIntegration, "Alice", "Alice A.")
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if profile.Handle != "Alice" {
		t.Fatalf("unexpected profile: %+v", profile)
	}
	// Matches the repo-level budget exactly: CreateProfile never consults the cache before writing.
	budgettest.Assert(t, "IdentityService.CreateProfile", counter, budgettest.Budget{Reads: 2, Writes: 3})
}

func TestCheckHandleAvailability_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// A second Service instance (fresh cache) checking a taken handle: 1 read (proto: reads 1/1).
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx, counter := budget.WithCounter(context.Background())
	available, _, err := svc2.CheckHandleAvailability(ctx, "alice")
	if err != nil {
		t.Fatalf("CheckHandleAvailability() error = %v", err)
	}
	if available {
		t.Fatal("expected 'alice' to be unavailable (taken)")
	}
	budgettest.Assert(t, "IdentityService.CheckHandleAvailability (cold)", counter, budgettest.Budget{Reads: 1})

	// Repeating the same check on svc2 is NOT cheaper: CheckHandleAvailability never populates the handle
	// cache itself (proto: "reads 1/1" — worst == typical, no caching claimed for this RPC; it relies on
	// the 10/min/uid rate limit instead, per the proto comment).
	ctx1b, counter1b := budget.WithCounter(context.Background())
	if _, _, err := svc2.CheckHandleAvailability(ctx1b, "alice"); err != nil {
		t.Fatalf("CheckHandleAvailability() error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.CheckHandleAvailability (repeat, still cold)", counter1b, budgettest.Budget{Reads: 1})

	// On svc (the instance that actually created uid-1/alice), the handle->uid mapping was populated as a
	// side effect of CreateProfile's cache.SetProfile — so checking that same handle again costs 0 reads.
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, _, err := svc.CheckHandleAvailability(ctx2, "alice"); err != nil {
		t.Fatalf("CheckHandleAvailability() error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.CheckHandleAvailability (cache warmed by CreateProfile)", counter2, budgettest.Budget{Reads: 0})
}

func TestGetMe_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// Fresh Service (cold cache): profile cache miss + unread-count cache miss = 2 reads (proto: reads 2/1).
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx, counter := budget.WithCounter(context.Background())
	if _, err := svc2.GetMe(ctx, "uid-1"); err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.GetMe (cold)", counter, budgettest.Budget{Reads: 2})

	// Same Service instance again: both caches warm, 0 reads (proto typical: 1, this is even better).
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, err := svc2.GetMe(ctx2, "uid-1"); err != nil {
		t.Fatalf("GetMe() error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.GetMe (warm)", counter2, budgettest.Budget{Reads: 0})
}

func TestGetProfile_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// By user_id, cold cache: 1 read (no handle resolve needed).
	svcByID := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx, counter := budget.WithCounter(context.Background())
	if _, err := svcByID.GetProfile(ctx, "caller", identity.ProfileTarget{UserID: "uid-1"}); err != nil {
		t.Fatalf("GetProfile(by id) error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.GetProfile (by user_id, cold)", counter, budgettest.Budget{Reads: 1})

	// By handle, cold cache: handle resolve + profile = 2 reads. Phase 0 ceiling (service.go doc comment);
	// the proto's stated worst case of 4 additionally covers the graph blocked-by check, not implemented
	// in this bootstrap (see docs/code-map.md "Not implemented yet").
	svcByHandle := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, err := svcByHandle.GetProfile(ctx2, "caller", identity.ProfileTarget{Handle: "ALICE"}); err != nil {
		t.Fatalf("GetProfile(by handle) error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.GetProfile (by handle, cold)", counter2, budgettest.Budget{Reads: 2})
}

func TestUpdateProfile_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	newBio := "hello world"
	ctx, counter := budget.WithCounter(context.Background())
	updated, err := svc.UpdateProfile(ctx, "uid-1", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &newBio})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if updated.Bio != newBio {
		t.Fatalf("unexpected profile: %+v", updated)
	}
	// UpdateProfile never consults the cache before writing (it writes straight through), so this matches
	// the repo-level budget regardless of cache state (service.go Phase 0 doc comment: reads 1, writes 1).
	budgettest.Assert(t, "IdentityService.UpdateProfile", counter, budgettest.Budget{Reads: 1, Writes: 1})
}

// TestChangeHandle_Integration_ServiceBudget (M4 fix): the cooldown/no-op/case-only checks now run inside
// FirestoreRepo.ChangeHandle's own transaction, against the doc read fresh there — service.go no longer
// needs a pre-transaction cache read to decide those (it used to, via getProfileCached, which cost an
// extra read on a cold cache: see git history / the phase0 code review for the prior 3-read behavior).
// Every ChangeHandle call now costs exactly the repo's own 2 reads, matching the proto doc comment and
// docs/reviews/cost-model.md, regardless of whether the caller's profile was already warm in this
// instance's cache.
func TestChangeHandle_Integration_ServiceBudget(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// A second, independent account for the warm-cache half of this test below — ChangeHandle has a 7-day
	// cooldown per uid, so uid-1 can only be renamed once within this test.
	ctx0b, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx0b, "uid-2", validKeyForIntegration, "Bob", "Bob B."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// Fresh Service (cold cache): still exactly 2 reads, since ChangeHandle no longer consults the cache at
	// all — it delegates straight to the repo transaction.
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx, counter := budget.WithCounter(context.Background())
	updated, err := svc2.ChangeHandle(ctx, "uid-1", validKeyForIntegration, "alicia")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if updated.HandleLower != "alicia" {
		t.Fatalf("unexpected profile: %+v", updated)
	}
	budgettest.Assert(t, "IdentityService.ChangeHandle (cold cache)", counter, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})

	// A caller who has already made a request this session (profile cache warm, e.g. from GetMe) costs the
	// same 2 reads — cache state is now irrelevant to this RPC's budget. Different uid: see cooldown note
	// above.
	svc3 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	if _, err := svc3.GetMe(context.Background(), "uid-2"); err != nil {
		t.Fatalf("warm-up GetMe: %v", err)
	}
	ctx2, counter2 := budget.WithCounter(context.Background())
	if _, err := svc3.ChangeHandle(ctx2, "uid-2", validKeyForIntegration, "bobby"); err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	budgettest.Assert(t, "IdentityService.ChangeHandle (warm cache, same budget)", counter2, budgettest.Budget{Reads: 2, Writes: 2, Deletes: 1})
}

// TestAccountStatus_Integration_NegativeCache (M1): authn.AccountStatusInterceptor calls this on every
// non-exempt RPC. Without the ~10s negative cache, a caller who never completes sign-up would cost 1
// Firestore read per request indefinitely; with it, only the first miss touches Firestore.
func TestAccountStatus_Integration_NegativeCache(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx, counter := budget.WithCounter(context.Background())
	exists, _, err := svc.AccountStatus(ctx, "ghost")
	if err != nil || exists {
		t.Fatalf("AccountStatus(ghost) #1 = (%v, err=%v), want (false, nil)", exists, err)
	}
	budgettest.Assert(t, "AccountStatus (cold, no profile)", counter, budgettest.Budget{Reads: 1})

	ctx2, counter2 := budget.WithCounter(context.Background())
	exists2, _, err := svc.AccountStatus(ctx2, "ghost")
	if err != nil || exists2 {
		t.Fatalf("AccountStatus(ghost) #2 = (%v, err=%v), want (false, nil)", exists2, err)
	}
	budgettest.Assert(t, "AccountStatus (negative-cache hit)", counter2, budgettest.Budget{Reads: 0})
}

// validKeyForIntegration mirrors the unit tests' validKey constant (16-64 chars, [A-Za-z0-9_-]); kept
// distinct because this file is `package identity_test` (black-box), unlike service_test.go's validKey.
const validKeyForIntegration = "0123456789abcdef"
