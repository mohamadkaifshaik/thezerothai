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
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/idempotency"
)

// W5-9 (ADR-0030 D6) on the emulator: the SetHomeTabs transaction's exact reads and writes (the account-status interceptor's
// own read is not part of this harness), the field-level write, Unpin and Retitle for lists.Pins, and the proof that a
// whole-document rewrite of users/{uid} (UpdateProfile, ChangeHandle, the privacy toggle) keeps homeTabs.

const (
	htListA = "0000000000000000101"
	htListB = "0000000000000000102"
	htListC = "0000000000000000103"
	htKey1  = "tabs-key-0000001"
	htKey2  = "tabs-key-0000002"
	htKey3  = "tabs-key-0000003"
)

type homeTabsEnv struct {
	client  *firestore.Client
	svc     identity.Service
	repo    *identity.FirestoreRepo
	adapter *identity.HomeTabsAdapter
}

func newHomeTabsEnv(t *testing.T) *homeTabsEnv {
	t.Helper()
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	cache := identity.NewCache(time.Minute)
	set := identity.NewProtectedSetLoader(repo, time.Minute, 10*time.Minute, nil, nil)
	reg := flags.NewRegistry(flags.Spec{Name: identity.PrivateAccountsFlag, Mode: flags.On}, flags.Spec{Name: identity.ListsFlag, Mode: flags.On})
	svc := identity.New(repo, cache, 7*24*time.Hour, identity.WithFeatureFlags(reg), identity.WithExtrasFlags(reg),
		identity.WithPrivacy(identity.PrivacyDeps{Repo: repo, Set: set, Limits: identity.PrivacyLimits{TogglesPerDay: 4, SetMax: 20000}}))
	ctx, _ := budget.WithCounter(context.Background())
	if _, err := svc.CreateProfile(ctx, itUID, validKeyForIntegration, "Alice", "Alice A."); err != nil {
		t.Fatalf("CreateProfile: %v", err)
	}
	return &homeTabsEnv{client: client, svc: svc, repo: repo, adapter: identity.NewHomeTabs(repo, idempotency.New(client), cache)}
}

func (e *homeTabsEnv) stored(t *testing.T) []identity.HomeTab {
	t.Helper()
	p, err := e.repo.GetProfile(context.Background(), itUID)
	if err != nil {
		t.Fatal(err)
	}
	return p.HomeTabs()
}

func setTo(tabs ...identity.HomeTab) func([]identity.HomeTab) ([]identity.HomeTab, error) {
	return func([]identity.HomeTab) ([]identity.HomeTab, error) { return tabs, nil }
}

func tab(id, title string) identity.HomeTab {
	return identity.HomeTab{Kind: identity.HomeTabKindList, ID: id, Title: title}
}

