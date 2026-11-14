//go:build integration

package posts

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"testing"
	"time"

	"cloud.google.com/go/firestore"
)

// TestIntegration_SetShareCountDrainsShards: a hot post with pending shareCount deltas (+2 on one shard, -1 on another,
// views and a likeCount delta on the same shard docs) is repaired to the true total 7; the shareCount shards are drained
// in the same transaction, so the next rollup fold adds nothing and the plain field stays 7 (the old plain set gave 8:
// the regression). The views field and the likeCount delta are untouched and the like delta still folds. A second
// repair is a no-op on the value; a cold post without shards is the old single write; a missing post is ErrNotFound.
func TestIntegration_SetShareCountDrainsShards(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := NewFirestoreRepo(client)
	base := 3_000_000 + rand.IntN(1_000_000)
	hot, cold, missing := fmt.Sprintf("%019d", base), fmt.Sprintf("%019d", base+1), fmt.Sprintf("%019d", base+2)
	for _, id := range []string{hot, cold} {
		if _, err := r.ref(id).Set(ctx, map[string]any{"authorId": "a", "kind": "POST", "text": "t", "likeCount": int64(10), "shareCount": int64(4)}); err != nil {
			t.Fatal(err)
		}
	}
	t0 := time.Now().Add(-time.Hour)
	seedCounterShard(t, r, hot, shareCountField, 2, t0)
	seedCounterShard(t, r, hot, shareCountField, -1, t0)
	seedCounterShard(t, r, hot, likeCountField, 3, t0)
	stageViewsCommit(t, r, []string{hot}, t0, 5)

	if c, found, err := r.StoredShareCount(ctx, hot); err != nil || !found || c != (StoredCount{Plain: 4, Pending: 1}) {
		t.Fatalf("stored before = %+v %v %v; want plain 4 + pending 1", c, found, err)
	}
	if err := r.SetShareCount(ctx, hot, 7); err != nil {
		t.Fatal(err)
	}
	shards := func(when string, wantLike int64) {
		t.Helper()
		tot, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{r.ref(hot)}, shareCountField, likeCountField, viewShardField)
		if err != nil {
			t.Fatal(err)
		}
		if tot[0].Get(shareCountField) != 0 || tot[0].Get(likeCountField) != wantLike || tot[0].Get(viewShardField) != 5 {
			t.Fatalf("%s: shards = %v; want shareCount 0, likeCount %d, views 5", when, tot[0], wantLike)
		}
	}
	if s := intField(t, r, hot, "shareCount"); s != 7 {
		t.Fatalf("after set: shareCount %d, want 7", s)
	}
	shards("after set", 3)
	if c, _, err := r.StoredShareCount(ctx, hot); err != nil || c != (StoredCount{Plain: 7}) {
		t.Fatalf("stored after set = %+v %v; want plain 7, nothing pending", c, err)
	}

	// The rollup's next tick: the share markers' fold moves nothing more; the like delta folds as before.
	v := &ViewRollup{Repo: r, MinInterval: time.Hour, Off: func() bool { return true }, Now: time.Now}
	if _, err := v.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if s, l := intField(t, r, hot, "shareCount"), intField(t, r, hot, "likeCount"); s != 7 || l != 13 {
		t.Fatalf("after fold: shareCount %d likeCount %d, want 7 (no double count) and 13", s, l)
	}
	shards("after fold", 0)

	// A second repair (a re-run of the command) writes the same value and drains nothing.
	if err := r.SetShareCount(ctx, hot, 7); err != nil {
		t.Fatal(err)
	}
	if c, _, err := r.StoredShareCount(ctx, hot); err != nil || c != (StoredCount{Plain: 7}) {
		t.Fatalf("stored after re-run = %+v %v; want plain 7", c, err)
	}

	// Cold post, no shards: the old behaviour (read the field, set it).
	if c, found, err := r.StoredShareCount(ctx, cold); err != nil || !found || c != (StoredCount{Plain: 4}) {
		t.Fatalf("cold stored = %+v %v %v", c, found, err)
	}
	if err := r.SetShareCount(ctx, cold, 2); err != nil {
		t.Fatal(err)
	}
	if s, l := intField(t, r, cold, "shareCount"), intField(t, r, cold, "likeCount"); s != 2 || l != 10 {
		t.Fatalf("cold after set: shareCount %d likeCount %d, want 2 10", s, l)
	}
	if tot, err := viewShards.Read(ctx, client, []*firestore.DocumentRef{r.ref(cold)}, shareCountField); err != nil || tot[0].Get(shareCountField) != 0 {
		t.Fatalf("cold shards = %v %v; want none", tot, err)
	}

	// Missing post: not found on both halves, and no shard is created.
	if _, found, err := r.StoredShareCount(ctx, missing); err != nil || found {
		t.Fatalf("missing stored: found=%v err=%v", found, err)
	}
	if err := r.SetShareCount(ctx, missing, 1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing set = %v, want ErrNotFound", err)
	}
}
