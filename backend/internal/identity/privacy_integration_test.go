//go:build integration

package identity_test

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/apierr"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

// W3-26a on the emulator: the toggle transaction's exact reads and writes, the set doc it maintains, the loader's
// detached read, and the identity eraser step's ArrayRemove.

func privacyService(t *testing.T, client *firestore.Client, limits identity.PrivacyLimits) (identity.Service, *identity.FirestoreRepo, *identity.ProtectedSetLoader) {
	t.Helper()
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	set := identity.NewProtectedSetLoader(repo, time.Minute, 10*time.Minute, nil, nil)
	reg := flags.NewRegistry(flags.Spec{Name: identity.PrivateAccountsFlag, Mode: flags.On})
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour,
		identity.WithExtrasFlags(reg), identity.WithPrivacy(identity.PrivacyDeps{Repo: repo, Set: set, Limits: limits}))
	ctx, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return svc, repo, set
}

func setUIDs(t *testing.T, client *firestore.Client) (uids []string, exists bool) {
	t.Helper()
	snap, err := client.Doc("privacy/protectedAuthors").Get(context.Background())
	if err != nil {
		return nil, false
	}
	raw, _ := snap.Data()["uids"].([]any)
	for _, u := range raw {
		uids = append(uids, u.(string))
	}
	return uids, true
}

func TestPrivacyToggle_Integration_Budgets(t *testing.T) {
	client := newTestClient(t)
	svc, _, set := privacyService(t, client, identity.PrivacyLimits{TogglesPerDay: 4, SetMax: 20000})
	yes := true
	update := func(name string, v bool, b budgettest.Budget, writes int64) error {
		t.Helper()
		ctx, c := budget.WithCounter(context.Background())
		_, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, IsPrivate: &v})
		if err == nil {
			budgettest.Assert(t, name, c, b)
			if c.Writes() != writes {
				t.Errorf("%s: writes = %d, want exactly %d", name, c.Writes(), writes)
			}
		}
		return err
	}

	// No set doc yet: the first protect creates it (3 reads, 3 writes; the 4th cold read is the interceptor's).
	if err := update("protect (creates the set doc)", true, budgettest.Budget{Reads: 3, Writes: 3}, 3); err != nil {
		t.Fatal(err)
	}
	if uids, ok := setUIDs(t, client); !ok || !slices.Equal(uids, []string{itUID}) {
		t.Fatalf("set after protect = %v (exists %v), want [uid]", uids, ok)
	}
	// The committing instance sees it at once, without reading (the loader was never asked before).
	ctx, c := budget.WithCounter(context.Background())
	cur, err := set.Current(ctx)
	if err != nil || !cur.Has(itUID) || c.Reads() != 0 {
		t.Fatalf("loader after protect: has=%v err=%v reads charged to the caller=%d", cur != nil && cur.Has(itUID), err, c.Reads())
	}

	if err := update("protect again (equal value)", true, budgettest.Budget{Reads: 1}, 0); err != nil {
		t.Fatal(err)
	}
	if err := update("unprotect", false, budgettest.Budget{Reads: 2, Writes: 3}, 3); err != nil {
		t.Fatal(err)
	}
	if uids, ok := setUIDs(t, client); !ok || len(uids) != 0 {
		t.Fatalf("set after unprotect = %v (exists %v), want an empty list on a surviving doc", uids, ok)
	}
	if err := update("protect (set doc exists)", true, budgettest.Budget{Reads: 3, Writes: 3}, 3); err != nil {
		t.Fatal(err)
	}
	if err := update("unprotect 2", false, budgettest.Budget{Reads: 2, Writes: 3}, 3); err != nil {
		t.Fatal(err)
	}

	// The 5th toggle: QUOTA_EXCEEDED, no writes.
	ctx, c = budget.WithCounter(context.Background())
	_, err = svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, IsPrivate: &yes})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["quota"] != "privacy_toggles" {
		t.Fatalf("5th toggle err = %v, want QUOTA_EXCEEDED quota=privacy_toggles", err)
	}
	if c.Writes() != 0 {
		t.Errorf("5th toggle wrote %d, want 0", c.Writes())
	}
	if p := userData(t, client, itUID); p["isPrivate"] != false {
		t.Errorf("isPrivate = %v after the refused toggle, want false", p["isPrivate"])
	}
}