func TestHomeTabsReplace_Integration_Budgets(t *testing.T) {
	e := newHomeTabsEnv(t)
	ctx := context.Background()
	before := userData(t, e.client, itUID)

	run := func(name, key, hash string, b budgettest.Budget, writes int64, next func([]identity.HomeTab) ([]identity.HomeTab, error)) ([]identity.HomeTab, error) {
		t.Helper()
		c, counter := budget.WithCounter(ctx)
		got, err := e.adapter.Replace(c, itUID, key, hash, next)
		if err == nil {
			budgettest.Assert(t, name, counter, b)
			if counter.Writes() != writes {
				t.Errorf("%s: writes = %d, want exactly %d", name, counter.Writes(), writes)
			}
			if counter.Reads() != 2 {
				t.Errorf("%s: reads = %d, want exactly 2 (idempotency, users)", name, counter.Reads())
			}
		}
		return got, err
	}

	want := []identity.HomeTab{tab(htListA, "Mine"), tab(htListB, "")}
	got, err := run("SetHomeTabs, changed order", htKey1, "h1", budgettest.Budget{Reads: 2, Writes: 2}, 2, setTo(want...))
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("Replace = %+v, %v", got, err)
	}
	if !slices.Equal(e.stored(t), want) {
		t.Fatalf("stored = %+v, want %+v", e.stored(t), want)
	}
	// Field-level: nothing else on the document moved.
	after := userData(t, e.client, itUID)
	for k, v := range before {
		if k == "homeTabs" {
			continue
		}
		if !equalAny(after[k], v) {
			t.Errorf("users/%s.%s changed from %v to %v: the write must touch homeTabs only", itUID, k, v, after[k])
		}
	}

	// The same order under a new key: only the idempotency record is written.
	if _, err := run("SetHomeTabs, same order, new key", htKey2, "h1", budgettest.Budget{Reads: 2, Writes: 1}, 1, setTo(want...)); err != nil {
		t.Fatal(err)
	}
	// A replay of the first key: stored tabs, no write, and next must not even run.
	got, err = run("SetHomeTabs, replay", htKey1, "h1", budgettest.Budget{Reads: 2, Writes: 0}, 0,
		func([]identity.HomeTab) ([]identity.HomeTab, error) { t.Error("next ran on a replay"); return nil, nil })
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("replay = %+v, %v", got, err)
	}
	// The same key with another body.
	if _, err := e.adapter.Replace(ctx, itUID, htKey1, "other", setTo()); !errors.Is(err, identity.ErrKeyReused) {
		t.Fatalf("reused key err = %v, want ErrKeyReused", err)
	}
	// A failing next writes nothing (not even the idempotency record: the key stays usable).
	boom := errors.New("boom")
	if _, err := e.adapter.Replace(ctx, itUID, htKey3, "h3", func([]identity.HomeTab) ([]identity.HomeTab, error) { return nil, boom }); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want boom", err)
	}
	if _, err := e.client.Collection("idempotency").Doc(idempotency.Key(itUID, "SetHomeTabs", htKey3)).Get(ctx); err == nil {
		t.Error("a refused call left an idempotency record")
	}
	// Unpin everything removes the field instead of storing an empty array.
	if _, err := run("SetHomeTabs, unpin all", htKey3, "h3", budgettest.Budget{Reads: 2, Writes: 2}, 2, setTo()); err != nil {
		t.Fatal(err)
	}
	if _, has := userData(t, e.client, itUID)["homeTabs"]; has {
		t.Error("homeTabs is still on the document after unpinning everything")
	}
	// A missing account is ErrNotFound and creates nothing.
	if _, err := e.adapter.Replace(ctx, "ghost", htKey1, "h", setTo(want...)); !errors.Is(err, identity.ErrNotFound) {
		t.Fatalf("ghost err = %v, want ErrNotFound", err)
	}
	if snap, err := e.client.Collection("users").Doc("ghost").Get(ctx); err == nil && snap.Exists() {
		t.Error("Replace recreated a missing users document")
	}
}

func equalAny(a, b any) bool {
	at, aok := a.(time.Time)
	bt, bok := b.(time.Time)
	if aok && bok {
		return at.Equal(bt)
	}
	return a == b
}

func TestHomeTabsPins_Integration_UnpinRetitle(t *testing.T) {
	e := newHomeTabsEnv(t)
	ctx := context.Background()
	if _, err := e.adapter.Replace(ctx, itUID, htKey1, "h", setTo(tab(htListA, "Old"), tab(htListB, ""), tab(htListC, "C"))); err != nil {
		t.Fatal(err)
	}
	measure := func(name string, reads, writes int64, fn func(context.Context)) {
		t.Helper()
		c, counter := budget.WithCounter(ctx)
		fn(c)
		budgettest.Assert(t, name, counter, budgettest.Budget{Reads: reads, Writes: writes})
		if counter.Reads() != reads || counter.Writes() != writes {
			t.Errorf("%s: reads/writes = %d/%d, want exactly %d/%d", name, counter.Reads(), counter.Writes(), reads, writes)
		}
	}

	measure("Retitle a pinned list", 1, 1, func(c context.Context) {
		pinned, err := e.adapter.Retitle(c, itUID, htListA, "New name")
		if err != nil || !pinned {
			t.Fatalf("Retitle = %v, %v", pinned, err)
		}
	})
	measure("Retitle to the same title", 1, 0, func(c context.Context) {
		pinned, err := e.adapter.Retitle(c, itUID, htListA, "New name")
		if err != nil || !pinned {
			t.Fatalf("Retitle = %v, %v", pinned, err)
		}
	})
	measure("Retitle a list that is not pinned", 1, 0, func(c context.Context) {
		pinned, err := e.adapter.Retitle(c, itUID, "0000000000000000999", "x")
		if err != nil || pinned {
			t.Fatalf("Retitle = %v, %v", pinned, err)
		}
	})
	measure("Unpin a pinned list", 1, 1, func(c context.Context) {
		if err := e.adapter.Unpin(c, itUID, htListB); err != nil {
			t.Fatal(err)
		}
	})
	measure("Unpin a list that is not pinned", 1, 0, func(c context.Context) {
		if err := e.adapter.Unpin(c, itUID, htListB); err != nil {
			t.Fatal(err)
		}
	})
	if got, want := e.stored(t), []identity.HomeTab{tab(htListA, "New name"), tab(htListC, "C")}; !slices.Equal(got, want) {
		t.Fatalf("stored = %+v, want %+v", got, want)
	}
	// A missing account: nothing to do, nothing created.
	if err := e.adapter.Unpin(ctx, "ghost", htListA); err != nil {
		t.Fatalf("Unpin ghost = %v", err)
	}
	if snap, err := e.client.Collection("users").Doc("ghost").Get(ctx); err == nil && snap.Exists() {
		t.Error("Unpin recreated a missing users document")
	}
}

