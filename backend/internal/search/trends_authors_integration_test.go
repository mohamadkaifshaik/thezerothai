//go:build integration

package search

// W4-26 against the Firestore emulator: the sweep with the real identity Directory. 60 authors on one tag are read in two
// GetProfiles batches (about 1 read per author on a cold cache); a SUSPENDED author and accounts younger than
// TRENDS_MIN_ACCOUNT_AGE are not counted.

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/dzeroth/dzeroth/backend/internal/graph"
	"github.com/dzeroth/dzeroth/backend/internal/identity"
	"github.com/dzeroth/dzeroth/backend/internal/posts"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/budget/budgettest"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/flags"
)

func TestTrends_Integration_EstablishedAuthors(t *testing.T) {
	c := emulatorClient(t)
	ctx := context.Background()
	graphRepo := graph.NewFirestoreRepo(c)
	idRepo := identity.NewFirestoreRepo(c, graphRepo)
	idSvc := identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour)
	dir := idSvc.(identity.Directory)

	const n = 60
	for i := 0; i < n; i++ {
		uid := fmt.Sprintf("uid-a%02d", i)
		if _, err := idSvc.CreateProfile(ctx, uid, "0123456789abcdef", fmt.Sprintf("a%02d", i), "Name"); err != nil {
			t.Fatalf("CreateProfile: %v", err)
		}
	}
	if _, err := idRepo.UpdateProfile(ctx, "uid-a07", func(p *identity.Profile) { p.Status = identity.AccountStatusSuspended }); err != nil {
		t.Fatal(err)
	}

	// The suspension went around the service, so the sweep gets a service with a cold cache (as a cron instance has).
	dir = identity.New(idRepo, identity.NewCache(time.Minute), 7*24*time.Hour).(identity.Directory)
	store := NewTrendsRepo(c)
	reader := posts.New(posts.Deps{Repo: posts.NewFirestoreRepo(c), Cache: posts.NewCache(time.Minute, 0, 0)})
	reg := flags.NewRegistry(flags.Spec{Name: FlagTrends, Mode: flags.On})
	// The accounts were created just now; the sweep runs "80 h later", so they are older than 72 h.
	now := time.Now().UTC().Add(80 * time.Hour).Truncate(time.Millisecond)
	for i := 0; i < n; i++ {
		seedPost(t, c, i+1, fmt.Sprintf("uid-a%02d", i), "POST", now.Add(-time.Duration(n-i)*time.Minute), "", "big")
	}
	cfg := RefresherConfig{MinAuthors: 3, MaxPosts: 2000, MinInterval: 12 * time.Hour, Now: func() time.Time { return now }}
	r := NewRefresher(store, reader, &trendsFakeProtected{set: map[string]bool{}}, dir, reg, cfg)
	res, err := r.Run(ctx)
	if err != nil || res.Skipped != "" {
		t.Fatalf("res %+v err %v", res, err)
	}
	// document + hide list + 60 posts + 60 profiles (cold cache, 2 batches), 1 write.
	budgettest.Assert(t, "sweep with author check", runCounter(res), budgettest.Budget{Reads: 2 + n + n, Writes: 1})
	doc, err := store.Get(ctx)
	if err != nil || doc == nil || len(doc.Items) != 1 || doc.Items[0] != (TrendItem{Tag: "big", Posts: n - 1, Authors: n - 1}) {
		t.Fatalf("doc %+v err %v, want #big with 59 authors (the suspended one is not counted)", doc, err)
	}
	if res.AuthorsChecked != n || res.AuthorsUnverified != 0 {
		t.Errorf("checked %d unverified %d", res.AuthorsChecked, res.AuthorsUnverified)
	}
}

// runCounter rebuilds a counter from the run's own totals so budgettest can assert them.
func runCounter(res RunResult) *budget.Counter {
	_, c := budget.WithCounter(context.Background())
	c.AddReads(res.FsReads)
	c.AddWrites(res.FsWrites)
	return c
}
