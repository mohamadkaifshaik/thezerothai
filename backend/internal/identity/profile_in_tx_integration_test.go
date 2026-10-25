//go:build integration

package identity_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
)

// profileInTx runs ProfileInTx in a read-only transaction and returns what it saw and what it cost.
func profileInTx(t *testing.T, client *firestore.Client, repo *identity.FirestoreRepo, uid string) (identity.Profile, *budget.Counter, error) {
	t.Helper()
	ctx, counter := budget.WithCounter(context.Background())
	var got identity.Profile
	err := client.RunTransaction(ctx, func(ctx context.Context, tx *firestore.Transaction) error {
		p, err := repo.ProfileInTx(ctx, tx, uid)
		got = p
		return err
	})
	return got, counter, err
}

// TestProfileInTx_Integration: the transaction-scoped profile read (ADR-0021 Sweep step 3.2) costs exactly 1 read,
// returns the profile unfiltered by status (SUSPENDED and DELETING come back, unlike Directory.GetProfiles), reports
// ErrNotFound for an absent document, and never puts the uid in the error text.
func TestProfileInTx_Integration(t *testing.T) {
	client := newTestClient(t)
	repo := identity.NewFirestoreRepo(client, graph.NewFirestoreRepo(client))
	now := time.Now().UTC().Truncate(time.Millisecond)
	if _, _, err := repo.CreateProfile(context.Background(), "uid-tx-1", "Alice", "alice", "Alice A.", now, nil); err != nil {
		t.Fatal(err)
	}

	t.Run("active", func(t *testing.T) {
		p, c, err := profileInTx(t, client, repo, "uid-tx-1")
		if err != nil {
			t.Fatalf("ProfileInTx: %v", err)
		}
		budgettest.Assert(t, "ProfileInTx", c, budgettest.Budget{Reads: 1})
		if c.Reads() != 1 {
			t.Errorf("reads = %d, want exactly 1", c.Reads())
		}
		if p.UserID != "uid-tx-1" || p.Handle != "Alice" || p.DisplayName != "Alice A." || p.Status != identity.AccountStatusActive || !p.CreatedAt.Equal(now) {
			t.Errorf("profile = %+v", p)
		}
	})

	for _, st := range []struct {
		stored string
		want   identity.AccountStatus
	}{{"SUSPENDED", identity.AccountStatusSuspended}, {"DELETING", identity.AccountStatusDeleting}} {
		t.Run("status "+st.stored+" is returned, not filtered", func(t *testing.T) {
			if _, err := client.Collection("users").Doc("uid-tx-1").Update(context.Background(), []firestore.Update{{Path: "status", Value: st.stored}}); err != nil {
				t.Fatal(err)
			}
			p, c, err := profileInTx(t, client, repo, "uid-tx-1")
			if err != nil || p.Status != st.want {
				t.Fatalf("profile status = %v err = %v, want %v", p.Status, err, st.want)
			}
			if c.Reads() != 1 {
				t.Errorf("reads = %d, want 1", c.Reads())
			}
		})
	}

	t.Run("absent", func(t *testing.T) {
		_, c, err := profileInTx(t, client, repo, "uid-tx-missing")
		if !errors.Is(err, identity.ErrNotFound) {
			t.Fatalf("err = %v, want ErrNotFound", err)
		}
		if c.Reads() != 1 {
			t.Errorf("an absent document still bills 1 read; got %d", c.Reads())
		}
		if strings.Contains(err.Error(), "uid-tx-missing") {
			t.Errorf("the error text names the uid: %v", err)
		}
	})
}
