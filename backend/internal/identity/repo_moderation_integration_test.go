//go:build integration

package identity_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// TestSetAccountStatus_Integration: ACTIVE <-> SUSPENDED in one transaction (1 read, 1 write, 0 on a no-op); a
// DELETING account is never touched (ADR-0016 D4); unknown users are ErrNotFound.
func TestSetAccountStatus_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC()
	if _, _, err := repo.CreateProfile(context.Background(), "uid-s", "Sam", "sam", "Sam", now, nil); err != nil {
		t.Fatal(err)
	}
	stored := func() string {
		snap, err := client.Collection("users").Doc("uid-s").Get(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		v, _ := snap.DataAt("status")
		s, _ := v.(string)
		return s
	}

	ctx, c := budget.WithCounter(context.Background())
	changed, err := repo.SetAccountStatus(ctx, "uid-s", identity.AccountStatusActive, identity.AccountStatusSuspended, now)
	if err != nil || !changed || stored() != "SUSPENDED" {
		t.Fatalf("suspend: changed=%v err=%v status=%q", changed, err, stored())
	}
	budgettest.Assert(t, "SetAccountStatus", c, budgettest.Budget{Reads: 1, Writes: 1})

	ctx, c = budget.WithCounter(context.Background())
	changed, err = repo.SetAccountStatus(ctx, "uid-s", identity.AccountStatusActive, identity.AccountStatusSuspended, now)
	if err != nil || changed {
		t.Fatalf("suspend again: changed=%v err=%v", changed, err)
	}
	budgettest.Assert(t, "SetAccountStatus no-op", c, budgettest.Budget{Reads: 1})

	if changed, err = repo.SetAccountStatus(context.Background(), "uid-s", identity.AccountStatusSuspended, identity.AccountStatusActive, now); err != nil || !changed || stored() != "ACTIVE" {
		t.Fatalf("unsuspend: changed=%v err=%v status=%q", changed, err, stored())
	}

	if _, err := client.Collection("users").Doc("uid-s").Update(context.Background(), []firestore.Update{{Path: "status", Value: "DELETING"}}); err != nil {
		t.Fatal(err)
	}
	for _, p := range [][2]identity.AccountStatus{
		{identity.AccountStatusActive, identity.AccountStatusSuspended},
		{identity.AccountStatusSuspended, identity.AccountStatusActive},
	} {
		if _, err := repo.SetAccountStatus(context.Background(), "uid-s", p[0], p[1], now); !errors.Is(err, identity.ErrStatusConflict) {
			t.Fatalf("DELETING %v->%v: err = %v, want ErrStatusConflict", p[0], p[1], err)
		}
	}
	if stored() != "DELETING" {
		t.Fatalf("a DELETING account was changed to %q", stored())
	}

	if _, err := repo.SetAccountStatus(context.Background(), "uid-none", identity.AccountStatusActive, identity.AccountStatusSuspended, now); !errors.Is(err, identity.ErrNotFound) {
		t.Fatalf("unknown user: %v", err)
	}
	if _, err := repo.SetAccountStatus(context.Background(), "uid-s", identity.AccountStatusActive, identity.AccountStatusDeleting, now); err == nil {
		t.Fatal("ACTIVE -> DELETING must be unsupported")
	}
}
