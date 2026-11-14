//go:build integration

package posts

import (
	"context"
	"fmt"
	"math/rand/v2"
	"testing"
	"time"
)

func shardDocs(t *testing.T, r *FirestoreRepo, id string) int {
	t.Helper()
	docs, err := r.ref(id).Collection(ViewShardsSubcollection).Limit(20).Documents(context.Background()).GetAll()
	if err != nil {
		t.Fatal(err)
	}
	return len(docs)
}

// TestIntegration_ViewShardsGoWithThePost: the account purge deletes every post with its view shards (more posts than one
// view-shard batch), and DeletePost's batch deletes the shards with the post.
func TestIntegration_ViewShardsGoWithThePost(t *testing.T) {
	ctx := context.Background()
	client := newTestClient(t)
	r := NewFirestoreRepo(client)
	r.SetWriters(WriteDeps{Counters: countersStub{client}})
	uid := fmt.Sprintf("purge-views-%d", rand.Int64())
	if _, err := client.Collection("users").Doc(uid).Set(ctx, map[string]any{"postsCount": 100}); err != nil {
		t.Fatal(err)
	}
	base := 3_000_000 + rand.IntN(1_000_000)
	var ids []string
	for i := range purgeShardChunk + 5 {
		id := fmt.Sprintf("%019d", base+i)
		ids = append(ids, id)
		if _, err := r.ref(id).Set(ctx, map[string]any{"authorId": uid, "kind": "POST", "text": "t", "createdAt": time.Now().UTC()}); err != nil {
			t.Fatal(err)
		}
	}
	stageViewsCommit(t, r, ids, time.Now(), 3)
	if shardDocs(t, r, ids[0]) == 0 {
		t.Fatal("no shards were written")
	}

	// DeletePost of the first post takes its shards in the same batch.
	if ok, err := r.DeleteOwn(ctx, ids[0], uid); err != nil || !ok {
		t.Fatalf("DeleteOwn = %v, %v", ok, err)
	}
	if n := shardDocs(t, r, ids[0]); n != 0 {
		t.Fatalf("DeleteOwn left %d shards", n)
	}

	cp, done := Checkpoint{}, false
	for i := 0; !done && cp.Phase == 0 && i < 5; i++ {
		var err error
		if cp, done, err = r.PurgeUser(ctx, uid, cp); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range ids[1:] {
		if n := shardDocs(t, r, id); n != 0 {
			t.Fatalf("purge left %d shards of %s", n, id)
		}
		if _, err := r.ref(id).Get(ctx); err == nil {
			t.Fatalf("purge left post %s", id)
		}
	}
}