func TestPrivacyToggle_Integration_CapAndLoader(t *testing.T) {
	client := newTestClient(t)
	svc, repo, _ := privacyService(t, client, identity.PrivacyLimits{TogglesPerDay: 4, SetMax: 2})
	if _, err := client.Doc("privacy/protectedAuthors").Set(context.Background(), map[string]any{"uids": []string{"x", "y"}, "updatedAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	yes := true
	ctx, c := budget.WithCounter(context.Background())
	_, err := svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, IsPrivate: &yes})
	var ae *apierr.Error
	if !errors.As(err, &ae) || ae.Metadata["limit"] != "private_accounts" {
		t.Fatalf("protect at the cap: %v, want LIMIT_REACHED limit=private_accounts", err)
	}
	if c.Writes() != 0 {
		t.Errorf("capped protect wrote %d, want 0", c.Writes())
	}
	if uids, _ := setUIDs(t, client); !slices.Equal(uids, []string{"x", "y"}) {
		t.Errorf("set = %v after a capped protect", uids)
	}

	// A fresh loader reads the doc once on a detached counter: nothing is charged to the caller.
	fresh := identity.NewProtectedSetLoader(repo, time.Minute, 10*time.Minute, nil, nil)
	cctx, cc := budget.WithCounter(context.Background())
	cur, err := fresh.Current(cctx)
	if err != nil || !cur.Has("x") || !cur.Has("y") || cur.Has(itUID) {
		t.Fatalf("fresh loader: %v, %v", cur, err)
	}
	if cc.Reads() != 0 {
		t.Errorf("the refresh was charged to the caller: %d reads", cc.Reads())
	}
	// A missing doc is an empty set.
	empty := newTestClient(t)
	emptyRepo := identity.NewFirestoreRepo(empty, graph.NewFirestoreRepo(empty))
	cur, err = identity.NewProtectedSetLoader(emptyRepo, time.Minute, time.Minute, nil, nil).Current(context.Background())
	if err != nil || cur == nil || cur.Has("x") {
		t.Fatalf("missing doc: %v, %v; want an empty set", cur, err)
	}
}

func TestRemoveFromProtectedSet_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	ctx := context.Background()

	// No set doc: success, and the step never creates it.
	if err := repo.RemoveFromProtectedSet(ctx, "gone"); err != nil {
		t.Fatalf("missing doc: %v", err)
	}
	if _, ok := setUIDs(t, client); ok {
		t.Fatal("RemoveFromProtectedSet created the set doc")
	}

	if _, err := client.Doc("privacy/protectedAuthors").Set(ctx, map[string]any{"uids": []string{"a", "b", "c"}, "updatedAt": time.Now()}); err != nil {
		t.Fatal(err)
	}
	bctx, c := budget.WithCounter(ctx)
	if err := repo.RemoveFromProtectedSet(bctx, "b"); err != nil {
		t.Fatal(err)
	}
	budgettest.Assert(t, "RemoveFromProtectedSet", c, budgettest.Budget{Writes: 1})
	if uids, _ := setUIDs(t, client); !slices.Equal(uids, []string{"a", "c"}) {
		t.Errorf("set = %v, want [a c]", uids)
	}
	// Idempotent; an absent uid changes nothing.
	for _, uid := range []string{"b", "zzz"} {
		if err := repo.RemoveFromProtectedSet(ctx, uid); err != nil {
			t.Fatal(err)
		}
	}
	if uids, _ := setUIDs(t, client); !slices.Equal(uids, []string{"a", "c"}) {
		t.Errorf("set = %v after idempotent removes, want [a c]", uids)
	}
}
