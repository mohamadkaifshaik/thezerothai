package identity

import (
	"context"
	"errors"
	"testing"

	"connectrpc.com/connect"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
)

// ADR-0010 D5 / T3: a missing handle is negatively cached (notFoundTTL) for GetProfile-by-handle and
// CheckHandleAvailability, so a scraper probing free handles costs one read per handle per 10 s.
func TestNegativeHandleCache(t *testing.T) {
	ctx := context.Background()

	t.Run("GetProfile by handle NotFound twice reads once", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestService(repo)
		for i := 0; i < 2; i++ {
			_, err := svc.GetProfile(ctx, "caller", ProfileTarget{Handle: "nosuchuser"})
			var ae *apierr.Error
			if !errors.As(err, &ae) || ae.Code != connect.CodeNotFound {
				t.Fatalf("call %d: err = %v, want NotFound", i, err)
			}
		}
		if repo.resolveCalls != 1 {
			t.Fatalf("ResolveHandle calls = %d, want 1", repo.resolveCalls)
		}
	})

	t.Run("CheckHandleAvailability free twice reads once, shared with GetProfile", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestService(repo)
		for i := 0; i < 2; i++ {
			ok, _, err := svc.CheckHandleAvailability(ctx, "freehandle")
			if err != nil || !ok {
				t.Fatalf("call %d: (%v, %v), want available", i, ok, err)
			}
		}
		if _, err := svc.GetProfile(ctx, "caller", ProfileTarget{Handle: "FreeHandle"}); err == nil {
			t.Fatal("GetProfile of a free handle must be NotFound")
		}
		if repo.resolveCalls != 1 {
			t.Fatalf("ResolveHandle calls = %d, want 1", repo.resolveCalls)
		}
	})

	t.Run("CreateProfile claiming the handle clears the negative entry", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestService(repo)
		if ok, _, _ := svc.CheckHandleAvailability(ctx, "claimme"); !ok {
			t.Fatal("expected available")
		}
		if _, err := svc.CreateProfile(ctx, "uid-1", validKey, "claimme", "Claim Me"); err != nil {
			t.Fatalf("CreateProfile: %v", err)
		}
		if ok, _, _ := svc.CheckHandleAvailability(ctx, "claimme"); ok {
			t.Fatal("a just-claimed handle must not be reported available from the negative cache")
		}
	})

	t.Run("stale free hint cannot create a duplicate", func(t *testing.T) {
		repo := newFakeRepo()
		svc := newTestService(repo)
		if ok, _, _ := svc.CheckHandleAvailability(ctx, "racehandle"); !ok {
			t.Fatal("expected available")
		}
		repo.handles["racehandle"] = "other-uid" // claimed on another instance; our hint is now stale
		_, err := svc.CreateProfile(ctx, "uid-2", validKey, "racehandle", "Racer")
		var ae *apierr.Error
		if !errors.As(err, &ae) || ae.Code != connect.CodeAlreadyExists {
			t.Fatalf("err = %v, want AlreadyExists (transactional create is the source of truth)", err)
		}
		if svc.cache.GetHandleFree("racehandle") {
			t.Fatal("HANDLE_TAKEN must clear the stale negative entry")
		}
	})
}
