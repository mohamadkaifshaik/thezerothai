//go:build integration

package posts

import (
	"context"
	"fmt"
	"math/rand/v2"
	"testing"
	"time"

	"cloud.google.com/go/firestore"

	"github.com/dzeroth/dzeroth/backend/pkg/platform/shardcount"
	"github.com/dzeroth/dzeroth/backend/pkg/platform/store"
)

// seedCounterShard commits one engagement shard write of field on postID with its counter marker at `at` (what the hot
// path of PR 2 stages), plus n views when views > 0.
func seedCounterShard(t *testing.T, r *FirestoreRepo, postID string, field firestore.FieldPath, n int64, at time.Time) {
	t.Helper()
	b := store.NewFirestoreBatch(r.client)
	viewShards.StageIncrement(b, r.ref(postID), shardcount.Delta{Field: field, N: n})
	done := r.stageMarkers(b, counterMarkers, []string{postID}, at)
	if err := b.Commit(context.Background()); err != nil {
		t.Fatalf("seed counter shard: %v", err)
	}
	done()
}

func intField(t *testing.T, r *FirestoreRepo, id, field string) int64 {
	t.Helper()
	s, err := r.ref(id).Get(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	v, _ := s.DataAt(field)
	n, _ := v.(int64)
	return n
}

// TestIntegration_CounterRollup: engagement shards (+ and -) and a cold Increment on the same post fold into the plain
// fields with delta semantics, on a tick where the views half is gated and post_views is globally off; the views field
// on the same shard docs and the view markers are untouched; the shards net to 0; the counter markers of closed windows
// are deleted, the open window's stay; a redelivered fold (the markers re-created by hand) does not double-count; a post
// deleted with live counter shards gets its shards deleted.
func TestIntegration_CounterRollup(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := NewFirestoreRepo(client)
	base := 1_000_000 + rand.IntN(1_000_000)
	hot, gone := fmt.Sprintf("%019d", base), fmt.Sprintf("%019d", base+1)
	for _, id := range []string{hot, gone} {
		if _, err := r.ref(id).Set(ctx, map[string]any{"authorId": "a", "kind": "POST", "text": "t", "likeCount": int64(50), "shareCount": int64(4)}); err != nil {
			t.Fatal(err)
		}
	}
	t0 := time.Now().Add(-time.Hour)
	for range 5 {
		seedCounterShard(t, r, hot, likeCountField, 1, t0)
	}
	seedCounterShard(t, r, hot, likeCountField, -1, t0)
	seedCounterShard(t, r, hot, shareCountField, 2, t0.Add(ViewWindow))
	seedCounterShard(t, r, hot, repostCountField, 3, t0.Add(ViewWindow))
	stageViewsCommit(t, r, []string{hot}, t0, 6) // views on the same shard docs
	if _, err := r.ref(hot).Update(ctx, []firestore.Update{{Path: "likeCount", Value: firestore.Increment(1)}}); err != nil {
		t.Fatal(err) // a cold write meanwhile
	}
	seedCounterShard(t, r, gone, likeCountField, 1, t0)
	if _, err := r.ref(gone).Delete(ctx); err != nil {
		t.Fatal(err)
	}
	seedCounterShard(t, r, hot, likeCountField, 1, time.Now().Add(ViewWindow)) // an open window: its marker waits, its value moves with the rest

	clock := time.Now()
	v := &ViewRollup{Repo: r, MinInterval: time.Hour, Off: func() bool { return true }, Now: func() time.Time { return clock }}
	res, err := v.Run(ctx)
	if err != nil || res.CountersFolded != 1 || res.CountersGone != 1 || res.Outcome != ViewRollupOff {
		t.Fatalf("run = %+v, %v; want 1 folded, 1 gone, views off", res, err)
	}
	check := func(when string) {
		t.Helper()
		// likeCount: 50 + 1 cold + 4 net hot + the open window's 1 (the fold moves whatever the shards hold; only the
		// open window's marker waits, for a later fold that moves nothing).
		if l, s, rp := intField(t, r, hot, "likeCount"), intField(t, r, hot, "shareCount"), intField(t, r, hot, "repostCount"); l != 56 || s != 6 || rp != 3 {
			t.Fatalf("%s: like %d share %d repost %d, want 56 6 3", when, l, s, rp)
		}
		tot, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{r.ref(hot)}, likeCountField, shareCountField, repostCountField, viewShardField)
		if err != nil {
			t.Fatal(err)
		}
		if tot[0].Get(likeCountField) != 0 || tot[0].Get(shareCountField) != 0 || tot[0].Get(repostCountField) != 0 || tot[0].Get(viewShardField) != 6 {
			t.Fatalf("%s: shards = %v; want the engagement fields at 0 and views 6", when, tot[0])
		}
		if viewCountOf(t, r, hot) != 0 {
			t.Fatalf("%s: viewCount moved while post_views is off", when)
		}
	}
	check("first run")
	gtot, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{r.ref(gone)}, likeCountField)
	if err != nil || gtot[0].Get(likeCountField) != 0 {
		t.Fatalf("gone post's shards = %v, %v; want deleted", gtot, err)
	}
	counterLeft, err := client.Collection(viewDirtyCollection).Where("counterWindow", ">", int64(0)).Limit(10).Documents(ctx).GetAll()
	if err != nil || len(counterLeft) != 1 {
		t.Fatalf("counter markers left %d, %v; want the open window's only", len(counterLeft), err)
	}
	viewLeft, err := client.Collection(viewDirtyCollection).Where("window", ">", int64(0)).Limit(10).Documents(ctx).GetAll()
	if err != nil || len(viewLeft) != 1 {
		t.Fatalf("view markers left %d, %v; want the view marker untouched while views are off", len(viewLeft), err)
	}

	// Redelivery: the same closed-window markers again (re-created by hand) fold nothing more.
	if _, err := r.markerRef(counterMarkers, viewWindow(t0), hot).Set(ctx, counterMarkers.data(viewWindow(t0), hot)); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(time.Minute)
	if res, err := v.Run(ctx); err != nil || res.CountersFolded != 1 {
		t.Fatalf("redelivery = %+v, %v", res, err)
	}
	check("redelivery")

	// Views back on: the views half folds the absolute sum, the plain engagement fields do not move.
	v.Off = func() bool { return false }
	if _, err := v.Run(ctx); err != nil || viewCountOf(t, r, hot) != 6 {
		t.Fatalf("views run: %v, viewCount %d, want 6", err, viewCountOf(t, r, hot))
	}
	if l := intField(t, r, hot, "likeCount"); l != 56 {
		t.Fatalf("likeCount after the views fold = %d, want 56", l)
	}
}