// The adapter refreshes this instance's cache from the written data: GetMe right after a write shows the new order without
// re-reading users/{uid}, and a flag that is off for the caller hides the tabs without losing them.
func TestHomeTabs_Integration_GetMeAndCache(t *testing.T) {
	e := newHomeTabsEnv(t)
	ctx := context.Background()
	if _, err := e.svc.GetMe(ctx, itUID); err != nil { // warm the profile cache (the interceptor's read)
		t.Fatal(err)
	}
	if _, err := e.adapter.Replace(ctx, itUID, htKey1, "h", setTo(tab(htListB, ""), tab(htListA, "Mine"))); err != nil {
		t.Fatal(err)
	}
	c, counter := budget.WithCounter(ctx)
	me, err := e.svc.GetMe(c, itUID)
	if err != nil {
		t.Fatal(err)
	}
	if want := []identity.HomeTab{tab(htListB, ""), tab(htListA, "Mine")}; !slices.Equal(me.HomeTabs, want) {
		t.Fatalf("GetMe tabs = %+v, want %+v", me.HomeTabs, want)
	}
	// GetMe's own cost is unchanged by tabs: the profile is cached, the unread count is the one read.
	if counter.Reads() > 1 {
		t.Errorf("GetMe reads = %d, want at most 1 (the notification count); home_tabs adds none", counter.Reads())
	}
}

// UpdateProfile, ChangeHandle and the privacy toggle each rewrite the whole users document; homeTabs must survive all three.
func TestHomeTabs_Integration_SurvivesWholeDocumentRewrites(t *testing.T) {
	e := newHomeTabsEnv(t)
	ctx := context.Background()
	want := []identity.HomeTab{tab(htListA, "Mine"), tab(htListB, "")}
	if _, err := e.adapter.Replace(ctx, itUID, htKey1, "h", setTo(want...)); err != nil {
		t.Fatal(err)
	}
	name := "Alice Again"
	if _, err := e.svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, DisplayName: &name}); err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if got := e.stored(t); !slices.Equal(got, want) {
		t.Fatalf("after UpdateProfile: %+v", got)
	}
	yes := true
	if _, err := e.svc.UpdateProfile(ctx, itUID, identity.UpdateProfileParams{IdempotencyKey: validKeyForIntegration, IsPrivate: &yes}); err != nil {
		t.Fatalf("privacy toggle: %v", err)
	}
	if got := e.stored(t); !slices.Equal(got, want) {
		t.Fatalf("after the privacy toggle: %+v", got)
	}
	if _, err := e.svc.ChangeHandle(ctx, itUID, validKeyForIntegration, "alicia"); err != nil {
		t.Fatalf("ChangeHandle: %v", err)
	}
	if got := e.stored(t); !slices.Equal(got, want) {
		t.Fatalf("after ChangeHandle: %+v", got)
	}
}
