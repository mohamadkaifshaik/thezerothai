//go:build integration

package posts

import (
	"context"
	"fmt"
	"math/rand/v2"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// stageViewsCommit commits n views of ids at t through StageViews (what RecordImpressions does).
func stageViewsCommit(t *testing.T, r *FirestoreRepo, ids []string, at time.Time, n int) {
	t.Helper()
	for range n {
		b := store.NewFirestoreBatch(r.client)
		done := r.StageViews(b, ids, at)
		if err := b.Commit(context.Background()); err != nil {
			t.Fatalf("commit views: %v", err)
		}
		done()
	}
}

func viewCountOf(t *testing.T, r *FirestoreRepo, id string) int64 {
	t.Helper()
	s, err := r.ref(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v, _ := s.DataAt("viewCount")
	n, _ := v.(int64)
	return n
}

// TestIntegration_ViewRollup: views spread over shards fold into viewCount once their window closed; the rollup is
// idempotent on redelivery (a second run, and a run with the markers re-created by hand, write the same value); a post
// deleted with live markers gets its shards deleted; every marker of a closed window is gone afterwards.
func TestIntegration_ViewRollup(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := NewFirestoreRepo(client)
	base := 1_000_000 + rand.IntN(1_000_000)
	live, gone := fmt.Sprintf("%019d", base), fmt.Sprintf("%019d", base+1)
	for _, id := range []string{live, gone} {
		if _, err := r.ref(id).Set(ctx, map[string]any{"authorId": "a", "kind": "POST", "text": "t"}); err != nil {
			t.Fatal(err)
		}
	}
	t0 := time.Now().Add(-time.Hour)
	stageViewsCommit(t, r, []string{live, gone}, t0, 12)
	stageViewsCommit(t, r, []string{live}, t0.Add(ViewWindow), 3) // a second window: a second marker for live
	if _, err := r.ref(gone).Delete(ctx); err != nil {
		t.Fatal(err)
	}

	clock := time.Now()
	v := &ViewRollup{Repo: r, MinInterval: time.Minute, Now: func() time.Time { return clock }}
	res, err := v.Run(ctx)
	if err != nil || res.Folded != 1 || res.Gone != 1 {
		t.Fatalf("run = %+v, %v; want 1 folded, 1 gone", res, err)
	}
	if got := viewCountOf(t, r, live); got != 15 {
		t.Fatalf("viewCount = %d, want 15", got)
	}
	left, err := client.Collection(viewDirtyCollection).Where("postId", "in", []string{live, gone}).Limit(10).Documents(ctx).GetAll()
	if err != nil || len(left) != 0 {
		t.Fatalf("markers left %d, %v", len(left), err)
	}
	tot, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{r.ref(gone)}, viewShardField)
	if err != nil || tot[0].Get(viewShardField) != 0 {
		t.Fatalf("gone post's shards = %v, %v; want deleted", tot, err)
	}

	// Redelivery inside the gate: fresh, nothing changes.
	if res, err := v.Run(ctx); err != nil || res.Outcome != ViewRollupFresh {
		t.Fatalf("redelivery = %+v, %v", res, err)
	}
	// A later run that sees the same post dirty again (markers re-created, no new views) writes the same value.
	if _, err := r.viewMarkerRef(viewWindow(t0), live).Set(ctx, viewMarkerDoc{PostID: live, Window: viewWindow(t0)}); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(2 * time.Minute)
	if res, err := v.Run(ctx); err != nil || res.Folded != 1 || viewCountOf(t, r, live) != 15 {
		t.Fatalf("repeat fold = %+v, %v, viewCount %d; want 15 again", res, err, viewCountOf(t, r, live))
	}
}
