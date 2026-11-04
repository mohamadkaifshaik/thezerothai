//go:build integration

// Service-level tests: these drive identity.Service, the exact interface server.go (the Connect handler) calls,
// over a real Firestore emulator client, so the instance cache (backend/internal/identity/cache.go) is exercised
// too, not just the repo.
package identity_test

import (
	"context"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
)

func TestCreateProfile_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx := context.Background()
	profile, err := svc.CreateProfile(ctx, "uid-1", validKeyForIntegration, "Alice", "Alice A.")
	if err != nil {
		t.Fatalf("CreateProfile() error = %v", err)
	}
	if profile.Handle != "Alice" {
		t.Fatalf("unexpected profile: %+v", profile)
	}
}

func TestCheckHandleAvailability_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0 := context.Background()
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// A second Service instance (fresh cache) checking a taken handle.
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx := context.Background()
	available, _, err := svc2.CheckHandleAvailability(ctx, "alice")
	if err != nil {
		t.Fatalf("CheckHandleAvailability() error = %v", err)
	}
	if available {
		t.Fatal("expected 'alice' to be unavailable (taken)")
	}

	// Repeating the same check on svc2 answers the same.
	if available, _, err := svc2.CheckHandleAvailability(context.Background(), "alice"); err != nil || available {
		t.Fatalf("repeat CheckHandleAvailability() = %v, %v, want unavailable", available, err)
	}

	// On svc (the instance that actually created uid-1/alice) the handle is known from CreateProfile's cache fill.
	if available, _, err := svc.CheckHandleAvailability(context.Background(), "alice"); err != nil || available {
		t.Fatalf("CheckHandleAvailability() on the creating instance = %v, %v, want unavailable", available, err)
	}
}

func TestGetMe_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0 := context.Background()
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// Fresh Service (cold cache).
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx := context.Background()
	for i := range 2 { // the second call is served from the warm caches
		me, err := svc2.GetMe(ctx, "uid-1")
		if err != nil || me.Profile.UserID != "uid-1" {
			t.Fatalf("GetMe() call %d = %+v, %v", i+1, me.Profile, err)
		}
	}
}

func TestGetProfile_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0 := context.Background()
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// By user_id, cold cache.
	svcByID := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx := context.Background()
	if _, err := svcByID.GetProfile(ctx, "caller", identity.ProfileTarget{UserID: "uid-1"}); err != nil {
		t.Fatalf("GetProfile(by id) error = %v", err)
	}

	// By handle, cold cache: the handle is resolved, then the profile loaded.
	svcByHandle := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx2 := context.Background()
	if _, err := svcByHandle.GetProfile(ctx2, "caller", identity.ProfileTarget{Handle: "ALICE"}); err != nil {
		t.Fatalf("GetProfile(by handle) error = %v", err)
	}
}

func TestUpdateProfile_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0 := context.Background()
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	newBio := "hello world"
	ctx := context.Background()
	updated, err := svc.UpdateProfile(ctx, "uid-1", identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, Bio: &newBio})
	if err != nil {
		t.Fatalf("UpdateProfile() error = %v", err)
	}
	if updated.Bio != newBio {
		t.Fatalf("unexpected profile: %+v", updated)
	}
}

// TestChangeHandle_Integration_Service (M4 fix): the cooldown/no-op/case-only checks run inside
// FirestoreRepo.ChangeHandle's own transaction, against the doc read fresh there, so the rename works the same
// whether or not the caller's profile was already warm in this instance's cache.
func TestChangeHandle_Integration_Service(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx0 := context.Background()
	if _, err := svc.CreateProfile(ctx0, "uid-1", validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	// A second, independent account for the warm-cache half of this test below — ChangeHandle has a 7-day
	// cooldown per uid, so uid-1 can only be renamed once within this test.
	ctx0b := context.Background()
	if _, err := svc.CreateProfile(ctx0b, "uid-2", validKeyForIntegration, "Bob", "Bob B."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}

	// Fresh Service (cold cache): ChangeHandle delegates straight to the repo transaction.
	svc2 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	ctx := context.Background()
	updated, err := svc2.ChangeHandle(ctx, "uid-1", validKeyForIntegration, "alicia")
	if err != nil {
		t.Fatalf("ChangeHandle() error = %v", err)
	}
	if updated.HandleLower != "alicia" {
		t.Fatalf("unexpected profile: %+v", updated)
	}

	// A caller who has already made a request this session (profile cache warm, e.g. from GetMe) gets the same
	// result. Different uid: see the cooldown note above.
	svc3 := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	if _, err := svc3.GetMe(context.Background(), "uid-2"); err != nil {
		t.Fatalf("warm-up GetMe: %v", err)
	}
	if p, err := svc3.ChangeHandle(context.Background(), "uid-2", validKeyForIntegration, "bobby"); err != nil || p.HandleLower != "bobby" {
		t.Fatalf("ChangeHandle() = %+v, %v", p, err)
	}
}

// TestAccountStatus_Integration_NegativeCache (M1): authn.AccountStatusInterceptor calls this on every
// non-exempt RPC. Without the ~10s negative cache, a caller who never completes sign-up would hit
// Firestore on every request indefinitely; with it, only the first miss does.
func TestAccountStatus_Integration_NegativeCache(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)

	ctx := context.Background()
	exists, _, err := svc.AccountStatus(ctx, "ghost")
	if err != nil || exists {
		t.Fatalf("AccountStatus(ghost) #1 = (%v, err=%v), want (false, nil)", exists, err)
	}

	// The profile appears behind this instance's back (written through the repo, not the service): the second answer
	// still comes from the negative cache, which proves the repo was not asked again.
	if _, _, err := repo.CreateProfile(ctx, "ghost", "Ghost", "ghost", "Ghost", time.Now().UTC(), nil); err != nil {
		t.Fatalf("repo.CreateProfile: %v", err)
	}
	exists2, _, err := svc.AccountStatus(ctx, "ghost")
	if err != nil || exists2 {
		t.Fatalf("AccountStatus(ghost) #2 = (%v, err=%v), want (false, nil) from the negative cache", exists2, err)
	}
}

// validKeyForIntegration mirrors the unit tests' validKey constant (16-64 chars, [A-Za-z0-9_-]); kept
// distinct because this file is `package identity_test` (black-box), unlike service_test.go's validKey.
const validKeyForIntegration = "0123456789abcdef"
