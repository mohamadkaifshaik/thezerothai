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

// TestSearchHandles_Integration (W4-4 acceptance, real repo): handleLower order with the exact match first,
// succ per character (`_` and `z`), limit clamp, exact read counts (len(result), minimum 1), raw status.
func TestSearchHandles_Integration(t *testing.T) {
	client := newTestClient(t)
	graphRepo := graph.NewFirestoreRepo(client)
	repo := identity.NewFirestoreRepo(client, graphRepo)
	graphRepo.SetCounters(repo)
	svc := identity.New(repo, identity.NewCache(time.Minute), 7*24*time.Hour)
	dir := svc.(identity.Directory)
	ctx := context.Background()

	handles := []string{"abd", "abc", "ab_c", "abcd", "zed", "zzz", "zzzz", "z_9", "bbb"}
	for _, h := range handles {
		if _, err := svc.CreateProfile(ctx, "uid-"+h, "0123456789abcdef", h, "N "+h); err != nil {
			t.Fatalf("CreateProfile(%s): %v", h, err)
		}
	}
	// 25 more under one prefix to exercise the clamp.
	for i := 0; i < 25; i++ {
		h := fmt.Sprintf("many%02d", i)
		if _, err := svc.CreateProfile(ctx, "uid-"+h, "0123456789abcdef", h, "N "+h); err != nil {
			t.Fatalf("CreateProfile(%s): %v", h, err)
		}
	}
	// A suspended account is returned raw.
	if _, err := repo.UpdateProfile(ctx, "uid-abd", func(p *identity.Profile) { p.Status = identity.AccountStatusSuspended }); err != nil {
		t.Fatal(err)
	}

	order := func(ps []identity.Profile) []string {
		var out []string
		for _, p := range ps {
			out = append(out, p.HandleLower)
		}
		return out
	}
	equal := func(a, b []string) bool {
		if len(a) != len(b) {
			return false
		}
		for i := range a {
			if a[i] != b[i] {
				return false
			}
		}
		return true
	}

	tests := []struct {
		name      string
		prefix    string
		limit     int
		want      []string
		wantReads int64
	}{
		{"ab: handleLower order", "ab", 20, []string{"ab_c", "abc", "abcd", "abd"}, 4},
		{"abc: exact match first", "abc", 20, []string{"abc", "abcd"}, 2},
		{"upper case prefix", "AB", 20, []string{"ab_c", "abc", "abcd", "abd"}, 4},
		{"z: succ is {; z_9 < zed < zzz < zzzz", "z", 20, []string{"z_9", "zed", "zzz", "zzzz"}, 4},
		{"zzz: succ of the last char only", "zzz", 20, []string{"zzz", "zzzz"}, 2},
		{"ab_: succ of _ is a backtick", "ab_", 20, []string{"ab_c"}, 1},
		{"no match bills 1", "qq", 20, nil, 1},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cctx, counter := budget.WithCounter(ctx)
			got, err := dir.SearchHandles(cctx, tc.prefix, tc.limit)
			if err != nil {
				t.Fatal(err)
			}
			if !equal(order(got), tc.want) {
				t.Fatalf("handles = %v, want %v", order(got), tc.want)
			}
			if counter.Reads() != tc.wantReads {
				t.Fatalf("reads = %d, want %d", counter.Reads(), tc.wantReads)
			}
			budgettest.Assert(t, "SearchHandles", counter, budgettest.Budget{Reads: 20})
		})
	}

	t.Run("limit 50 is clamped to 20", func(t *testing.T) {
		cctx, counter := budget.WithCounter(ctx)
		got, err := dir.SearchHandles(cctx, "many", 50)
		if err != nil {
			t.Fatal(err)
		}
		if len(got) != 20 || counter.Reads() != 20 {
			t.Fatalf("len = %d, reads = %d; want 20 and 20", len(got), counter.Reads())
		}
		budgettest.Assert(t, "SearchHandles", counter, budgettest.Budget{Reads: 20})
	})

	t.Run("raw profile includes status", func(t *testing.T) {
		got, err := dir.SearchHandles(ctx, "abd", 5)
		if err != nil || len(got) != 1 || got[0].Status != identity.AccountStatusSuspended {
			t.Fatalf("got %+v, err %v; want one SUSPENDED profile", got, err)
		}
	})

	t.Run("empty prefix: 0 reads", func(t *testing.T) {
		cctx, counter := budget.WithCounter(ctx)
		got, err := dir.SearchHandles(cctx, "", 5)
		if err != nil || len(got) != 0 || counter.Reads() != 0 {
			t.Fatalf("got %v, err %v, reads %d", got, err, counter.Reads())
		}
	})
}
